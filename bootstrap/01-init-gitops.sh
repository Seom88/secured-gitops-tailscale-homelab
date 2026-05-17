#!/bin/bash
set -e

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# --- Config env ---
ENV=${1:-prod}
VALUES_FILE="gitops/values.yaml"

echo -e "${BLUE}${BOLD}===================================================${NC}"
echo -e "${BLUE}${BOLD}   🚀 ARGO GITOPS HOMELAB BOOTSTRAP ($ENV)        ${NC}"
echo -e "${BLUE}${BOLD}===================================================${NC}"

if [ "$ENV" == "dev" ]; then
  echo -e "${YELLOW}⚠️  Dev mode ON - using values-dev.yaml${NC}"
  VALUES_FILE="gitops/values-dev.yaml"
fi

echo -e "\n${BOLD}🔐 Vault Secrets Setup${NC}"
if [ -z "$TS_CLIENT_ID" ] || [ "$TS_CLIENT_ID" == "ChangeMeSecret" ]; then
    echo -ne "${YELLOW}👉 Enter Tailscale Client ID: ${NC}"
    read TS_CLIENT_ID
    export TS_CLIENT_ID
fi

if [ -z "$TS_CLIENT_SECRET" ] || [ "$TS_CLIENT_SECRET" == "ChangeMeSecret" ]; then
    echo -ne "${YELLOW}👉 Enter Tailscale Client Secret (hidden): ${NC}"
    read -s TS_CLIENT_SECRET
    echo ""
    export TS_CLIENT_SECRET
fi

# --- ArgoCD Version ---
ARGOCD_VERSION=9.5.13

# Init infra
echo -e "\n${BLUE}🏗️  Initializing infrastructure...${NC}"
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# --- STEP 1: Install ArgoCD ---
echo -e "\n${BLUE}📦 Installing ArgoCD (v$ARGOCD_VERSION)...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm > /dev/null 2>&1
helm repo update > /dev/null 2>&1

helm upgrade --install argocd argo/argo-cd \
  --version $ARGOCD_VERSION \
  --namespace argocd --create-namespace \
  --timeout 30m \
  -f platform/argocd/values.yaml

echo -ne "${YELLOW}⏳ Waiting for ArgoCD CRDs...${NC}"
until kubectl get crd applications.argoproj.io > /dev/null 2>&1; do echo -n "."; sleep 2; done
echo -e " ${GREEN}Done!${NC}"

echo -e "${YELLOW}⏳ Waiting for ArgoCD server rollout...${NC}"
kubectl rollout status deployment/argocd-server -n argocd --timeout=10m

# --- STEP 2: Install App-of-Apps ---
echo -e "\n${BLUE}📂 Installing GitOps App-of-Apps...${NC}"
helm upgrade --install gitops gitops \
  --namespace argocd \
  --timeout 30m \
  -f "$VALUES_FILE"

# --- STEP 3: Vault configuration ---
echo -e "\n${BLUE}🔑 Configuring Hashicorp Vault...${NC}"
chmod +x platform/vault/scripts/init-vault.sh
./platform/vault/scripts/init-vault.sh

# Final Info
VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
if [ -n "$VAULT_POD" ]; then
    RELEASE_NAME=$(kubectl get pod "$VAULT_POD" -n vault -o jsonpath="{.metadata.labels['app\.kubernetes\.io/instance']}")
    SECRET_NAME="$RELEASE_NAME-unseal-keys"
else
    SECRET_NAME="vault-unseal-keys"
fi

ROOT_TOKEN=$(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.root-token}' | base64 -d 2>/dev/null || echo "N/A")
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "N/A")

echo -e "\n${GREEN}${BOLD}===================================================${NC}"
echo -e "${GREEN}${BOLD}      ✨ BOOTSTRAP COMPLETE! ✨                    ${NC}"
echo -e "${GREEN}${BOLD}===================================================${NC}"
echo -e "${BOLD}ArgoCD UI:${NC}    http://localhost:8080"
echo -e "${BOLD}ArgoCD User:${NC}  admin"
echo -e "${BOLD}ArgoCD Pass:${NC}  $ARGOCD_PASSWORD"
echo -e "\n${BOLD}Vault UI:${NC}     https://localhost:8200"
echo -e "${BOLD}Vault Token:${NC}  $ROOT_TOKEN"
echo -e "\n${YELLOW}💡 Port-forward commands:${NC}"
echo -e "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo -e "   kubectl port-forward svc/vault -n vault 8200:8200"
echo -e "\n${RED}⚠️  IMPORTANT:${NC} Read doc/secrets-structure.md to update your secrets."
echo -e "${GREEN}${BOLD}===================================================${NC}"
