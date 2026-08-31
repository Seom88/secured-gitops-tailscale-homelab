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

ensureVeleroCredentials() {
  echo -e "\n${BLUE}🛡️  Ensuring Velero S3 credentials (RustFS)...${NC}"

  # Ensure namespace exists (idempotent, also created by Helm/ArgoCD but needed for Secret)
  if ! kubectl get namespace velero >/dev/null 2>&1; then
    echo -e "${YELLOW}  [Velero] Creating namespace velero...${NC}"
    kubectl create namespace velero >/dev/null 2>&1 || true
  else
    echo -e "${GREEN}  [Velero] Namespace velero exists.${NC}"
  fi

  # Resolve credentials: prefer VELERO_AWS_* , fallback to AWS_* (same RustFS keys as Terraform).
  VELERO_KEY_ID="${VELERO_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  VELERO_SECRET="${VELERO_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

  if [ -z "$VELERO_KEY_ID" ] || [ -z "$VELERO_SECRET" ]; then
    echo -e "${YELLOW}  [Velero] ⚠️  No S3 credentials in env (VELERO_AWS_ACCESS_KEY_ID / VELERO_AWS_SECRET_ACCESS_KEY or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).${NC}"
    echo -e "${YELLOW}  [Velero]    Velero chart will stay Pending (BackupStorageLocation unavailable) until you create the Secret.${NC}"
    echo -e "${YELLOW}  [Velero]    Create it with: VELERO_AWS_ACCESS_KEY_ID=... VELERO_AWS_SECRET_ACCESS_KEY=... ./bootstrap/init-gitops.sh $ENV${NC}"
    echo -e "${YELLOW}  [Velero]    Expected Secret: velero/cloud-credentials key 'cloud' = \"[default]\\naws_access_key_id=...\\naws_secret_access_key=...\"${NC}"
    return 0
  fi

  # Velero AWS plugin expects key `cloud` with ini format:
  #   [default]
  #   aws_access_key_id=...
  #   aws_secret_access_key=...
  CLOUD_CONTENT="[default]
aws_access_key_id=${VELERO_KEY_ID}
aws_secret_access_key=${VELERO_SECRET}"

  echo -e "${YELLOW}  [Velero] Creating/updating Secret velero/cloud-credentials (existingSecret for Helm)...${NC}"
  kubectl create secret generic cloud-credentials \
    --namespace velero \
    --from-literal=cloud="$CLOUD_CONTENT" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo -e "${GREEN}  [Velero] Secret velero/cloud-credentials ready.${NC}"
}

# --- STEP 1.45: Velero credentials (MUST run BEFORE Longhorn wait) ---
# Velero bucket-init Job is wave -1 and mounts Secret as volume. If Secret does not exist
# kubelet fails with FailedMount and never creates the pod (chicken-egg). Creating it here
# ensures Argo can sync wave -1 / wave 0 without blocking.
ensureVeleroCredentials

# --- STEP 1.5: Wait for Longhorn Storage (wave 0) ---
echo -e "\n${BLUE}💾 Waiting for Longhorn storage (wave 0)...${NC}"

# Only watch if longhorn is part of the App-of-Apps (gitops/values.yaml contains it)
if kubectl get application longhorn -n argocd >/dev/null 2>&1; then
  LONGHORN_TIMEOUT=300
  LONGHORN_INTERVAL=5
  LONGHORN_ELAPSED=0
  echo -ne "${YELLOW}  [Longhorn] Waiting for StorageClasses (longhorn/longhorn-prod) and CSI to be ready...${NC}"
  while [ $LONGHORN_ELAPSED -lt $LONGHORN_TIMEOUT ]; do
    SC_READY="false"
    if kubectl get sc longhorn >/dev/null 2>&1 || kubectl get sc longhorn-prod >/dev/null 2>&1; then
      SC_READY="true"
    fi

    APP_HEALTH=$(kubectl get application longhorn -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    APP_SYNC=$(kubectl get application longhorn -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

    # CSI gate: driver-deployer rollout + csi-plugin DaemonSet (created dynamically by driver-deployer)
    # Use longer timeout (5s) to avoid flaky 1s timeout; add fallback via DaemonSet numberReady.
    CSI_READY="false"
    if kubectl rollout status deployment/longhorn-driver-deployer -n longhorn-system --timeout=5s >/dev/null 2>&1; then
      if kubectl get daemonset longhorn-csi-plugin -n longhorn-system >/dev/null 2>&1; then
        if kubectl rollout status daemonset/longhorn-csi-plugin -n longhorn-system --timeout=5s >/dev/null 2>&1; then
          CSI_READY="true"
        else
          # Fallback: check DaemonSet numberReady vs desiredNumberScheduled (handles rollout status flakiness)
          CSI_DESIRED=$(kubectl get daemonset longhorn-csi-plugin -n longhorn-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
          CSI_READY_COUNT=$(kubectl get daemonset longhorn-csi-plugin -n longhorn-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
          # Also check driver-deployer deployment ready
          DEPLOY_READY=$(kubectl get deployment longhorn-driver-deployer -n longhorn-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
          if [ "$CSI_READY_COUNT" != "0" ] && [ "$CSI_READY_COUNT" = "$CSI_DESIRED" ] && [ "$DEPLOY_READY" != "0" ]; then
            CSI_READY="true"
          elif [ "$CSI_READY_COUNT" -ge 1 ] 2>/dev/null && [ "$DEPLOY_READY" -ge 1 ] 2>/dev/null; then
            # At least one CSI pod ready and deployer ready — consider functional (covers discover-proc-kubelet-cmdline Pending edge)
            CSI_READY="true"
          fi
        fi
      else
        # driver-deployer ready but DaemonSet not yet created — still progressing
        CSI_READY="false"
      fi
    else
      # rollout status timed out — fallback to DaemonSet ready check
      if kubectl get daemonset longhorn-csi-plugin -n longhorn-system >/dev/null 2>&1; then
        CSI_DESIRED=$(kubectl get daemonset longhorn-csi-plugin -n longhorn-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        CSI_READY_COUNT=$(kubectl get daemonset longhorn-csi-plugin -n longhorn-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        DEPLOY_READY=$(kubectl get deployment longhorn-driver-deployer -n longhorn-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$CSI_READY_COUNT" != "0" ] && [ "$CSI_READY_COUNT" = "$CSI_DESIRED" ] && [ "$DEPLOY_READY" != "0" ]; then
          CSI_READY="true"
        fi
      fi
    fi

    # Fallback: if SC and Argo are Healthy/Synced, consider CSI ready even if rollout check flaked
    # This prevents 600s block when only non-critical pods (discover-proc-kubelet-cmdline, csi-wait, post-upgrade) are Pending.
    if [ "$CSI_READY" = "false" ] && [ "$SC_READY" = "true" ] && [ "$APP_HEALTH" = "Healthy" ] && [ "$APP_SYNC" = "Synced" ]; then
      # Double-check DaemonSet has at least 1 ready replica before trusting Argo health
      CSI_READY_COUNT_FB=$(kubectl get daemonset longhorn-csi-plugin -n longhorn-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
      if [ "$CSI_READY_COUNT_FB" -ge 1 ] 2>/dev/null; then
        CSI_READY="true"
      elif [ $LONGHORN_ELAPSED -ge 90 ]; then
        # After 90s with SC + Healthy/Synced, don't block CI for flaky CSI Pending pods
        echo -e "\n${YELLOW}  [Longhorn] SC + Argo Healthy/Synced for ${LONGHORN_ELAPSED}s — treating CSI as ready (flaky Pending tolerant).${NC}"
        CSI_READY="true"
      fi
    fi

    # Also check the csi-wait Job (wave 1 inside longhorn chart) if it exists
    CSI_JOB_STATUS=$(kubectl get job longhorn-csi-wait -n longhorn-system -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")

    if [ "$SC_READY" = "true" ] && [ "$CSI_READY" = "true" ] && [ "$APP_HEALTH" = "Healthy" ] && [ "$APP_SYNC" = "Synced" ]; then
      echo -e " ${GREEN}Ready! (SC + CSI + ArgoCD Healthy/Synced)${NC}"
      break
    fi

    # Show richer status every 30s so the watch is not mute like Vault's "....."
    if [ $((LONGHORN_ELAPSED % 30)) -eq 0 ] && [ $LONGHORN_ELAPSED -ne 0 ]; then
      echo ""
      echo -e "${YELLOW}  [Longhorn] elapsed ${LONGHORN_ELAPSED}s — SC_READY=$SC_READY CSI_READY=$CSI_READY APP=$APP_SYNC/$APP_HEALTH CSI_JOB=$CSI_JOB_STATUS${NC}"
      kubectl get application longhorn -n argocd 2>/dev/null | sed 's/^/    /' || true
      kubectl get sc 2>/dev/null | sed 's/^/    /' || echo "    (no StorageClass yet)"
      kubectl get pods -n longhorn-system 2>/dev/null | sed 's/^/    /' || echo "    (no pods in longhorn-system yet)"
      echo -ne "${YELLOW}  [Longhorn] Waiting...${NC}"
    else
      echo -n "."
    fi

    sleep $LONGHORN_INTERVAL
    LONGHORN_ELAPSED=$((LONGHORN_ELAPSED + LONGHORN_INTERVAL))
  done

  if [ $LONGHORN_ELAPSED -ge $LONGHORN_TIMEOUT ]; then
    echo -e "\n${RED}  [Longhorn] Timeout after ${LONGHORN_TIMEOUT}s — SC or CSI not ready yet.${NC}"
    echo -e "${YELLOW}  [Longhorn] Current state (will continue to Vault, but PVCs may stay Pending):${NC}"
    kubectl get application longhorn -n argocd 2>/dev/null | sed 's/^/    /' || echo "    (no ArgoCD Application longhorn)"
    kubectl get sc 2>/dev/null | sed 's/^/    /' || echo "    (no StorageClass)"
    kubectl get pods -n longhorn-system 2>/dev/null | sed 's/^/    /' || echo "    (no pods)"
    kubectl get jobs -n longhorn-system 2>/dev/null | sed 's/^/    /' || true
    echo -e "${YELLOW}  💡 Check: kubectl describe application longhorn -n argocd | kubectl logs -n longhorn-system -l app.kubernetes.io/name=longhorn${NC}"
  else
    echo -e "${GREEN}  [Longhorn] Storage is ready — Vault PVCs can now bind.${NC}"
    kubectl get sc | sed 's/^/    /' || true
  fi
else
  echo -e "${YELLOW}  [Longhorn] Application 'longhorn' not found in ArgoCD — skipping wait (older git revision without wave 0).${NC}"
  echo -e "${YELLOW}  💡 If you expect Longhorn, push gitops/values.yaml with longhorn to origin/main and re-run.${NC}"
fi

# --- STEP 1.6: Velero credentials already ensured before Longhorn wait (STEP 1.45) ---
# (moved earlier to avoid chicken-egg FailedMount for velero-bucket-init wave -1)

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
echo -e "\n${BOLD}Velero Pods:${NC}"
kubectl get pods -n velero || true
echo -e "\n${BOLD}Tailscale Pods:${NC}"
kubectl get pods -n tailscale || true

# Final Info
echo -e "\n${GREEN}${BOLD}===================================================${NC}"
echo -e "${GREEN}${BOLD}      ✨ BOOTSTRAP COMPLETE! ✨                    ${NC}"
echo -e "${GREEN}${BOLD}===================================================${NC}"
echo -e "${BOLD}ArgoCD UI:${NC}    just pf-argocd    -> https://localhost:8080"
echo -e "${BOLD}ArgoCD User:${NC}  admin"
echo -e "${BOLD}ArgoCD Pass:${NC}  just argocd-password"
echo -e "\n${BOLD}Vault UI:${NC}   just pf-vault     -> https://localhost:8200"
echo -e "${BOLD}Vault Token:${NC} just vault-token"
echo -e "\n${YELLOW}💡 Port-forward commands (via just):${NC}"
echo -e "   just pf-argocd   # svc/argocd-server -n argocd 8080:443"
echo -e "   just pf-vault    # svc/vault -n vault 8200:8200"
echo -e "\n${RED}⚠️  IMPORTANT:${NC} Read docs/secrets-structure.md to update your secrets."
echo -e "${YELLOW}ℹ️  Script is idempotent — rerun without --force anytime to verify platform status.${NC}"
echo -e "${GREEN}${BOLD}===================================================${NC}"
