# Customization & Fork Guide

This guide will walk you through the steps required to personalize this homelab after forking the repository. Since GitOps relies on declarative state, you need to update several references to point to your own infrastructure and repository.

> **Two-repo setup:** This project is the GitOps layer. Cluster provisioning and **ArgoCD** (GitOps engine) live in a separate [infra repo](https://github.com/Seom88/infra-talos-homelab) (`platform/` layer, ArgoCD only). Longhorn is deployed by this repo as a wave-0 platform app with a CSI readiness gate. If you fork both, update the infra repo references too — including its platform Terraform configuration and Helm values.

## 1. Update Repository References

> **Prerequisites:** Before bootstrapping this repo, your cluster must provide **ArgoCD**. If you fork the infra repo, its `platform/` layer installs it (`just tf_env=<env> tf-platform-apply` from the infra repo); otherwise, provide it through your own provisioning. Longhorn is not a prerequisite: this repo deploys it as a wave-0 app. The GitOps bootstrap does not install ArgoCD.

ArgoCD needs to know where its source of truth is. This project uses an **App-of-Apps** pattern driven by Helm values.

### Update repoURL

The main entry point is `gitops/templates/root-prod-app.yaml`, which uses the `repoURL` defined in the values files. Platform apps are plain `Application` resources in `gitops/templates/apps/00-*.yaml` (not ApplicationSets), each with `argocd.argoproj.io/sync-wave` and `wave-policy`. You **must** update `repoURL` to point to your fork.

1.  **Production**: Update `repoURL` in `gitops/values.yaml`.
2.  **Development**: Update `repoURL` in `gitops/values-dev.yaml`.

By default, the `prod` environment targets the `main` branch, while the `dev` environment targets the `dev` branch. You can change this behavior in `gitops/templates/root-prod-app.yaml` and in each `gitops/templates/apps/00-*.yaml` (via `targetRevision`).

To add a new ordered app, create a new `gitops/templates/apps/0N-name.yaml` as a plain `Application` with the correct `argocd.argoproj.io/sync-wave` annotation and `wave-policy` label (`healthy` to block the next wave until `Synced + Healthy`, `sync-only` to require only `Synced`). Use the existing `00-*.yaml` → `04-*.yaml` files as templates: wave `-1` tailscale-operator → `0` cert-manager/external-secrets/longhorn/coredns-patch/velero → `1` vault → `2` seaweedfs → `3` monitoring (`sync-only`) → `4` tailscale single-host gateway (`my-cluster` Ingress + `cluster-gateway` Deployment/Service, `sync-only`, always last) — see ADRs 010/011/012.

## 2. Tailscale Configuration

This homelab integrates with Tailscale for secure networking:

1.  **Auth Credentials**: Tailscale credentials are seeded into Vault and consumed by the Tailscale Operator — see the [Secrets Structure guide](secrets-structure.md) for the expected secret layout. The bootstrap script does not prompt for them.
2.  **Operator**: The Tailscale Operator is managed as a platform app in `platform/tailscale-operator/` (wave `-1`). Platform exposure is a **single-host gateway** in `platform/tailscale/` (`hostname: my-cluster` → `my-cluster.lonk-mirfak.ts.net/{argocd,grafana,prometheus,vault,longhorn,seaweedfs-*}` via `cluster-gateway` NGINX) — see [ADR-012](adrs/012-single-host-cluster-gateway.md). No distro-specific setup is required here — any cluster with ArgoCD (installed by the infra platform layer) works; Longhorn is deployed by this repo as a wave-0 app. The cluster uses Cilium CNI (v1.20.1) with native `CiliumNetworkPolicy` enforcement across all platform namespaces (see [ADR-014](adrs/014-cilium-cni-and-identity-networkpolicies.md)).


## 3. Vault & Secrets Management

This lab relies heavily on HashiCorp Vault. The setup is mostly automated:

1.  **Initialization**: Follow the [Getting Started](getting-started.md) guide. The bootstrap script handles initialization, unsealing, and basic configuration (KV engine and Kubernetes auth).
2.  **Secrets Structure**: It is **crucial** to follow the [Secrets Structure guide](secrets-structure.md) to understand how to seed your own credentials (Tailscale, Cloudflare, etc.) into Vault.
3.  **External Secrets Operator (ESO)**: The `ClusterSecretStore` is pre-configured to connect to Vault using the internal Kubernetes service name. No manual updates are required unless you change the Vault deployment namespace or service names.


## 4. Personal Branding

Feel free to update the `README.md` footer and any other metadata to reflect your own journey!

---
*Good luck with your DevSecOps journey! If you find this useful, consider giving the original repo a star.*
