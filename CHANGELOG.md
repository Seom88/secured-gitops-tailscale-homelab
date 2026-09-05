# Changelog

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

### Planned (Roadmap)

- **Renovate bot** — automated dependency updates (Phase 2)
- **Velero** — cluster backups to SeaweedFS S3 (Phase 3)
- **CI/CD pipeline** — GitHub Actions for lint, test, preview (Phase 4)
- **Real application deployment** — Immich or similar (Phase 4)
- **Phase 5 — Python automation & image security**: ops CLI (Typer), infrastructure tests (pytest/testinfra), Prometheus exporter, maintenance automation, Trivy image scanning

## [Unreleased]

### Added

- **Cilium 1.20.1 eBPF CNI + Gateway API 1.2.3 + CiliumNetworkPolicy (9 charts, ADR-014) + Hubble observability** — Talos `cni: none` + `proxy.disabled`, DAG `gateway_api 1.2.3 → cilium 1.20.1 → wait_nodes → argocd` (KubePrism `localhost:7445`, `ipam: kubernetes`, `kubeProxyReplacement: strict`, `socketLB: hostNamespaceOnly`, `gatewayAPI.enabled`, `cgroup.hostRoot`). Per-namespace `CiliumNetworkPolicy` (gated by `ciliumNetworkPolicy.enabled=true`) with `allow-dns` (kube-dns 53 + `toFQDNs`/`rules.dns`), `allow-egress` (kube-apiserver 443/6443, hubble-relay 4244, intra-ns), `allow-ingress` (intra-ns, tailscale/cluster-gateway, host/remote-node/kube-apiserver probes). Fixed Flannel mismatches: vault same-ns ingress, Gateway post-DNAT ports 8080/3000/8081, storage intra-ns unrestricted (Longhorn 9500/8000/8500-8503, SeaweedFS 8333/9333), Hubble 4244/4245 whitelisted. See `docs/networking.md` and ADR-014.

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