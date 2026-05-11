#!/bin/bash

# Init infra (storage class)
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# Install ArgoCD Base first (to get CRDs)
echo "Installing ArgoCD Base (Timeout: 30m)..."
helm dependency build gitops
helm upgrade --install argocd gitops \
  --namespace argocd --create-namespace \
  --set platformApps.enabled=false \
  --timeout 30m \
  -f gitops/values.yaml

echo "Waiting for ArgoCD CRDs..."
until kubectl get crd applications.argoproj.io > /dev/null 2>&1; do sleep 2; done

# Install full GitOps (including Apps)
echo "Installing ArgoCD Apps (Timeout: 30m)..."
helm upgrade --install argocd gitops \
  --namespace argocd \
  --timeout 30m \
  -f gitops/values.yaml

# Wait for Vault Setup Job
echo "Waiting for Vault namespace and setup Job..."
until kubectl get ns vault > /dev/null 2>&1; do sleep 5; done
echo "Namespace 'vault' found. Waiting for job/vault-setup to be created..."
until kubectl get job/vault-setup -n vault > /dev/null 2>&1; do sleep 5; done
kubectl wait --for=condition=complete job/vault-setup -n vault --timeout=1800s

# Seed secrets for Tailscale auth (Interactive)
echo "Waiting for vault-unseal-keys secret..."
until kubectl get secret vault-unseal-keys -n vault > /dev/null 2>&1; do sleep 5; done
ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d)

if [ -z "$TS_CLIENT_ID" ] || [ -z "$TS_CLIENT_SECRET" ]; then
    read -p "Type Tailscale Client ID: " TS_CLIENT_ID
    read -sp "Type Tailscale Client Secret (your input will not be shown): " TS_CLIENT_SECRET
    echo ""
fi

echo "Seeding Tailscale secrets into Vault..."
kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault kv put \
        -address=https://127.0.0.1:8200 \
        -ca-cert=/vault/userconfig/vault-tls/ca.crt \
        -tls-server-name=vault \
        secret/tailscale/auth \
        client_id=$TS_CLIENT_ID \
        client_secret=$TS_CLIENT_SECRET"

# Final Info
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "---------------------------------------------------"
echo "Bootstrap Complete!"
echo "ArgoCD URL: http://localhost:8080 (port-forward needed)"
echo "ArgoCD User: admin"
echo "ArgoCD Password: $ARGOCD_PASSWORD"
echo "Vault Root Token: $ROOT_TOKEN"
echo "---------------------------------------------------"

