# Roadmap

**Status:** v0.9 (pre-release) · v1.0.0 planned to include Cilium CNI migration (CNI replacement, breaking change); subsequent releases are expected to be additive · Last updated: 29 August 2026

This document tracks what is currently deployed in the cluster, what is required to complete the **v1.0.0** release, and what is planned for **v2.0**. v1.0.0 will include the Cilium CNI migration (CNI replacement, breaking change). Subsequent releases are expected to be additive. The [README](./README.md) contains a short summary and links here.

---

## Where the project stands today

The cluster runs on end-to-end GitOps: ArgoCD as the App-of-Apps, Vault HA for secrets, Tailscale as the single ingress point, and distributed storage via Longhorn + SeaweedFS. On top of that there's a CI layer that validates every push (`validate.yaml`) and a controlled, manual workflow for deploys (`deploy.yaml`).

**What's already running in CI/CD**, verified directly against `.github/workflows/`:
- `validate.yaml`: Helm dependency builds, `helm lint` and `helm template` (both prod and dev values), ShellCheck on the bootstrap scripts, YAML/JSON sanity checks, and `yamllint` as a non-blocking extra check.
- `deploy.yaml`: manual deploy via `workflow_dispatch` (not on every push), with environment selection (prod/dev), a Tailscale connection step, kubeconfig retrieval from Terraform state, and a `force_reapply` flag for safe retries.
- `renovate.json`: weekly updates (Mondays before 5am), with differentiated rules — critical cluster components (Vault, Longhorn, cert-manager) require explicit manual review via labels, while non-critical charts and GitHub Actions are grouped and auto-merged.

That's already a real, guided CI/CD foundation — not a full DevSecOps pipeline yet (still missing image scanning, git secrets detection, network policies, etc.), but not "nothing" either.

---

## Path to v1.0 — Phases 1 through 4

The scope for v1.0 is defined as Phases 1 through 4. Items previously labeled "Phase 5" or "Phase 1.2" are tracked under v2.0 below.

### Phase 1 — Foundation ✅ Complete

- [x] Bootstrap script: empty cluster → ArgoCD → Vault → apps
- [x] Vault HA (3-node Raft) with TLS + auto-unseal
- [x] External Secrets Operator with per-service ClusterSecretStores
- [x] cert-manager for automated TLS
- [x] Tailscale operator with secure ingress (no public ports)
- [x] ArgoCD with custom health checks
- [x] Longhorn as distributed storage (wave 0)
- [x] Prometheus + Grafana + Loki
- [x] SeaweedFS as S3-compatible storage
- [x] Architecture Decision Records (ADRs)

### Phase 2 — Automation & Observability ✅ Complete

- [x] Monitoring stack deployed (Prometheus + Grafana + Loki + Alloy — Alloy `chart 1.12.1` DaemonSet via `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` to Loki gateway; stateless, RBAC auto-created; replaces Promtail — deprecated)
- [x] Dashboards reachable via Tailscale ingress (Grafana at `/grafana`, Prometheus at `/prometheus`; Loki datasource with `X-Scope-OrgID: fake`, Explore + LogQL)
- [x] CI pipeline — `validate.yaml` (lint, render, ShellCheck, sanity checks) + `deploy.yaml` (guided, manual deploy)
- [x] Renovate — weekly updates with mandatory manual review for critical components (Vault, Longhorn, cert-manager) and grouped automerge for the rest

### Phase 3 — Storage & Scale ✅ Complete

- [x] Longhorn — distributed block storage
- [x] SeaweedFS — S3-compatible object storage
- [x] Loki → SeaweedFS integration for centralized logging (SingleBinary + gateway, buckets `loki-chunks`/`loki-ruler`)
- [x] Velero — automated backup/restore (Wave 0, RustFS S3 `velero-homelab` at `https://rustfs.lonk-mirfak.ts.net`, schedules `daily-full` (02:00, all namespaces, 30d TTL) + `vault-hourly` (hourly, vault only, 7d TTL); chart `12.1.0` / app `1.18.1`) — deployed

### Phase 4 — Hardening & Developer Experience (in progress, v1.0)

Remaining scope for v1.0.0. The Cilium CNI migration is a breaking change at the infrastructure layer.

**CNI migration (v1.0.0, breaking change):**
- [ ] Cilium CNI migration (Flannel -> Cilium; enables NetworkPolicy enforcement, Hubble observability, and WireGuard encryption) — planned for v1.0.0

**Security hardening (requires Cilium, planned for v1.0.0):**
- [ ] Complete NetworkPolicies (default deny-all + explicit allows) — requires Cilium
- [ ] Pod Security Admission in `restricted` mode
- [ ] Centralized audit logging (Kubernetes API + Vault → Loki)
- [ ] Container image vulnerability scanning (Trivy) integrated into CI
- [ ] Git secrets detection (`detect-secrets`) before every commit/push
- [ ] Security architecture documentation (minimal threat model, attack surface, incident response)

**Developer experience (v1.0):**
- [x] Bootstrap guard with `--force` flag for safe reapply
- [x] Status verifier (rerun bootstrap to check cluster health)
- [x] `just validate` as a local mirror of CI validation
- [ ] Real application example deployed (Homarr — lightweight dashboard as first real app)
- [ ] Customization guide tested end-to-end

---

## v2.0 — Enterprise automation (beyond v1.0)

Items planned after v1.0.0. Expected to be additive; no CNI or storage re-architecture is planned.

### Compliance & policy

- Kyverno — admission-time policy enforcement (policy-as-code)
- CIS Benchmark — automated Kubernetes security validation
- RBAC audit — access pattern reports
- Compliance dashboard (SOC 2 / PCI-DSS) in Grafana

### Operational excellence

- Automated secrets rotation (Tailscale, S3, API keys) via CronJob
- Supply chain hardening — chart signing, SBOM, dependency scanning
- Velero restore drills (RTO/RPO validation)

### Python automation & image security

- Ops CLI (`gitops-ops`) built with Typer + a Kubernetes client + HVAC, for bootstrap, health checks, image scanning, secrets rotation, and cluster diagnostics
- Infrastructure tests with pytest + testinfra (Vault unsealed, ArgoCD healthy, secrets synced, no root pods)
- Observability exporter with custom Prometheus metrics (Vault seal state, ArgoCD drift, Longhorn rebuilds)
- Automated compliance scanning (CIS, PCI-DSS checklist, policy violation alerts)

---

## v1.0 release checklist

**Already complete:**
- [x] Vault HA with auto-unseal
- [x] ArgoCD App-of-Apps
- [x] External Secrets Operator
- [x] Zero-trust ingress via Tailscale
- [x] Longhorn + SeaweedFS
- [x] Prometheus + Grafana + Loki + Alloy (DaemonSet log collector)
- [x] Velero — backup/restore (Wave 0, RustFS S3, chart `12.1.0`)
- [x] Validation CI (GitHub Actions)
- [x] Architecture Decision Records

**Still pending for v1.0:**
- [ ] Cilium CNI migration (Flannel -> Cilium; enables NetworkPolicy enforcement, Hubble, WireGuard encryption)
- [ ] Complete NetworkPolicies (requires Cilium)
- [ ] Pod Security Admission `restricted`
- [ ] Centralized audit logging (K8s API + Vault → Loki)
- [ ] Trivy in CI
- [ ] Git secrets detection (`detect-secrets`)
- [ ] Security architecture documentation (minimal threat model)
- [ ] Real application example (Homarr)
- [ ] Customization guide tested end-to-end

**Planned for v2.0:**
- [ ] Compliance & policy (Kyverno, CIS Benchmark, RBAC audit, compliance dashboard)
- [ ] Operational excellence (automated secrets rotation, supply chain hardening, Velero restore drills)
- [ ] Python automation & image security (Ops CLI, infrastructure tests, observability exporter, compliance scanning)

---

## Related documentation

- [Getting Started](./docs/getting-started.md)
- [Customization Guide](./docs/customization-guide.md)
- [Secrets Structure](./docs/secrets-structure.md)
- [Architecture Decision Records](./docs/adrs/)
