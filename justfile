# ──────────────────────────────────────────────
#  Secured GitOps Homelab — ujust / just recipes
# ──────────────────────────────────────────────

# ── Default ───────────────────────────────────
_default:
    @just --list

# ── Development ───────────────────────────────

# Create dev cluster (without Longhorn)
cluster-dev:
    k3d cluster create --config infra/k3d/k3d-config.yaml

# Create dev cluster WITH Longhorn support (needs iscsiadm on host)
cluster-dev-longhorn:
    #!/usr/bin/env bash
    mkdir -p "$HOME/k3d-longhorn"
    k3d cluster create --config infra/k3d/k3d-config-longhorn.yaml

# Destroy dev cluster
cluster-destroy-dev:
    k3d cluster delete dev-cluster

# ── Bootstrap ─────────────────────────────────

# Full bootstrap (production)
init-prod:
    ./bootstrap/01-init-gitops.sh prod

# Full bootstrap (development mode)
init-dev:
    ./bootstrap/01-init-gitops.sh dev

# Initialize node-level infrastructure (storage, system-upgrade-controller)
init-infra:
    ./infra/init-infra.sh

# ── Vault ─────────────────────────────────────

# Initialize Vault (auto-unseal, configure secrets)
vault-init:
    ./platform/vault/scripts/init-vault.sh

# ── Port Forwarding ───────────────────────────

# Port-forward ArgoCD UI → localhost:8080
pf-argocd:
    kubectl port-forward svc/argocd-server -n argocd 8080:443

# Port-forward Vault UI → localhost:8200
pf-vault:
    kubectl port-forward svc/vault -n vault 8200:8200

# Port-forward Prometheus → localhost:9090
pf-prometheus:
    kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090

# Port-forward Grafana → localhost:3000
pf-grafana:
    kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80

# ── Cluster Info ──────────────────────────────

# Show ArgoCD admin password
argocd-password:
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" | base64 -d; echo

# Show Vault root token
vault-token:
    #!/usr/bin/env bash
    secret=$(kubectl get secret -n vault -l app.kubernetes.io/instance=vault \
      -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    if [ -z "$secret" ]; then
      echo "No Vault unseal secret found"
    else
      kubectl get secret "$secret" -n vault -o jsonpath='{.data.root-token}' | base64 -d; echo
    fi

# Show cluster nodes and versions
status:
    @echo "=== Nodes ===" && \
    kubectl get nodes -o wide && \
    echo "" && \
    echo "=== Platform ===" && \
    kubectl get pods -n argocd -o name && \
    kubectl get pods -n vault -o name 2>/dev/null && \
    kubectl get pods -n monitoring -o name 2>/dev/null

# ── GitOps ────────────────────────────────────

# Force ArgoCD sync (App of Apps)
sync:
    kubectl apply -n argocd -f gitops/

# Show rendered Helm templates (dry-run)
diff:
    helm diff upgrade --install gitops gitops/ -n argocd -f gitops/values.yaml \
      --allow-unreleased 2>/dev/null || \
    helm template gitops gitops/ -n argocd -f gitops/values.yaml

# ── Docs ──────────────────────────────────────

# List available documentation
docs:
    @echo "── Documentation ──" && \
    ls -1 docs/*.md docs/**/*.md 2>/dev/null | sed 's/^/  /' || echo "  (no docs found)"

# ── Environment ───────────────────────────────

# Check required tools are installed
check:
    @echo "Checking prerequisites..."
    @kubectl version --client 2>/dev/null && echo "  ✅ kubectl" || echo "  ❌ kubectl — not found"
    @helm version --short 2>/dev/null && echo "  ✅ helm" || echo "  ❌ helm — not found"
    @git --version 2>/dev/null && echo "  ✅ git" || echo "  ❌ git — not found"
    @jq --version 2>/dev/null && echo "  ✅ jq" || echo "  ❌ jq — not found"
    @k3d --version 2>/dev/null && echo "  ✅ k3d" || echo "  ❌ k3d — not found"
    @talosctl version --client 2>/dev/null && echo "  ✅ talosctl" || echo "  ❌ talosctl — not found"

# ── Maintenance ───────────────────────────────

# Dry-run Helm upgrades for all platform charts
helm-dry-run:
    #!/usr/bin/env bash
    for chart in platform/*/; do
      name=$(basename "$chart")
      echo "── ${name} ──"
      helm template "$name" "$chart" -n "$name" 2>/dev/null | head -3 || echo "  (skip)"
      echo ""
    done

# Update Helm chart dependencies
helm-deps:
    #!/usr/bin/env bash
    for chart in platform/*/ gitops/; do
      [ -f "${chart}Chart.yaml" ] && helm dependency update "$chart" 2>/dev/null || true
    done
    echo "Dependencies updated."
