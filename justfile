# ──────────────────────────────────────────────
#  Secured GitOps Homelab — ujust / just recipes
# ──────────────────────────────────────────────

# Auto-load .env if present — secrets for k8s (see .env.example)
# .env is gitignored; every recipe inherits K8S_TS_OAUTH_* / VELERO_AWS_*
set dotenv-load

# ── Default ───────────────────────────────────
_default:
    @just --list

# ── Bootstrap ─────────────────────────────────

# Full bootstrap (production) — idempotent; rerun for status check, --force to reapply
init-prod:
    just secrets-apply
    ./bootstrap/init-gitops.sh prod

# Force reapply App-of-Apps (production)
init-prod-force:
    just secrets-apply
    ./bootstrap/init-gitops.sh prod --force

# Full bootstrap (development mode) — idempotent; rerun for status check, --force to reapply
init-dev:
    just secrets-apply
    ./bootstrap/init-gitops.sh dev

# Force reapply App-of-Apps (development)
init-dev-force:
    just secrets-apply
    ./bootstrap/init-gitops.sh dev --force

# ── Secrets (.env → k8s) ────────────────────────

# Init .env from .env.example (no overwrite)
secrets-init:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f .env ]; then
      echo "✅ .env ya existe — no se sobrescribe (borralo primero si querés regenerarlo)"
      exit 0
    fi
    if [ ! -f .env.example ]; then
      echo "❌ .env.example no encontrado" >&2; exit 1
    fi
    cp .env.example .env
    echo "✅ .env creado desde .env.example — completá los valores y luego: just secrets-apply"

# Check .env vs .env.example — keys faltantes / valores vacíos / placeholders
secrets-check:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f .env.example ]; then
      echo "❌ .env.example no encontrado" >&2; exit 1
    fi
    if [ ! -f .env ]; then
      echo "❌ .env no encontrado — crealo con: just secrets-init  (o cp .env.example .env)" >&2
      exit 1
    fi
    echo "==> .env vs .env.example"
    missing=0; empty=0; placeholder=0
    while IFS='=' read -r key _; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
      key=$(echo "$key" | xargs)
      [ -z "$key" ] && continue
      if ! grep -q "^${key}=" .env; then
        echo "  ❌ falta en .env: $key"; missing=$((missing+1))
      else
        val=$(grep "^${key}=" .env | cut -d'=' -f2-)
        if [ -z "$val" ]; then
          echo "  ⚠️  vacío en .env: $key"; empty=$((empty+1))
        elif [ "$val" = "..." ] || [ "$val" = "changeme" ] || [ "$val" = "CHANGEME" ]; then
          echo "  ⚠️  placeholder sin completar en .env: $key=$val"; placeholder=$((placeholder+1))
        fi
      fi
    done < .env.example
    if [ "$missing" = 0 ] && [ "$empty" = 0 ] && [ "$placeholder" = 0 ]; then
      echo "✅ .env OK — todas las keys de .env.example presentes y con valor"
    else
      echo ""
      echo "Resumen: $missing faltantes, $empty vacías, $placeholder placeholders"
      [ "$missing" != 0 ] && exit 1 || true
      [ "$placeholder" != 0 ] && exit 1 || true
    fi

# Carga .env → k8s Secrets (idempotente, re-ejecutable)
#   tailscale/operator-oauth  {client_id, client_secret}  <- K8S_TS_OAUTH_*
# velero/cloud-credentials  {cloud: "[default]\\naws_access_key_id=..."} <- VELERO_AWS_*
secrets-apply:
    #!/usr/bin/env bash
    set -euo pipefail
    # Carga explícita de .env por si just se invoca con --no-dotenv o fuera de just
    if [ -f .env ]; then
      set -a; source .env; set +a
    fi
    if [ ! -f .env ]; then
      echo "⚠️  .env no encontrado — usando env del shell / CI (GitHub Secrets)" >&2
    fi
    echo "==> secrets-apply (.env → k8s)"

    # ── Tailscale ──────────────────────────────────
    TS_ID="${K8S_TS_OAUTH_CLIENT_ID:-}"
    TS_SECRET="${K8S_TS_OAUTH_SECRET:-}"
    if [ -z "$TS_ID" ] || [ -z "$TS_SECRET" ] || [ "$TS_ID" = "..." ] || [ "$TS_SECRET" = "..." ]; then
      echo "  ⏭️  Tailscale: sin credenciales válidas (K8S_TS_OAUTH_CLIENT_ID / K8S_TS_OAUTH_SECRET) — skip"
      echo "     Tip: completá .env y reintentá, o exportá las vars en el shell"
    else
      echo "  🔐 Tailscale: creando/actualizando Secret tailscale/operator-oauth..."
      kubectl get namespace tailscale >/dev/null 2>&1 || kubectl create namespace tailscale >/dev/null 2>&1
      kubectl create secret generic operator-oauth \
        --namespace tailscale \
        --from-literal=client_id="$TS_ID" \
        --from-literal=client_secret="$TS_SECRET" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      echo "  ✅ Tailscale: Secret tailscale/operator-oauth listo"
      kubectl rollout restart deployment/tailscale-operator -n tailscale >/dev/null 2>&1 || \
        kubectl rollout restart deployment/operator -n tailscale >/dev/null 2>&1 || true
    fi

    # ── Velero (RustFS S3) ─────────────────────────
    VELERO_ID="${VELERO_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
    VELERO_SECRET_VAL="${VELERO_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
    if [ -z "$VELERO_ID" ] || [ -z "$VELERO_SECRET_VAL" ] || [ "$VELERO_ID" = "..." ] || [ "$VELERO_SECRET_VAL" = "..." ]; then
      echo "  ⏭️  Velero: sin credenciales S3 válidas (VELERO_AWS_ACCESS_KEY_ID / VELERO_AWS_SECRET_ACCESS_KEY) — skip"
    else
      echo "  🛡️  Velero: creando/actualizando Secret velero/cloud-credentials..."
      kubectl get namespace velero >/dev/null 2>&1 || kubectl create namespace velero >/dev/null 2>&1
      CLOUD_CONTENT="[default]
    aws_access_key_id=${VELERO_ID}
    aws_secret_access_key=${VELERO_SECRET_VAL}"
      kubectl create secret generic cloud-credentials \
        --namespace velero \
        --from-literal=cloud="$CLOUD_CONTENT" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      echo "  ✅ Velero: Secret velero/cloud-credentials listo"
    fi

    echo "✅ secrets-apply: done (revisá con: just secrets-status)"

# Estado de los Secrets en k8s (sin exponer valores)
secrets-status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> k8s Secrets (masked)"
    echo "  tailscale/operator-oauth:"
    if kubectl get secret operator-oauth -n tailscale >/dev/null 2>&1; then
      echo "    ✅ existe — keys: $(kubectl get secret operator-oauth -n tailscale -o jsonpath='{.data}' | tr ',' '\\n' | cut -d'\"' -f2 | paste -sd ', ' -)"
      echo "    client_id len: $(kubectl get secret operator-oauth -n tailscale -o jsonpath='{.data.client_id}' | base64 -d | wc -c | xargs) chars"
    else
      echo "    ❌ no existe"
    fi
    echo "  velero/cloud-credentials:"
    if kubectl get secret cloud-credentials -n velero >/dev/null 2>&1; then
      echo "    ✅ existe — key 'cloud' presente: $(kubectl get secret cloud-credentials -n velero -o jsonpath='{.data.cloud}' | base64 -d | head -1)"
    else
      echo "    ❌ no existe"
    fi

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

# Run all local validations (gitops + platform + scripts + yaml + json)
validate:
    @echo "==> validate: running all checks (gitops + platform + scripts + yaml + json)"
    @just validate-gitops
    @just validate-platform
    @just validate-scripts
    @just validate-yaml
    @just validate-json
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

# JSON syntax sanity (python -m json.tool)
validate-json:
    #!/usr/bin/env bash
    set -e
    echo "==> JSON sanity (python3 -m json.tool)"
    errors=0
    for f in $(find . -type f -name "*.json" -not -path "*/charts/*" -not -path "*/.git/*" -not -path "*/node_modules/*"); do
      echo "  checking $f..."
      if ! python3 -m json.tool "$f" > /dev/null; then
        echo "❌ JSON parse error in $f"
        errors=$((errors+1))
      else
        echo "  OK  $f"
      fi
    done
    if [ ! -f renovate.json ]; then
      echo "⚠️  renovate.json not found"
    fi
    if [ "$errors" != "0" ]; then
      echo "❌ $errors JSON file(s) failed validation"
      exit 1
    fi
    echo "✅ validate-json: OK"

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
