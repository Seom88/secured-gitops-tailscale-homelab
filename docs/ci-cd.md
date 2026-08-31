# CI / CD

> GitHub Actions, Helm validation, shell linting, and Renovate — how quality is enforced and GitOps stays healthy.

[← Back to README](../README.md) · [Getting Started →](./getting-started.md) · [Architecture →](./features-deep-dive.md)

## Workflows

Both workflows live in `.github/workflows/` and are distro-agnostic — no Terraform, no cluster required for validation. `deploy.yaml` is the only workflow that touches the cluster (via Tailscale + kubeconfig from infra state) and delegates all logic to `bootstrap/init-gitops.sh`.

| Workflow | Trigger | Needs cluster | What it does |
|----------|---------|---------------|--------------|
| `validate.yaml` | `push` + `pull_request` (all branches) | No | Helm lint/template, platform lint, shellcheck, YAML/JSON sanity |
| `deploy.yaml` | `workflow_dispatch` (manual) | Yes | Restore kubeconfig from infra state → `bootstrap/init-gitops.sh` |

### `deploy.yaml` — Deploy GitOps (manual)

Triggers: `workflow_dispatch` only (manual from GitHub UI / `gh`). Concurrency `deploy-${{ github.ref_name }}` (`cancel-in-progress: false`), `environment: ${{ inputs.environment || 'prod' }}`.

```yaml
# .github/workflows/deploy.yaml — triggers
on:
  workflow_dispatch:
    inputs:
      environment:
        description: Target environment
        type: choice
        options: [prod, dev]
        default: prod
      force_reapply:
        description: Force reapply even if App-of-Apps already exists
        type: boolean
        default: false

permissions:
  contents: read

concurrency:
  group: deploy-${{ github.ref_name }}
  cancel-in-progress: false

env:
  HELM_VERSION: v3.18.4
  S3_ENDPOINT: https://rustfs.lonk-mirfak.ts.net
  S3_BUCKET: terraform-homelab
```

| Job | Runs | What it does |
|-----|------|--------------|
| `deploy` | manual (`workflow_dispatch`) | Restore kubeconfig from infra S3 state + Tailscale, run `bootstrap/init-gitops.sh` |

**Deploy job** (`runs-on: ubuntu-latest`, `timeout-minutes: 15`, `environment: ${{ inputs.environment || 'prod' }}`):

1. `checkout` secure repo — `actions/checkout@v7` with `persist-credentials: false`
2. `checkout` infra repo — `actions/checkout@v7` with `repository: Seom88/infra-talos-homelab`, `path: infra`, `token: ${{ secrets.GH_PAT || secrets.GITHUB_TOKEN }}`, `persist-credentials: false` (needs `GH_PAT` to read the private infra state repo)
3. `setup-terraform` — `hashicorp/setup-terraform@v4` with `terraform_wrapper: false` (only for `terraform output` to fetch kubeconfig; no apply)
4. `setup-kubectl` — `azure/setup-kubectl@v5`
5. `setup-helm` — `azure/setup-helm@v5` with `version: ${{ env.HELM_VERSION }}` (`v3.18.4`)
6. `install jq / yq` — `jq --version` + `wget mikefarah/yq` if `yq` missing, `yq --version`
7. `tailscale/github-action@v4` with `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` (`tags: tag:terraform`, `use-cache: 'true'`) — subnet-route reachability to the cluster (Tailscale mesh, no exposed ports)
8. `restore kubeconfig from infra state` (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`):
   ```bash
   ENV="${{ inputs.environment || 'prod' }}"
   TF_DIR="infra/environments/proxmox/${ENV}"
   terraform -chdir="$TF_DIR" init -reconfigure -input=false
   terraform -chdir="$TF_DIR" output -raw kubeconfig > /tmp/kubeconfig.yaml
   # fallback if output fails:
   aws s3api get-object --bucket $S3_BUCKET --key "proxmox/${ENV}/terraform.tfstate" \
     --endpoint-url $S3_ENDPOINT /tmp/tfstate.json
   jq -r '.outputs.kubeconfig.value // empty' /tmp/tfstate.json > /tmp/kubeconfig.yaml
   chmod 600 /tmp/kubeconfig.yaml
   echo "KUBECONFIG=/tmp/kubeconfig.yaml" >> "$GITHUB_ENV"
   KUBECONFIG=/tmp/kubeconfig.yaml kubectl cluster-info --request-timeout=10s
   KUBECONFIG=/tmp/kubeconfig.yaml kubectl get nodes --request-timeout=10s
   ```
   Fails fast if `infra/environments/proxmox/${ENV}` is missing or resulting kubeconfig is empty.
9. `bootstrap (delegates to init-gitops.sh — single source of truth)` (`KUBECONFIG=/tmp/kubeconfig.yaml`):
   ```bash
   ENV="${{ inputs.environment || 'prod' }}"
   FORCE="--force" # only if inputs.force_reapply == true
   chmod +x bootstrap/init-gitops.sh platform/vault/scripts/bootstrap-vault.sh
   ./bootstrap/init-gitops.sh "$ENV" $FORCE
   ```
   `init-gitops.sh` is idempotent: `helm upgrade --install gitops`, Longhorn CSI gate (wave 0), `ensureVeleroCredentials()` (see [Velero](./velero.md)), `bootstrap-vault.sh`, status verifier. See [Getting Started](./getting-started.md).
10. `cleanup kubeconfig` (`if: always()`) — `shred -u /tmp/kubeconfig.yaml || rm -f /tmp/kubeconfig.yaml /tmp/tfstate.json`

> `deploy.yaml` never runs `terraform apply` — infra is owned by `infra-talos-homelab`. This repo only fetches kubeconfig and delegates to `bootstrap/init-gitops.sh`, which in turn applies the ArgoCD App-of-Apps (`gitops/` chart, wave-ordered).

**Required GitHub secrets:**

| Secret | Required | Value |
|--------|----------|-------|
| `TS_OAUTH_CLIENT_ID` | yes | Tailscale OAuth client ID (`tag:terraform`, scopes `devices:core:write` + `auth_keys:write`) |
| `TS_OAUTH_SECRET` | yes | Tailscale OAuth client secret |
| `GH_PAT` | yes (private infra) | GitHub PAT with `repo` read to `Seom88/infra-talos-homelab` (`checkout infra` step); falls back to `GITHUB_TOKEN` if infra is public |
| `AWS_ACCESS_KEY_ID` | yes | RustFS S3 access key (bucket `terraform-homelab`, path-style, `S3_ENDPOINT`) |
| `AWS_SECRET_ACCESS_KEY` | yes | RustFS S3 secret key |
| `VELERO_AWS_ACCESS_KEY_ID` | no | Optional override for Velero bucket `velero-homelab` — if unset, `AWS_*` fallback via `ensureVeleroCredentials()` |
| `VELERO_AWS_SECRET_ACCESS_KEY` | no | Idem — see [Velero](./velero.md) |
| `PROXMOX_API_TOKEN` | no | Not used in this repo (infra repo owns Proxmox); listed only if you fork both repos with shared secrets |

To use from a fork, configure `tagOwners` / `acls` for `tag:terraform → tag:pve` in your Tailscale ACL and set `GH_PAT` so the workflow can clone the (private) infra repo. The `S3_ENDPOINT` / `S3_BUCKET` envs point at RustFS (`https://rustfs.lonk-mirfak.ts.net`).

### `validate.yaml` — Validate (fast feedback, no cluster)

Triggers: `push` + `pull_request` (all branches). Concurrency `validate-${{ github.ref_name }}` (`cancel-in-progress: true`). No cluster, no creds.

```yaml
# .github/workflows/validate.yaml — triggers
on:
  push:
  pull_request:

permissions:
  contents: read

concurrency:
  group: validate-${{ github.ref_name }}
  cancel-in-progress: true

env:
  HELM_VERSION: v3.18.4

jobs:
  validate:
    runs-on: ubuntu-latest
    timeout-minutes: 10
```

| Step | What it does |
|------|--------------|
| `checkout` | `actions/checkout@v7` `persist-credentials: false` |
| `setup-helm` | `azure/setup-helm@v5` `version: v3.18.4` |
| `helm dependency build (gitops)` | `helm dependency build gitops` (no-op if no deps) |
| `helm dependency build (platform charts)` | `helm repo add` longhorn/grafana/prometheus-community/seaweedfs/tailscale/hashicorp + `helm repo update`; loop `platform/*/` → `helm dependency update/build` |
| `lint gitops (prod)` | `helm lint gitops -f gitops/values.yaml` |
| `lint gitops (dev)` | `helm lint gitops -f gitops/values-dev.yaml` |
| `render gitops (prod) — empty check` | `helm template gitops gitops -f gitops/values.yaml > /tmp/gitops-prod.yaml` + `test -s` + `wc -l` + `grep -c '^---'` + `head -n 80` |
| `render gitops (dev) — empty check` | `helm template gitops gitops -f gitops/values-dev.yaml > /tmp/gitops-dev.yaml` + `test -s` |
| `lint platform charts` | Loop `platform/*/` with `Chart.yaml` → `helm lint "$dir"` (fail aggregated via `failed` flag) |
| `shellcheck` | Install `shellcheck` if missing (`apt-get`); `shellcheck bootstrap/init-gitops.sh` + `shellcheck platform/vault/scripts/bootstrap-vault.sh` |
| `yaml sanity` | `python3` + `yaml.safe_load_all` over `**/*.yaml` skipping `/templates/` `/charts/` `platform/longhorn/charts/` and Go templates (`{{`/`{%`) |
| `json sanity` | `python3 -m json.tool` over `**/*.json` skipping `charts/.git/node_modules`; warn if `renovate.json` missing |
| `yamllint` | `continue-on-error: true` — `pip install yamllint`, `yamllint -c .yamllint.yaml gitops/ platform/ bootstrap/` (templates ignored, `helm lint` owns them) |

Local equivalent: `just validate` (same checks, no creds). Sub-recipes: `just validate-gitops`, `just validate-platform`, `just validate-scripts`, `just validate-yaml`, `just validate-json`.

## Quality gates

| Gate | How | Where |
|------|-----|-------|
| Helm lint | `helm lint gitops -f gitops/values{,-dev}.yaml` + `helm lint platform/*/` | `validate.yaml`, `just validate-gitops`, `just validate-platform` |
| Helm template | `helm template gitops gitops -f gitops/values{,-dev}.yaml` + empty/manifest count check | `validate.yaml`, `just validate-gitops` |
| Helm dependencies | `helm dependency build/update gitops` + `platform/*/` (with `helm repo add` for 6 repos) | `validate.yaml`, `just validate-platform`, `just helm-deps` |
| Shell lint | `shellcheck bootstrap/init-gitops.sh` + `platform/vault/scripts/bootstrap-vault.sh` | `validate.yaml`, `just validate-scripts` |
| YAML syntax | `PyYAML safe_load_all` (Helm templates skipped) + `.yamllint.yaml` | `validate.yaml`, `just validate-yaml` |
| JSON syntax | `python3 -m json.tool` over `**/*.json` | `validate.yaml`, `just validate-json` |
| Full local CI | `just validate` (gitops + platform + scripts + yaml + json) | `justfile` |
| Hardened inputs | `helm lint` strict, `null` guards in bootstrap, CSI wait gate before Vault | [Getting Started](./getting-started.md), `bootstrap/init-gitops.sh` |

## Justfile

`just` is the local task runner — all CI checks have a local mirror.

| Recipe | What it does |
|--------|--------------|
| `init-prod` | `./bootstrap/init-gitops.sh prod` — full bootstrap (idempotent, status verifier if App-of-Apps exists) |
| `init-prod-force` | `./bootstrap/init-gitops.sh prod --force` — reapply App-of-Apps even if it exists |
| `init-dev` | `./bootstrap/init-gitops.sh dev` — same with `gitops/values-dev.yaml` |
| `init-dev-force` | `./bootstrap/init-gitops.sh dev --force` |
| `vault-init` | `./platform/vault/scripts/bootstrap-vault.sh` — init + unseal only (per-service config via PostSync Jobs) |
| `pf-argocd` | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| `pf-vault` | `kubectl port-forward svc/vault -n vault 8200:8200` |
| `pf-prometheus` | `kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090` |
| `pf-grafana` | `kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80` |
| `argocd-password` | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| `vault-token` | Derive `vault-unseal-keys` secret name from pod label `app.kubernetes.io/instance` + `kubectl get secret ... -o jsonpath='{.data.root-token}' \| base64 -d` |
| `status` | `kubectl get nodes -o wide` + `kubectl get pods -n argocd/vault/monitoring` |
| `validate` | Runs all local validations (`validate-gitops` + `validate-platform` + `validate-scripts` + `validate-yaml` + `validate-json`) — mirrors `validate.yaml` |
| `validate-gitops` | `helm dependency build` + `helm lint` prod/dev + `helm template` prod/dev empty check |
| `validate-platform` | `helm repo add` (6 repos) + `helm dependency update/build` + `helm lint` per `platform/*/` |
| `validate-scripts` | `shellcheck bootstrap/init-gitops.sh` + `platform/vault/scripts/bootstrap-vault.sh` (soft-fail if missing) |
| `validate-yaml` | `PyYAML` sanity + `yamllint -c .yamllint.yaml gitops/ platform/ bootstrap/` |
| `validate-json` | `python3 -m json.tool` over `**/*.json` |
| `sync` | `kubectl apply -n argocd -f gitops/` — force ArgoCD sync (App-of-Apps) |
| `diff` | `helm diff upgrade --install gitops gitops/ -n argocd -f gitops/values.yaml` or `helm template` fallback |
| `docs` | `ls -1 docs/*.md docs/**/*.md` |
| `check` | Verify `kubectl`/`helm`/`git`/`jq` are installed |
| `helm-dry-run` | `helm template` per `platform/*/` + `head -3` |
| `helm-deps` | `helm dependency update` per `platform/*/` + `gitops/` |

## Renovate

`renovate.json` runs weekly **Monday before 05:00 `Europe/Madrid`**, `config:recommended`, labels `dependencies`, ignores `**/charts/*.tgz`:

| Rule | Datasource | Group / Label | Automerge |
|------|------------|---------------|-----------|
| Vault HA Raft + TLS + auto-unseal — wave 1 healthy — needs manual review | `helm` `vault` | `manual-review/vault` | `false` |
| Longhorn storage — needs manual validation (CSI-gated wave 0) | `helm` `longhorn` | `manual-review/longhorn` | `false` |
| cert-manager wave-0 healthy — needs manual review before wave 1 | `helm` `cert-manager` | `manual-review/cert-manager` | `false` |
| Group non-critical Helm charts (loki, kube-prometheus-stack, seaweedfs, tailscale-operator, external-secrets) | `helm` excl. vault/longhorn/cert-manager | `helm charts` (`helm-charts`), `helm` | grouped PR |
| Group GitHub Actions | `github-actions` | `github actions` (`github-actions`), `github-actions` | grouped PR |

No custom regex managers — Helm versions are pinned in `Chart.yaml` / `values.yaml` and picked up natively. Validate Vault/Longhorn/cert-manager upgrades via `just validate` + `helm template` before merging.

## Velero bootstrap

Velero lives outside Vault/ESO (chicken-egg: it backs up Vault). Credentials are injected as an ephemeral `Secret velero/cloud-credentials` by `bootstrap/init-gitops.sh:ensureVeleroCredentials()` (prefers `VELERO_AWS_*`, falls back to `AWS_*`; reuses the S3 creds already injected by `deploy.yaml`). The chart consumes it via `credentials.existingSecret: cloud-credentials` and a wave `-1` `Job velero-bucket-init` creates the `velero-homelab` bucket idempotently before wave `0`.

Details, bucket creation, verification, and troubleshooting: **[Velero →](./velero.md)**.

---

Next: [Getting Started →](./getting-started.md) · [Features →](./features-deep-dive.md) · [ADRs →](./adrs/) · [Velero →](./velero.md)
