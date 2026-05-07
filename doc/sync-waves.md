# Sync Waves (Installation Order)

ArgoCD deploys components in a specific order. Components with lower numbers are deployed first. Resources within the same wave are created in parallel.

> **Why order matters**: Some components depend on others being ready. For example, you can't connect External Secrets to Vault if Vault hasn't been initialized or if the certificates aren't ready.

## Current Order

| Step | Wave | Component | What it does |
|------|------|-----------|--------------|
| 1 | `-7` | `cert-manager` | Manages TLS certificates (HTTPS) for Vault and other services |
| 2 | `-6` | `vault` | Deploys HashiCorp Vault with TLS and Auto-unseal sidecar |
| 3 | `-5` | `vault-certs` | Creates Issuer and Certificate (managed by cert-manager) for Vault |
| 4 | `-4` | `eso-operator` | Installs the External Secrets Operator and its CRDs |
| 5 | `-3` | `eso-config` | Creates ClusterSecretStore and ExternalSecrets (connects to Vault) |
| 6 | `-1` | `tailscale` | Deploys Tailscale operator and secure Ingresses |

## How It Works (Step-by-Step)

1. **cert-manager** (`-7`): Before Vault starts, we need the operator that handles certificates. cert-manager is installed first.

2. **Vault** (`-6`): Installs with TLS enabled. It starts with an **Auto-unseal sidecar** container. This container waits for the `vault-unseal-keys` secret (created during bootstrap) and automatically unseals Vault whenever the pod restarts.

3. **Vault Certs** (`-5`): These are the `Issuer` and `Certificate` resources. cert-manager uses them to generate the `vault-tls` secret, which Vault needs for HTTPS.

4. **ESO Operator** (`-4`): Installs the External Secrets Operator. ArgoCD automatically waits until the operator is fully operational before moving to the next steps. This ensures that the system is ready to handle secrets before we try to configure them.

5. **ESO Config** (`-3`): Configures the connection to Vault and sets up the secret definitions. ArgoCD verifies that the connection to Vault is established and working correctly before proceeding, which prevents potential errors during the setup phase.

6. **Tailscale** (`-1`): Installs the Tailscale operator using the credentials synced by ESO. It also creates the **Ingress** resources that allow secure access to the cluster services.

## Ingress Management

To avoid circular dependencies, all Tailscale-managed access is centralized in `platform/tailscale`. This ensures that secure access points are only created once the Tailscale operator is fully ready to handle them.

## Bootstrap Flow

The `01-init-gitops.sh` script is run **only once** when setting up the cluster for the first time. It performs the following:

```bash
# Initialize the cluster and ArgoCD
./bootstrap/01-init-gitops.sh
```

The script:
- Installs ArgoCD
- Installs cert-manager
- Applies the Vault Application
- Waits for the TLS certificate to be ready
- Initializes Vault and saves unseal keys as a Kubernetes Secret
- Unseals Vault for the first time
- Configures Vault (auth methods, policies, roles)
- Seeds initial secrets (Tailscale credentials)
- Applies the root Application (which manages everything else via GitOps)
