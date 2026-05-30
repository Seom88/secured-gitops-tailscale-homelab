# Getting Started

This guide provides the steps to initialize the Homelab GitOps environment, including the setup of HashiCorp Vault for secret management and ArgoCD for continuous delivery.


## Prerequisites

- A running Kubernetes cluster (see [k3s-install.md](k3s-install.md) for a reference setup).
- `kubectl` configured to point to your cluster.
- `helm` installed locally.
- `jq` installed locally.
- [`just`](https://github.com/casey/just) installed locally (command runner — all common operations are available as recipes).

## 1. Bootstrap the Environment

Run the initialization script to configure the foundation of your GitOps flow (Storage, Vault, External Secrets, and ArgoCD). You can choose between `prod` (default) and `dev` environments using the `just` recipes:

```bash
# For production (default)
just init-prod

# For development
just init-dev
```

> [!TIP]
> The raw scripts are also available at `./bootstrap/01-init-gitops.sh [prod|dev]` if you prefer running them directly.

> [!IMPORTANT]
> - The script will prompt for your **Tailscale Client ID** and **Secret** if they are not already set as environment variables (`TS_CLIENT_ID` and `TS_CLIENT_SECRET`).
> - It also initializes the Vault operator and sets up the root ArgoCD application. Wait for the script to finish before proceeding.

## 2. Configure Vault

The bootstrap script automatically initializes Vault and configures the necessary secrets engines. 

### Access Vault UI

1. **Get the root token**:
   The script prints the root token at the end, but you can always retrieve it with a `just` recipe:
   ```bash
   just vault-token
   ```
   > [!NOTE]
   > This automatically finds the Vault unseal secret regardless of environment (prod/dev). The underlying command is `kubectl -n vault get secret <name> -o jsonpath="{.data.root-token}" | base64 -d`.
2. **Start port-forwarding**:
   ```bash
   just pf-vault
   ```
3. **Login**: Go to [https://localhost:8200](https://localhost:8200) and use the token from step 1.

> [!TIP]
> Once inside, follow the [Secret Structure guide](secrets-structure.md) to organize your secrets correctly. The automation already sets up the `secret/` KV engine.


## 3. Access ArgoCD

ArgoCD manages all the services in your cluster. Once Vault is configured, the Tailscale operator will automatically expose your services if configured.

### Local Access (Verification)

To check the sync status of your applications:

| Action | Command |
| :--- | :--- |
| **Get Password** | `just argocd-password` |
| **Port Forward** | `just pf-argocd` |

Access the UI at [localhost:8080](http://localhost:8080) with user `admin`.

## 4. Connectivity via Tailscale

If you have the Tailscale operator configured, your services will be reachable through your Tailnet.

- Verify Tailscale nodes are created in your admin console.
- Access services using their domain names (e.g., `vault.your-tailnet.ts.net`).

---
**Next Step:** Learn about [Sync Waves](sync-waves.md) to understand how the infrastructure components are ordered during deployment.

