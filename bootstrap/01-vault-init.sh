#!/bin/bash

VAULT_VERSION=0.32.0

# Init infra (cert-manager, storage class)
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# Create namespace for vault
echo "Creating vault namespace..."
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Apply cert-manager Issuer and Certificate
echo "Creating vault certificates using cert-manager..."
kubectl apply -f platform/vault/templates/vault/certificates.yaml

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

# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install vault
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --version $VAULT_VERSION \
  --set global.fullnameOverride=vault \
  -f platform/vault/values.yaml

# Wait for vault-0 pod to be created
echo "Waiting for vault-0 pod to be created..."
for i in $(seq 1 60); do
  if kubectl get pod/vault-0 -n vault &>/dev/null; then
    echo "Pod vault-0 created"
    break
  fi
  sleep 2
done

# Wait Vault pod to be running (it won't be 'Ready' until unsealed)
echo "Waiting for vault-0 pod to be running..."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 -n vault --timeout=120s

# Init Vault
INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init \
    -address=https://127.0.0.1:8200 \
    -tls-skip-verify \
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
kubectl exec -n vault vault-0 -- vault operator unseal -address=https://127.0.0.1:8200 -tls-skip-verify $KEY1
kubectl exec -n vault vault-0 -- vault operator unseal -address=https://127.0.0.1:8200 -tls-skip-verify $KEY2
kubectl exec -n vault vault-0 -- vault operator unseal -address=https://127.0.0.1:8200 -tls-skip-verify $KEY3
echo "Vault unsealed successfully."

# Enable kv-v2 secrets engine at path "secret"
echo "Enabling kv-v2 secrets engine at path 'secret'..."
kubectl exec -n vault vault-0 -- /bin/sh -c "export VAULT_TOKEN=$ROOT_TOKEN; vault secrets enable -address=https://127.0.0.1:8200 -tls-skip-verify -path=secret kv-v2"

# Print the root token for you to save in your password manager
echo "Save this in your password manager:"
echo "Key 1: $KEY1"
echo "Key 2: $KEY2"
echo "Key 3: $KEY3"
echo "Key 4: $KEY4"
echo "Key 5: $KEY5"
echo "Root Token (Login token): $ROOT_TOKEN"

# enter to UI
echo "Run: kubectl port-forward svc/vault -n vault 8200:8200"
echo "You should now config secrets, before executing init argoCD, check doc/secrets-structure.md for more info"