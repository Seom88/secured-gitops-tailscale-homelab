# Sync Waves

ArgoCD sync waves control the order of resource creation. Lower numbers deploy first. Resources within the same wave are created in parallel.

## Current Configuration

| Order | Sync-wave | Component | Description |
|-------|-----------|-----------|-------------|
| 1 | `-5` | `vault` (chart) | Deploys Vault using HashiCorp Helm chart |
| 2 | `-4` | `vault-unseal-job` | Unseals Vault using keys from `vault-unseal-keys` secret |
| 3 | `-3` | `vault-seed-job` | Creates initial secrets in Vault (e.g., `secret/tailscale/auth`) |
| 4 | `-2` | `argocd-sync` | ArgoCD manages its own versioning via `platform/argocd/` chart |
| 5 | `-2` | `eso-sync` | Installs External Secrets Operator + creates `ClusterSecretStore` and `ExternalSecret` |
| 6 | `-1` | `tailscale-operator` | Deploys Tailscale operator using credentials from Vault via ESO |

## How It Works

1. **Vault** (`-5`): Deployed first via HashiCorp Helm chart
2. **Vault Unseal** (`-4`): Job that unseals Vault using the keys generated during `01-vault-init.sh`
3. **Vault Seed** (`-3`): Creates initial secrets in Vault (path: `secret/tailscale/auth`)
4. **ArgoCD** (`-2`): Self-managed via its own Application manifest, allowing version control through Git commits
5. **ESO** (`-2`): External Secrets Operator reads from Vault using `ClusterSecretStore` (path: `secret/`)
6. **Tailscale** (`-1`): Uses the `operator-oauth` secret created by ESO

## Bootstrap Flow

```bash
# 1. Initialize Vault (installs Vault + creates unseal keys)
./bootstrap/01-vault-init.sh

# 1.5. Dont forget change secrets on vault ui.

# 2. Initialize ArgoCD (applies root-prod-app.yaml, ArgoCD manages itself)
./bootstrap/02-k8s-init.sh
```
