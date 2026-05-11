# Sync Waves (Installation Order)

ArgoCD deploys components in a specific order using **Sync Waves**. Components with lower numbers are deployed first. Resources within the same wave are created in parallel.

> **Why order matters**: Some components depend on others being ready. For example, you can't connect External Secrets to Vault if Vault hasn't been initialized or if the TLS certificates aren't available.

## Global Orchestration (App-of-Apps)

The project follows a modular architecture where the `gitops/` chart acts as the Root Application, orchestrating the installation of the platform components.

| Step | Wave | Component | What it does |
|------|------|-----------|--------------|
| 1 | `0` | `cert-manager` | Manages TLS certificates (HTTPS) for Vault and internal services |
| 2 | `1` | `vault` | Deploys HashiCorp Vault. Includes internal wave `-1` for TLS certs and a `PostSync` hook for auto-configuration |
| 3 | `2` | `eso-operator` | Installs External Secrets Operator and connects it to Vault via `ClusterSecretStore` |
| 4 | `3` | `tailscale` | Deploys Tailscale operator and secure Ingresses for the platform |

## How It Works (Step-by-Step)

1. **cert-manager** (`Wave 0`): The foundation for cluster trust. It must be ready before Vault starts to ensure the `Certificate` resources can be fulfilled.

2. **Vault** (`Wave 1`): 
   - **TLS First**: Inside the Vault chart, certificates are created in wave `-1` to ensure the `vault-tls` secret exists before the StatefulSet starts.
   - **Automated Setup**: A `PostSync` Job runs the `setup-vault.sh` script, which handles initialization, unsealing (using keys from a K8s secret), and configuring auth methods/policies.

3. **ESO Operator** (`Wave 2`): 
   - Installs the operator and its CRDs.
   - **SecretStore**: The `ClusterSecretStore` (Wave 1 inside the ESO app) connects to Vault using the Kubernetes auth method configured in the previous step.

4. **Tailscale** (`Wave 3`): 
   - The final layer. It uses the `ExternalSecret` synced by ESO to authenticate with the Tailscale control plane.
   - Centralizes all **Ingress** management to avoid circular dependencies and ensure secure access points are created only when the operator is ready.

## Bootstrap Flow

The `01-init-gitops.sh` script initializes the entire system. Since ArgoCD is now a dependency of the GitOps chart, the process is streamlined:

```bash
# Initialize the cluster and the Root Application
./bootstrap/01-init-gitops.sh
```

**The script performs the following:**
1. **Installs ArgoCD**: Deploys the `argo-cd` sub-chart using the base configuration.
2. **Applies Root App**: Deploys the `gitops` chart itself as an ArgoCD Application, which triggers the global sync waves.
3. **Waits for Vault**: Monitors the `vault-setup` Job until completion.
4. **Seeds Secrets**: Extracts the Vault root token and seeds the initial Tailscale credentials directly into Vault's KV store.

## Ingress Management

To maintain a clean separation of concerns, all secure access (ArgoCD UI, Vault UI, etc.) is managed via Tailscale Ingresses located in `platform/tailscale/templates/platform/`. This ensures that public/private access is only enabled once the security stack is fully operational.
