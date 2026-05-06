#!/bin/bash

CERT_MANAGER_VERSION=v1.17.2
VAULT_VERSION=0.32.0

# Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --version 9.5.11 \
  --namespace argocd \
  -f platform/argocd/values.yaml

# Wait for ArgoCD deployment to be created
echo "Waiting for ArgoCD deployment to be created..."
for i in $(seq 1 150); do
  if kubectl get deployment/argocd-server -n argocd &>/dev/null; then
    echo "Deployment argocd-server created"
    break
  fi
  sleep 2
done

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s

# Wait for ArgoCD initial admin secret to be created
echo "Waiting for ArgoCD initial admin secret..."
for i in $(seq 1 150); do
  if kubectl -n argocd get secret argocd-initial-admin-secret &>/dev/null; then
    echo "Secret argocd-initial-admin-secret created"
    break
  fi
  sleep 2
done

# Init infra (storage class)
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# Apply cert-manager Issuer and Certificate
# Install cert-manager
echo "Installing cert-manager..."
kubectl apply -f gitops/prod/cert-manager-app.yaml

# Wait for Cert-Manager ArgoCD App to be Synced
echo "Waiting for Cert-Manager ArgoCD App to be Synced..."
for i in $(seq 1 60); do
  SYNC_STATUS=$(kubectl get application cert-manager-sync -n argocd -o jsonpath='{.status.sync.status}')
  if [ "$SYNC_STATUS" = "Synced" ]; then
    echo "Cert-Manager ArgoCD App is Synced"
    break
  fi
  sleep 2
done

# Apply Vault ArgoCD App (sync-wave -5)
echo "Applying Vault ArgoCD App..."
kubectl apply -f gitops/prod/vault-app.yaml

# Wait for Vault ArgoCD App to be Synced (ArgoCD must deploy Vault first)
echo "Waiting for Vault ArgoCD App to be Synced..."
for i in $(seq 1 60); do
  SYNC_STATUS=$(kubectl get application vault-app -n argocd -o jsonpath='{.status.sync.status}')
  if [ "$SYNC_STATUS" = "Synced" ]; then
    echo "Vault ArgoCD App is Synced"
    break
  fi
  sleep 2
done

# Wait for certificate to be ready
echo "Waiting for certificate to be ready..."
for i in $(seq 1 60); do
  READY=$(kubectl get certificate vault-tls -n vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$READY" = "True" ]; then
    echo "Certificate ready"
    break
  fi
  sleep 2
done

# Wait for vault-app-0 pod to be created
echo "Waiting for vault-app-0 pod to be created..."
for i in $(seq 1 60); do
  if kubectl get pod/vault-app-0 -n vault &>/dev/null; then
    echo "Pod vault-app-0 created"
    break
  fi
  sleep 2
done

# Wait Vault pod to be running (it won't be 'Ready' until unsealed)
echo "Waiting for vault-app-0 pod to be running..."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-app-0 -n vault --timeout=120s

# Init Vault
INIT_OUTPUT=$(kubectl exec -n vault vault-app-0 -- vault operator init \
    -address=https://127.0.0.1:8200 \
    -ca-cert=/vault/userconfig/vault-tls/ca.crt \
    -tls-server-name=vault \
    -format=json)

# Extract the unseal keys and root token from the output
KEY1=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[0]')
KEY2=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[1]')
KEY3=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[2]')
KEY4=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[3]')
KEY5=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[4]')
ROOT_TOKEN=$(echo $INIT_OUTPUT | jq -r '.root_token')

# Create a Kubernetes secret to store the unseal keys
kubectl get secret vault-unseal-keys -n vault &>/dev/null || kubectl create secret generic vault-unseal-keys \
  --namespace vault \
  --from-literal=root-token="$ROOT_TOKEN" \
  --from-literal=key1="$KEY1" \
  --from-literal=key2="$KEY2" \
  --from-literal=key3="$KEY3" \
  --from-literal=key4="$KEY4" \
  --from-literal=key5="$KEY5"

# Unseal Vault
echo "Unsealing Vault..."
kubectl exec -n vault vault-app-0 -- vault operator unseal \
    -address=https://127.0.0.1:8200 \
    -ca-cert=/vault/userconfig/vault-tls/ca.crt \
    -tls-server-name=vault \
    $KEY1
kubectl exec -n vault vault-app-0 -- vault operator unseal \
    -address=https://127.0.0.1:8200 \
    -ca-cert=/vault/userconfig/vault-tls/ca.crt \
    -tls-server-name=vault \
    $KEY2
kubectl exec -n vault vault-app-0 -- vault operator unseal \
    -address=https://127.0.0.1:8200 \
    -ca-cert=/vault/userconfig/vault-tls/ca.crt \
    -tls-server-name=vault \
    $KEY3
echo "Vault unsealed successfully."

# Enable kv-v2 secrets engine at path "secret"
echo "Enabling kv-v2 secrets engine at path 'secret'..."
kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault secrets enable \
    -address=https://127.0.0.1:8200 \
    -ca-cert=/vault/userconfig/vault-tls/ca.crt \
    -tls-server-name=vault \
    -path=secret kv-v2"

# seed secrets for tailscale auth
if [ -z "$TS_CLIENT_ID" ] || [ -z "$TS_CLIENT_SECRET" ]; then
    read -p "Type Tailscale Client ID: " TS_CLIENT_ID
    read -sp "Type Tailscale Client Secret (your input will not be shown): " TS_CLIENT_SECRET
    echo ""
fi

kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault kv put \
        -address=https://127.0.0.1:8200 \
        -ca-cert=/vault/userconfig/vault-tls/ca.crt \
        -tls-server-name=vault \
        secret/tailscale/auth \
        client_id=$TS_CLIENT_ID \
        client_secret=$TS_CLIENT_SECRET"

# Enable Kubernetes authentication
echo "Enabling Kubernetes authentication..."
kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault auth enable \
        -address=https://127.0.0.1:8200 \
        -ca-cert=/vault/userconfig/vault-tls/ca.crt \
        -tls-server-name=vault kubernetes" || echo "Kubernetes auth already enabled"

# Configure Kubernetes authentication
echo "Configuring Kubernetes authentication..."
K8S_ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
K8S_CA=$(kubectl exec -n vault vault-app-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault write \
        -address=https://127.0.0.1:8200 \
        -ca-cert=/vault/userconfig/vault-tls/ca.crt \
        -tls-server-name=vault \
        auth/kubernetes/config \
        kubernetes_host=\"https://kubernetes.default.svc\" \
        kubernetes_ca_cert=\"$K8S_CA\" \
        issuer=\"$K8S_ISSUER\""

# Create Tailscale policy
echo "Creating Tailscale policy..."
kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault policy write \
        -address=https://127.0.0.1:8200 \
        -ca-cert=/vault/userconfig/vault-tls/ca.crt \
        -tls-server-name=vault \
        tailscale-policy - <<EOF
path \"secret/data/tailscale/*\" {
  capabilities = [\"read\"]
}
EOF"

# Create ESO role
echo "Creating ESO role..."
kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault write \
        -address=https://127.0.0.1:8200 \
        -ca-cert=/vault/userconfig/vault-tls/ca.crt \
        -tls-server-name=vault \
        auth/kubernetes/role/eso-tailscale-role \
        bound_service_account_names=eso-app-external-secrets \
        bound_service_account_namespaces=external-secrets \
        policies=tailscale-policy \
        ttl=24h"

# Deploy ArgoCD via its own Application manifest (GitOps style).
# ArgoCD will now manage its own versioning via platform/argocd/ chart.
echo "Initializing ArgoCD via GitOps..."
kubectl apply -f gitops/root-prod-app.yaml

# Print the root token for you to save in your password manager
echo "Save this in your password manager:"
echo "Key 1: $KEY1"
echo "Key 2: $KEY2"
echo "Key 3: $KEY3"
echo "Key 4: $KEY4"
echo "Key 5: $KEY5"
echo "Root Token (Login token): $ROOT_TOKEN"

# Extract the initial admin password for ArgoCD
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD initial admin password: $ARGOCD_PASSWORD"

# enter to UI
echo "Now chat your Tailscale admin console, to access vault local address, you need forward port"
echo "Run: kubectl port-forward svc/vault-app -n vault 8200:8200"
echo "Check doc/secrets-structure.md for more info, you maybe need configure more secrets"
echo "To access to argocd local address, you need forward port"
echo "Run: kubectl port-forward svc/argocd-server -n argocd 8080:443"
