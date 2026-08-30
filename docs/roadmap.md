# Roadmap

**Status:** v0.9 (pre-release) · Actively developed · Last updated: 29 August 2026

This document tracks what's actually running in the cluster today, what's left to close out for the **v1.0** release, and what's planned as a later enterprise-automation phase (**v2.0**). It's the detailed, phase-by-phase view; the [README](./README.md) keeps only a short summary and a link here.

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

The real scope for v1.0 stops at Phase 4. Everything that used to be labeled "Phase 5" or "Phase 1.2" has been moved to the v2.0 section below.

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

- [x] Monitoring stack deployed (Prometheus + Grafana + Loki)
- [x] Dashboards reachable via Tailscale ingress
- [x] CI pipeline — `validate.yaml` (lint, render, ShellCheck, sanity checks) + `deploy.yaml` (guided, manual deploy)
- [x] Renovate — weekly updates with mandatory manual review for critical components (Vault, Longhorn, cert-manager) and grouped automerge for the rest

### Phase 3 — Storage & Scale ✅ Complete

- [x] Longhorn — distributed block storage
- [x] SeaweedFS — S3-compatible object storage
- [x] Loki → SeaweedFS integration for centralized logging
- [ ] Velero — automated backup/restore

### Phase 4 — Hardening & Developer Experience 🟡 In progress

This is the phase that's left to close out for v1.0. It folds in what used to be a separate "Phase 1.1 — Critical Security Gates":

**Security (release-blocking gates):**
- [ ] Container image vulnerability scanning (Trivy) integrated into CI
- [ ] Git secrets detection (`detect-secrets`) before every commit/push
- [ ] Complete NetworkPolicies (default deny-all + explicit allows)
- [ ] Pod Security Admission in `restricted` mode
- [ ] Centralized audit logging (Kubernetes API + Vault → Loki)
- [ ] Security architecture documentation (threat model, attack surface, incident response)

**Developer experience:**
- [x] Bootstrap guard with `--force` flag for safe reapply
- [x] Status verifier (rerun bootstrap to check cluster health)
- [x] `just validate` as a local mirror of CI validation
- [ ] Real application example deployed (Immich or similar)
- [ ] Customization guide tested end-to-end

---

## v2.0 — Enterprise automation (future vision)

Everything below is intentionally **beyond v1.0** — maturity improvements that don't block the first stable release, but show where the project is headed.

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
- [x] Prometheus + Grafana + Loki
- [x] Validation CI (GitHub Actions)
- [x] Architecture Decision Records

**Still pending for v1.0:**
- [ ] Trivy in CI
- [ ] Git secrets detection
- [ ] Complete NetworkPolicies
- [ ] Pod Security Admission
- [ ] Audit logging
- [ ] Security architecture documentation
- [ ] Real application example
- [ ] Velero (backup/restore)

---

## Related documentation

- [Getting Started](./docs/getting-started.md)
- [Customization Guide](./docs/customization-guide.md)
- [Secrets Structure](./docs/secrets-structure.md)
- [Architecture Decision Records](./docs/adrs/)