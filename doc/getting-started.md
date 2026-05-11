# Getting Started

This guide provides the steps to initialize the Homelab GitOps environment, including the setup of HashiCorp Vault for secret management and ArgoCD for continuous delivery.


## Prerequisites

- A running Kubernetes cluster (see [k3s-install.md](k3s-install.md) for a reference setup).
- `kubectl` configured to point to your cluster.
- `helm` installed locally.
- `jq` installed locally.

## 1. Bootstrap the Environment

Run the initialization script to configure the foundation of your GitOps flow (Vault, External Secrets, and ArgoCD).

```bash
./bootstrap/01-init-gitops.sh
```

> [!IMPORTANT]
> This script initializes the Vault operator and sets up the root ArgoCD application. Wait for script to finish before proceeding.

## 2. Configure Vault

After initialization, you need to retrieve the root token to access the UI and set up your personal credentials.

### Access Vault UI

1. **Get the root token**:
   ```bash
   kubectl -n vault get secret vault-unseal-keys -o jsonpath="{.data.root-token}" | base64 -d && echo ""
   ```
2. **Start port-forwarding**:
   ```bash
   kubectl port-forward svc/vault-app -n vault 8200:8200
   ```
3. **Login**: Go to [localhost:8200](https://localhost:8200) and use the token from step 1.

> [!TIP]
> Once inside, follow the [Secret Structure guide](secrets-structure.md) to organize your secrets correctly.

## 3. Access ArgoCD

ArgoCD manages all the services in your cluster. Once Vault is configured, the Tailscale operator will automatically expose your services if configured.

### Local Access (Verification)

To check the sync status of your applications:

| Action | Command |
| :--- | :--- |
| **Get Password** | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d && echo ""` |
| **Port Forward** | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |

Access the UI at [localhost:8080](http://localhost:8080) with user `admin`.

## 4. Connectivity via Tailscale

If you have the Tailscale operator configured, your services will be reachable through your Tailnet.

- Verify Tailscale nodes are created in your admin console.
- Access services using their domain names (e.g., `vault.your-tailnet.ts.net`).

---
**Next Step:** Learn about [Sync Waves](sync-waves.md) to understand how the infrastructure components are ordered during deployment.

