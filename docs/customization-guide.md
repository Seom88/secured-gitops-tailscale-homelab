# Customization & Fork Guide

This guide will walk you through the steps required to personalize this homelab after forking the repository. Since GitOps relies on declarative state, you need to update several references to point to your own infrastructure and repository.

> **Two-repo setup:** This project is the GitOps layer. Cluster provisioning and **ArgoCD** (GitOps engine) live in a separate [infra repo](https://github.com/Seom88/infra-talos-homelab) (`platform/` layer, ArgoCD only). Longhorn is deployed by this repo as a wave -1 platform app with a CSI readiness gate. If you fork both, update the infra repo references too — including its platform Terraform configuration and Helm values.

## 1. Update Repository References

> **Prerequisites:** Before bootstrapping this repo, your cluster must provide **ArgoCD**. If you fork the infra repo, its `platform/` layer installs it (`just tf_env=<env> tf-platform-apply` from the infra repo); otherwise, provide it through your own provisioning. Longhorn is not a prerequisite: this repo deploys it as a wave -1 app. The GitOps bootstrap does not install ArgoCD.

ArgoCD needs to know where its source of truth is. This project uses an **App-of-Apps** pattern driven by Helm values.

### Update repoURL

The main entry point is `gitops/templates/root-prod-app.yaml`, which uses the `repoURL` defined in the values files. Platform apps are plain `Application` resources in `gitops/templates/platform/` (and user apps in `gitops/templates/apps/`), each with `argocd.argoproj.io/sync-wave` and `wave-policy`. You **must** update `repoURL` to point to your fork.

1.  **Production**: Update `repoURL` in `gitops/values.yaml`.
2.  **Development**: Update `repoURL` in `gitops/values-dev.yaml`.

By default, the `prod` environment targets the `main` branch, while the `dev` environment targets the `dev` branch. You can change this behavior in `gitops/templates/root-prod-app.yaml` and in each `gitops/templates/platform/*.yaml` / `gitops/templates/apps/*.yaml` (via `targetRevision`).

To add a new ordered app, create a new `gitops/templates/platform/0N-name.yaml` (platform) or `gitops/templates/apps/0N-name.yaml` (user app) as a plain `Application` with the correct `argocd.argoproj.io/sync-wave` annotation and `wave-policy` label (`healthy` to block the next wave until `Synced + Healthy`, `sync-only` to require only `Synced`). Use the existing files as templates: wave `-1` ts-operator/cert-manager/longhorn → `0` external-secrets/coredns-patch/velero → `1` vault → `2` seaweedfs → `3` monitoring/trivy-operator/homepage → `4` cloudnative-pg → `5` immich — see ADRs 010/011/018. (No `ts-ingress` chart: each chart owns its Tailscale Ingress.)

## 2. Tailscale Configuration

This homelab integrates with Tailscale for secure networking:

1.  **Auth Credentials**: Tailscale credentials are seeded into Vault and consumed by the Tailscale Operator — see the [Secrets Structure guide](secrets-structure.md) for the expected secret layout. The bootstrap script does not prompt for them.
2.  **Operator**: The Tailscale Operator is managed as a platform app in `platform/ts-operator/` (wave `-1`). Platform exposure is **one Ingress per app, owned by each chart** via `tailscaleIngress` values (each app its own MagicDNS device on `*.lonk-mirfak.ts.net`, served at `/` root) — see [ADR-018](adrs/018-per-app-tailscale-ingress.md). To expose a new UI, add a `tailscale-ingress.yaml` in the owning chart following the existing pattern (or `platform/ts-operator/templates/infra/` if the app lives in the infra repo). No distro-specific setup is required here — any cluster with ArgoCD (installed by the infra platform layer) works; Longhorn is deployed by this repo as a wave -1 app. Requires Cilium 1.20.1 (eBPF, kubeProxyReplacement strict). Policies are gated by `ciliumNetworkPolicy.enabled=true`; set to `false` for non-Cilium clusters where policies are not enforced.


## 3. Secrets Management (SOPS default, Vault paused)

> Vault is paused, not deleted ([ADR-017](adrs/017-vault-paused-sops-default.md)). New secrets ship with **SOPS + age** — see the [SOPS guide](sops.md). The Vault notes below apply only if you re-enable the Vault path.

This lab relies heavily on HashiCorp Vault. The setup is mostly automated:

1.  **Initialization**: Follow the [Getting Started](getting-started.md) guide. The bootstrap script handles initialization, unsealing, and basic configuration (KV engine and Kubernetes auth).
2.  **Secrets Structure**: It is **crucial** to follow the [Secrets Structure guide](secrets-structure.md) to understand how to seed your own credentials (Tailscale, Cloudflare, etc.) into Vault.
3.  **External Secrets Operator (ESO)**: The `ClusterSecretStore` is pre-configured to connect to Vault using the internal Kubernetes service name. No manual updates are required unless you change the Vault deployment namespace or service names.


## 4. Personal Branding

Feel free to update the `README.md` footer and any other metadata to reflect your own journey!

---
*Good luck with your DevSecOps journey! If you find this useful, consider giving the original repo a star.*
