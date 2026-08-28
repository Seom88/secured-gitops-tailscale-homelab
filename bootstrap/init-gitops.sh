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

# Support --force / -f as second argument to bypass idempotency guard
FORCE="false"
if [ "$2" = "--force" ] || [ "$2" = "-f" ]; then
  FORCE="true"
fi

echo -e "${BLUE}${BOLD}===================================================${NC}"
echo -e "${BLUE}${BOLD}   🚀 ARGO GITOPS HOMELAB BOOTSTRAP ($ENV)        ${NC}"
echo -e "${BLUE}${BOLD}===================================================${NC}"
echo -e "${YELLOW}ℹ️  Manual bootstrap + status verifier — idempotent, safe to rerun for status check. Use --force to reapply App-of-Apps.${NC}"

if [ "$ENV" == "dev" ]; then
  echo -e "${YELLOW}⚠️  Dev mode ON - using values-dev.yaml${NC}"
  VALUES_FILE="gitops/values-dev.yaml"
fi

# Prerequisites: ArgoCD must already be installed (infra-talos-homelab platform layer).
# Longhorn is now wave-0 of this repo, not a prerequisite.

# --- STEP 1: Install App-of-Apps (guarded) ---
APP_EXISTS="false"
if [ "$FORCE" != "true" ]; then
  if helm status gitops -n argocd >/dev/null 2>&1 \
    || kubectl get application gitops -n argocd >/dev/null 2>&1 \
    || kubectl get application gitops-dev -n argocd >/dev/null 2>&1 \
    || kubectl get applicationset platform-local-apps -n argocd >/dev/null 2>&1; then
    APP_EXISTS="true"
  fi
fi

if [ "$APP_EXISTS" = "true" ]; then
  echo -e "\n${YELLOW}App-of-Apps already exists — skipping helm install${NC}"
else
  echo -e "\n${BLUE}📂 Installing GitOps App-of-Apps...${NC}"
  helm upgrade --install gitops gitops \
    --namespace argocd \
    --timeout 30m \
    -f "$VALUES_FILE" \
    || echo -e "${YELLOW}⚠️  GitOps helm install failed (likely a server-side apply conflict).${NC}
${YELLOW}   You can retry with: kubectl delete applicationset -n argocd platform-local-apps${NC}"
fi

# --- STEP 2: Vault configuration ---
echo -e "\n${BLUE}🔑 Configuring Hashicorp Vault...${NC}"
chmod +x platform/vault/scripts/bootstrap-vault.sh
./platform/vault/scripts/bootstrap-vault.sh

# --- STEP 3: Status verification ---
echo -e "\n${BLUE}${BOLD}📊 Verifying platform status...${NC}"
echo -e "\n${BOLD}ArgoCD Applications:${NC}"
kubectl get applications -n argocd || true
echo -e "\n${BOLD}ArgoCD ApplicationSets:${NC}"
kubectl get applicationsets -n argocd || true
echo -e "\n${BOLD}ArgoCD Pods:${NC}"
kubectl get pods -n argocd || true
echo -e "\n${BOLD}Longhorn Pods:${NC}"
kubectl get pods -n longhorn-system || true
echo -e "\n${BOLD}Vault Pods:${NC}"
kubectl get pods -n vault || true
echo -e "\n${BOLD}Monitoring Pods:${NC}"
kubectl get pods -n monitoring || true
echo -e "\n${BOLD}Tailscale Pods:${NC}"
kubectl get pods -n tailscale || true

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
echo -e "${BOLD}ArgoCD UI:${NC}    https://localhost:8080"
echo -e "${BOLD}ArgoCD User:${NC}  admin"
echo -e "${BOLD}ArgoCD Pass:${NC}  $ARGOCD_PASSWORD"
echo -e "\n${BOLD}Vault UI:${NC}     https://localhost:8200"
echo -e "${BOLD}Vault Token:${NC}  $ROOT_TOKEN"
echo -e "\n${YELLOW}💡 Port-forward commands:${NC}"
echo -e "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
if [ "$ENV" == "dev" ]; then
  echo -e "   kubectl port-forward svc/vault-dev -n vault 8200:8200"
else
  echo -e "   kubectl port-forward svc/vault -n vault 8200:8200"
fi
echo -e "\n${RED}⚠️  IMPORTANT:${NC} Read docs/secrets-structure.md to update your secrets."
echo -e "${YELLOW}ℹ️  Script is idempotent — rerun without --force anytime to verify platform status.${NC}"
echo -e "${GREEN}${BOLD}===================================================${NC}"
