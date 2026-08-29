# ──────────────────────────────────────────────
#  Secured GitOps Homelab — ujust / just recipes
# ──────────────────────────────────────────────

# ── Default ───────────────────────────────────
_default:
    @just --list

# ── Bootstrap ─────────────────────────────────

# Full bootstrap (production) — idempotent; rerun for status check, --force to reapply
init-prod:
    ./bootstrap/init-gitops.sh prod

# Force reapply App-of-Apps (production)
init-prod-force:
    ./bootstrap/init-gitops.sh prod --force

# Full bootstrap (development mode) — idempotent; rerun for status check, --force to reapply
init-dev:
    ./bootstrap/init-gitops.sh dev

# Force reapply App-of-Apps (development)
init-dev-force:
    ./bootstrap/init-gitops.sh dev --force

# ── Vault ─────────────────────────────────────

# Bootstrap Vault (init + unseal only; per-service config via PostSync Jobs)
vault-init:
    ./platform/vault/scripts/bootstrap-vault.sh

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
    set -euo pipefail
    # Derive secret name exactly like platform/vault/scripts/bootstrap-vault.sh
    # (RELEASE_NAME from pod label app.kubernetes.io/instance -> <release>-unseal-keys)
    pod=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod" ]; then
      release=$(kubectl get pod "$pod" -n vault -o jsonpath="{.metadata.labels['app\.kubernetes\.io/instance']}" 2>/dev/null || echo "vault")
    else
      release="vault"
    fi
    # Try derived name first, then both known names as fallback
    candidates=("$release-unseal-keys" "vault-unseal-keys" "vault-dev-unseal-keys")
    secret=""
    for c in "${candidates[@]}"; do
      if kubectl get secret "$c" -n vault >/dev/null 2>&1; then
        secret="$c"
        break
      fi
    done
    if [ -z "$secret" ]; then
      echo "No Vault unseal secret found (tried: ${candidates[*]} in namespace vault)" >&2
      echo "Secrets in vault namespace:" >&2
      kubectl get secrets -n vault -o name 2>/dev/null | sed 's/^/  /' >&2 || true
      echo "Debug: kubectl get secret -n vault -l app.kubernetes.io/instance=vault returns:" >&2
      kubectl get secret -n vault -l app.kubernetes.io/instance=vault -o name 2>&1 | sed 's/^/  /' >&2 || true
      exit 1
    fi
    token=$(kubectl get secret "$secret" -n vault -o jsonpath='{.data.root-token}' | base64 -d || true)
    if [ -z "$token" ]; then
      echo "Secret $secret found but .data.root-token is empty/blank" >&2
      kubectl get secret "$secret" -n vault -o jsonpath='{.data}' 2>&1 | sed 's/^/  /' >&2 || true
      exit 1
    fi
    echo "$token"

# Show cluster nodes and versions
status:
    @echo "=== Nodes ===" && \
    kubectl get nodes -o wide && \
    echo "" && \
    echo "=== Platform ===" && \
    kubectl get pods -n argocd -o name && \
    kubectl get pods -n vault -o name 2>/dev/null && \
    kubectl get pods -n monitoring -o name 2>/dev/null

# ── Validate (local — mirrors CI validate job) ──────

# Run all local validations (gitops + platform + scripts + yaml)
validate:
    @echo "==> validate: running all checks (gitops + platform + scripts + yaml)"
    @just validate-gitops
    @just validate-platform
    @just validate-scripts
    @just validate-yaml
    @echo "✅ validate: all checks passed"

# Validate GitOps App-of-Apps chart (lint + render prod/dev)
validate-gitops:
    #!/usr/bin/env bash
    set -e
    echo "==> helm dependency build (gitops)"
    helm dependency build gitops 2>&1 || echo "no dependencies for gitops chart"
    echo "==> helm lint (prod)"
    helm lint gitops -f gitops/values.yaml
    echo "==> helm lint (dev)"
    helm lint gitops -f gitops/values-dev.yaml
    echo "==> helm template (prod) — empty check"
    helm template gitops gitops -f gitops/values.yaml > /tmp/gitops-prod.yaml
    test -s /tmp/gitops-prod.yaml || (echo "❌ helm template rendered empty (prod)" && exit 1)
    echo "   prod render: $(wc -l < /tmp/gitops-prod.yaml) lines, $(grep -c '^---' /tmp/gitops-prod.yaml || true) documents"
    echo "==> helm template (dev) — empty check"
    helm template gitops gitops -f gitops/values-dev.yaml > /tmp/gitops-dev.yaml
    test -s /tmp/gitops-dev.yaml || (echo "❌ helm template rendered empty (dev)" && exit 1)
    echo "   dev render: $(wc -l < /tmp/gitops-dev.yaml) lines"
    echo "✅ validate-gitops: OK"

# Lint all platform charts (vault, monitoring, seaweedfs, tailscale, longhorn)
validate-platform:
    #!/usr/bin/env bash
    set -e
    # Ensure Helm repos exist for dependency resolution (idempotent)
    helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
    helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm >/dev/null 2>&1 || true
    helm repo add tailscale https://pkgs.tailscale.com/helmcharts >/dev/null 2>&1 || true
    helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    failed=0
    for dir in platform/*/; do
      if [ -f "${dir}Chart.yaml" ]; then
        echo "==> helm dependency build $dir"
        # Use update to handle out-of-sync Chart.lock (e.g. vault)
        helm dependency update "$dir" 2>&1 || helm dependency build "$dir" 2>&1 || echo "   no deps / already built for $dir"
        echo "==> helm lint $dir"
        if ! helm lint "$dir"; then
          echo "❌ helm lint failed for $dir"
          failed=1
        fi
      fi
    done
    test "$failed" = "0" || exit 1
    echo "✅ validate-platform: OK"

# ShellCheck bootstrap scripts (soft-fail if not installed)
validate-scripts:
    #!/usr/bin/env bash
    set -e
    if ! command -v shellcheck >/dev/null 2>&1; then
      echo "⚠️  shellcheck not found — skipping (install with: sudo apt install shellcheck / brew install shellcheck)"
      echo "   CI will still run shellcheck; local check is non-blocking"
      exit 0
    fi
    echo "==> shellcheck bootstrap/init-gitops.sh"
    shellcheck bootstrap/init-gitops.sh
    echo "==> shellcheck platform/vault/scripts/bootstrap-vault.sh"
    shellcheck platform/vault/scripts/bootstrap-vault.sh
    echo "✅ validate-scripts: OK"

# YAML syntax sanity (PyYAML) — skip Helm templates
validate-yaml:
    #!/usr/bin/env bash
    set -e
    echo "==> YAML sanity (python yaml)"
    python3 - << 'PY'
    import glob, sys
    try:
        import yaml
    except ImportError:
        print("PyYAML not available — skipping")
        sys.exit(0)
    errors = 0
    for f in glob.glob("**/*.yaml", recursive=True) + glob.glob("**/*.yml", recursive=True):
        # skip Helm templates and vendored charts
        if "/templates/" in f or "/charts/" in f or f.startswith("platform/longhorn/charts/"):
            continue
        with open(f) as fh:
            content = fh.read()
        # skip files with Go templating
        if chr(123)*2 in content or chr(123)+"%" in content:
            continue
        try:
            list(yaml.safe_load_all(content))
        except Exception as e:
            print(f"❌ YAML parse error in {f}: {e}")
            errors += 1
    if errors:
        sys.exit(1)
    print("   YAML sanity: OK")
    PY
    # resolve yamllint (brew/pip binary or python module)
    YAMLLINT=""
    if command -v yamllint >/dev/null 2>&1; then YAMLLINT="yamllint"; elif python3 -m yamllint --help >/dev/null 2>&1; then YAMLLINT="python3 -m yamllint"; fi
    if [ -n "$YAMLLINT" ]; then
      echo "==> yamllint gitops/ platform/ bootstrap/ (.yamllint.yaml)"
      $YAMLLINT -c .yamllint.yaml gitops/ platform/ bootstrap/ 2>&1 || echo "⚠️ yamllint reported issues (non-blocking)"
    else
      echo "   yamllint not installed — skipping (pip install yamllint / brew install yamllint)"
    fi
    echo "✅ validate-yaml: OK"

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
