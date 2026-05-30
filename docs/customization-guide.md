# Customization & Fork Guide

This guide will walk you through the steps required to personalize this homelab after forking the repository. Since GitOps relies on declarative state, you need to update several references to point to your own infrastructure and repository.

## 1. Update Repository References

ArgoCD needs to know where its source of truth is. This project uses an **App-of-Apps** pattern driven by Helm values.

### Update repoURL

The main entry point is `gitops/templates/root-prod-app.yaml`, which uses the `repoURL` defined in the values files. You **must** update this to point to your fork.

1.  **Production**: Update `repoURL` in `gitops/values.yaml`.
2.  **Development**: Update `repoURL` in `gitops/values-dev.yaml`.

By default, the `prod` environment targets the `main` branch, while the `dev` environment targets the `dev` branch. You can change this behavior in `gitops/templates/root-prod-app.yaml` and `gitops/templates/platform-local-appset.yaml`.

## 2. Tailscale Configuration

This homelab integrates with Tailscale for secure networking. The bootstrap script simplifies the setup:

1.  **Auth Credentials**: When running `just init-prod` (or `just init-dev`), it will prompt for a **Tailscale Client ID** and **Secret**. These are used to provision the Tailscale Operator.
2.  **K3s Config**: If you are using K3s, follow the [K3s Install Guide](k3s-install.md) to ensure nodes are correctly identified in your Tailnet.
3.  **Operator**: The Tailscale Operator is managed as a platform app. You can find its configuration in `platform/tailscale/`.


## 3. Vault & Secrets Management

This lab relies heavily on HashiCorp Vault. The setup is mostly automated:

1.  **Initialization**: Follow the [Getting Started](../doc/getting-started.md) guide. The bootstrap script handles initialization, unsealing, and basic configuration (KV engine and Kubernetes auth).
2.  **Secrets Structure**: It is **crucial** to follow the [Secrets Structure guide](secrets-structure.md) to understand how to seed your own credentials (Tailscale, Cloudflare, etc.) into Vault.
3.  **External Secrets Operator (ESO)**: The `ClusterSecretStore` is pre-configured to connect to Vault using the internal Kubernetes service name. No manual updates are required unless you change the Vault deployment namespace or service names.


## 4. Personal Branding

Feel free to update the `README.md` footer and any other metadata to reflect your own journey!

---
*Good luck with your DevSecOps journey! If you find this useful, consider giving the original repo a star.*
