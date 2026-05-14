#!/bin/bash
set -e

# Init infra (storage class)
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# --- STEP 1: Install ArgoCD (standalone, with custom config) ---
echo "Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "Installing ArgoCD"
helm upgrade --install argocd argo/argo-cd \
  --version 9.5.13 \
  --namespace argocd --create-namespace \
  --timeout 30m \
  -f bootstrap/values-argocd.yaml

echo "Waiting for ArgoCD CRDs..."
until kubectl get crd applications.argoproj.io > /dev/null 2>&1; do sleep 2; done

echo "Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=10m

# --- STEP 2: Install App-of-Apps (platform applications) ---
echo "Installing GitOps App-of-Apps"
helm upgrade --install gitops gitops \
  --namespace argocd \
  --timeout 30m \
  -f gitops/values.yaml

# --- STEP 3: Vault configuration ---
chmod +x platform/vault/scripts/init-vault.sh
./platform/vault/scripts/init-vault.sh

# Final Info
ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d 2>/dev/null || echo "N/A")
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "---------------------------------------------------"
echo "Bootstrap Complete!"
echo "ArgoCD URL: http://localhost:8080 (port-forward needed)"
echo "ArgoCD User: admin"
echo "ArgoCD Password: $ARGOCD_PASSWORD"
echo "Vault Root Token: $ROOT_TOKEN"
echo "---------------------------------------------------"
