# Changelog

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

### Planned (Roadmap)

- **Renovate bot** — automated dependency updates (Phase 2)
- **Velero** — cluster backups to SeaweedFS S3 (Phase 3)
- **CI/CD pipeline** — GitHub Actions for lint, test, preview (Phase 4)
- **Real application deployment** — Immich or similar (Phase 4)
- **Phase 5 — Python automation & image security**: ops CLI (Typer), infrastructure tests (pytest/testinfra), Prometheus exporter, maintenance automation, Trivy image scanning

## [1.0.0] - Unreleased

> First version — never been published nor run on a live cluster; tag and GitHub Release pending.

### Added

- **Vault HA** — 3-node Raft storage with TLS, auto-unseal CronJob, Kubernetes auth, and NetworkPolicies (injector/server egress, vault-to-vault)
- **External Secrets Operator** — per-service ClusterSecretStores with sync-wave ordered configuration
- **cert-manager** — automated TLS certificates for Vault and cluster services
- **Tailscale operator** — secure `.tailnet` ingress for platform services (ArgoCD, Vault, Grafana, Prometheus)
- **Monitoring stack** — kube-prometheus-stack (Prometheus + Grafana) and Loki, with Vault-injected credentials
- **SeaweedFS** — S3-compatible object storage with Vault-managed credentials; Loki backed by SeaweedFS S3
- **Longhorn support** — storage option for the cluster (plus local-path for dev environments)
- **App-of-Apps** — ApplicationSets driven by Helm values, platform local/helm split, per-environment values (`values.yaml` / `values-dev.yaml`)
- **GitOps-only architecture** — ArgoCD and Longhorn installation moved out to the companion infra repo (`infra-talos-homelab`, `platform/` Terraform root); this repo is now a pure App-of-Apps layer consuming cluster prerequisites
- **Justfile** — task automation: `init-prod`/`init-dev`, `vault-init`, port-forwards, status, checks, helm helpers
- **Docs** — getting-started, customization-guide, secrets-structure, ADRs

### Changed

- Vault migrated from standalone/file storage to HA Raft with multi-replica unsealing
- Grafana and Prometheus ingresses centralized in the Tailscale chart
- KubeVault dependency replaced by a manual Vault bootstrap script with idempotent secret management helpers
- ESO installed via direct Helm deployment instead of a bundled chart
- Bootstrap (`01-init-gitops.sh`) simplified — no longer installs ArgoCD or storage components; expects Longhorn + ArgoCD pre-installed (via `just tf-platform-apply` in the infra repo)

### Fixed

- ArgoCD ingress port/HTTP routing
- Vault raft `retry_join` using fully qualified service DNS names
- Auto-unseal retry logic and pod readiness checks