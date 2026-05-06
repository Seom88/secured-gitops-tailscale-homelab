# Sync Waves

ArgoCD sync waves control the order of resource creation. Lower numbers deploy first. Resources within the same wave are created in parallel.

## Current Configuration

| Order | Sync-wave | Component | Description |
|-------|-----------|-----------|-------------|
| 1 | `-6` | `cert-manager` | Manages TLS certificates via cert-manager.io |
| 2 | `-5` | `vault` (chart) | Deploys Vault using HashiCorp Helm chart |
| 3 | `-4` | `vault-unseal-job` | Unseals Vault using keys from `vault-unseal-keys` secret |
| 4 | `-3` | `kubevault` | Configures Vault via CRDs: SecretEngine, VaultPolicy, VaultPolicyBinding |
| 5 | `-2` | `eso-sync` | Installs External Secrets Operator + creates `ClusterSecretStore` and `ExternalSecret` |
| 6 | `-1` | `tailscale-operator` | Deploys Tailscale operator using credentials from Vault via ESO |

## How It Works

1. **Cert-Manager** (`-6`): Manages TLS certificates (Vault TLS, etc.) using cert-manager.io
2. **Vault** (`-5`): Deployed first via HashiCorp Helm chart
3. **Vault Unseal** (`-4`): Job that unseals Vault using the keys generated during `01-vault-init.sh`
4. **KubeVault** (`-3`): Configures Vault (KV engine, policies, roles) via CRDs
5. **ESO** (`-2`): External Secrets Operator reads from Vault using `ClusterSecretStore` (path: `secret/`)
6. **Tailscale** (`-1`): Uses the `operator-oauth` secret created by ESO

## Bootstrap Flow

```bash
# 1. Initialize Vault (installs Vault + creates unseal keys)
./bootstrap/01-vault-init.sh
