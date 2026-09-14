# Roadmap

**Status:** v1.0-beta · Cilium 1.20.1 (ADR-014) · Last updated: 14 Sep 2026

This document tracks what is currently deployed in the cluster, what is required to complete the **v1.0.0** release, and what is planned for **v2.0**. The cluster uses Cilium 1.20.1 + Gateway API 1.2.3 + CiliumNetworkPolicy (ADR-014); subsequent releases are expected to be additive. The [README](./README.md) contains a short summary and links here.

---

## Where the project stands today

The cluster runs on end-to-end GitOps: ArgoCD as the App-of-Apps, Vault HA for secrets, Tailscale as the single ingress point, and distributed storage via Longhorn + SeaweedFS. On top of that there's a CI layer that validates every push (`validate.yaml`), scans images and misconfigs weekly (`security.yaml`), and a controlled workflow for deploys (`deploy.yaml`).

**What's already running in CI/CD**, verified directly against `.github/workflows/`:
- `validate.yaml`: Helm dependency builds, `helm lint` and `helm template` (both prod and dev values), secret scan (`detect-secrets` baseline-gated), ShellCheck on the bootstrap scripts, YAML/JSON sanity checks, and `yamllint` as a non-blocking extra check.
- `security.yaml`: Trivy image scans over the dynamically discovered chart images (matrix from rendered manifests) + repo misconfig scan, SARIF upload to code scanning, weekly cron — non-blocking until images are pinned to digests.
- `deploy.yaml`: auto-deploy on `Validate` success (main) plus manual `workflow_dispatch` with environment selection (prod/dev), a Tailscale connection step, kubeconfig retrieval from Terraform state, and a `force_reapply` flag for safe retries.
- Pre-commit (local mirror of the fast gates): `detect-secrets`, `check-yaml`/`check-json`, `yamllint`, `shellcheck`; `just validate` + `just scan` as local mirrors.
- `renovate.json`: weekly updates (Mondays before 5am), with differentiated rules — critical cluster components (Vault, Longhorn, cert-manager) require explicit manual review via labels, while non-critical charts and GitHub Actions are grouped and auto-merged; regex managers also cover hardcoded images and `HELM_VERSION`.

That's already a real, guided CI/CD foundation with image scanning and secrets detection live (both non-blocking) — not a full DevSecOps pipeline yet (still missing fail-closed gates, completed network policies, audit logging, etc.), but not "nothing" either.

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
- [x] CI pipeline — `validate.yaml` (lint, render, secret scan, ShellCheck, sanity checks) + `security.yaml` (Trivy images + misconfig, SARIF, weekly cron, non-blocking) + `deploy.yaml` (auto on Validate success + guided manual deploy)
- [x] Renovate — weekly updates with mandatory manual review for critical components (Vault, Longhorn, cert-manager) and grouped automerge for the rest

### Phase 3 — Storage & Scale ✅ Complete

- [x] Longhorn — distributed block storage
- [x] SeaweedFS — S3-compatible object storage
- [x] Loki → SeaweedFS integration for centralized logging (SingleBinary + gateway, buckets `loki-chunks`/`loki-ruler`)
- [x] Velero — automated backup/restore (Wave 0, RustFS S3 `velero-homelab` at `https://rustfs.lonk-mirfak.ts.net`, schedules `daily-full` (02:00, all namespaces, 30d TTL) + `vault-hourly` (hourly, vault only, 7d TTL); chart `12.1.0` / app `1.18.1`) — deployed

### Phase 4 — Hardening & Developer Experience (in progress, v1.0)

Remaining scope for v1.0.0. The Cilium CNI (breaking change at the infrastructure layer) is already deployed.

**CNI (v1.0.0):**
- [x] Cilium CNI (eBPF, Gateway API, CiliumNetworkPolicy) — Cilium 1.20.1 + Gateway API 1.2.3 (ADR-014) — NetworkPolicy enforcement, Hubble observability, eBPF kubeProxyReplacement

**Security hardening (requires Cilium, planned for v1.0.0):**
- [ ] Container image vulnerability scanning (Trivy) integrated into CI — non-blocking `Security` workflow live; fail-closed after digest pinning
- [x] Git secrets detection (`detect-secrets`) — pre-commit hook + `.secrets.baseline` (audited) + CI step, fails on new secrets

**Developer experience (v1.0):**
- [x] Bootstrap guard with `--force` flag for safe reapply
- [x] Status verifier (rerun bootstrap to check cluster health)
- [x] `just validate` + `just scan` as local mirrors of CI validation (incl. Trivy summary table)
- [x] Pre-commit fast gates (secrets, yaml/json, yamllint, shellcheck)
- [x] Real application example deployed (Homepage v2.3.0 pinned via `.Values.image`, wave 3 `apps/homepage`)

---

## v2.0 — Enterprise automation (beyond v1.0)

Items planned after v1.0.0. Expected to be additive; no CNI or storage re-architecture is planned.

### Decoupling & vendor-agnostic ingress (Gateway API BYOD)

Reduce Tailscale as a single point of trust and cut tailnet sprawl while keeping the current MagicDNS workflow intact. App routing moves to standard Kubernetes Gateway API (`GatewayClass` / `Gateway` / `HTTPRoute`) so swapping the underlying mesh (Tailscale → Netbird or other) later requires no app changes.

**Device inventory — 4 → 3 (vault device eliminated):**

| Tailnet device | Purpose | Today (v1 — 4 devices) | After BYOD (v2 — 3 devices) |
|---|---|---|---|
| `k8s-nameserver` | `DNSConfig` device for MagicDNS `ts.net` → CoreDNS sibling `ts.net:53` (`platform/coredns-patch`, ADR-011) | ✅ present | ✅ stays |
| `rustfs-egress` | `ExternalName` `rustfs.lonk-mirfak.ts.net` for Velero/S3 via Tailscale | ✅ present | ✅ stays (future optional: consolidate via `TCPRoute`; out of scope for v2) |
| `my-cluster` | Single `Ingress` + NGINX gateway (`platform/ts-ingress`) for `argocd`/`grafana`/`prometheus`/`longhorn`/`seaweedfs` (ADR-012) | ✅ present | 🔀 replaced — merged into `gateway-envoy` |
| `vault-my-cluster` | Dedicated `Ingress` for Vault — Amendment 2026-09-02 (Vault UI has no subpath support, `hashicorp/vault#9221`) | ✅ present | ❌ eliminated — becomes second listener/hostname on `gateway-envoy` |
| `gateway-envoy` | Envoy Gateway `LoadBalancer` with `loadBalancerClass: tailscale` (BYOD) | — | ✅ **single device** serving both `my-cluster.lonk-mirfak.ts.net` + `vault-my-cluster.lonk-mirfak.ts.net` |

> Operator itself is control-plane only and not counted. `k8s-nameserver` + `rustfs-egress` are unchanged in v2.

**BYOD architecture (brief):**

- Envoy Gateway chart provides `GatewayClass: tailscale` and a `LoadBalancer` (`loadBalancerClass: tailscale`) — single Tailscale device `gateway-envoy` replaces the two L7 devices above. See [Tailscale BYOD Gateway API](https://tailscale.com/docs/solutions/kubernetes-operator-byod-gateway-api).
- One `Gateway` with multiple `listeners` / `hostnames` (`my-cluster.lonk-mirfak.ts.net`, `vault-my-cluster.lonk-mirfak.ts.net`), each terminating its own TLS cert. One `HTTPRoute` per service (replaces NGINX `ConfigMap` path-proxy).
- Removes `platform/ts-ingress` NGINX gateway (`Deployment`/`Service`/`ConfigMap`) and `sub_filter`/`rewrite` hacks for `/longhorn`, `/seaweedfs-*`, etc. Vault no longer needs a separate device — it is a standard hostname-routed `HTTPRoute`.
- Substrate ready: Cilium Gateway API CRDs `v1.2.3` are already installed via `infra-talos-homelab` (ADR-014); no CNI/storage change needed.

**Scope:**

| | In scope for v2 (immediate) | Future / optional (not v2) |
|---|---|---|
| Ingress | Consolidate `my-cluster` + `vault-my-cluster` onto one `gateway-envoy` device; keep MagicDNS (`*.lonk-mirfak.ts.net`) | Own domain via Pi-hole/CoreDNS authoritative + `ExternalDNS` + `cert-manager` + Tailscale split DNS (BYOD guide Steps 1–6); reduces MagicDNS dependency but not required for vendor-agnostic routing |
| Mesh | App `HTTPRoutes` stay vendor-agnostic; swapping `GatewayClass` from `tailscale` to `netbird`/other requires no app changes | Evaluation of alternative meshes (e.g. Netbird) as drop-in `GatewayClass` replacement |
| DNS / S3 | `k8s-nameserver` and `rustfs-egress` untouched | Own DNS/domain, `TCPRoute` for RustFS |

**Checklist — v2:**

- [ ] Install Envoy Gateway chart (Gateway API provider) and define `GatewayClass: tailscale`
- [ ] Define single `Gateway: gateway-envoy` (`LoadBalancer`, `loadBalancerClass: tailscale`) with two TLS listeners/hostnames and per-service `HTTPRoute`s (argocd, grafana, prometheus, longhorn, seaweedfs, vault)
- [ ] Migrate Vault route from dedicated `Ingress` (`vault-my-cluster`) to `HTTPRoute` on `gateway-envoy`; verify Vault UI/API at root without subpath hacks
- [ ] Deprecate and remove `platform/ts-ingress` NGINX gateway (`Deployment`/`Service`/`ConfigMap` + Cilium policies for `cluster-gateway`); update `CiliumNetworkPolicies` for `gateway-envoy`
- [ ] Update docs/runbooks (URLs, `helm template` verification, `kubectl get gateway/httproute` checks, rollback to dual-Ingress)

**Non-goals for v2:**

- Not removing Tailscale entirely — `k8s-nameserver`, `rustfs-egress`, and tailnet ACLs remain.
- Not touching `k8s-nameserver` or `rustfs-egress` devices.
- No change to storage (Longhorn/SeaweedFS), Vault HA, or ArgoCD waves beyond ingress.

### Compliance & policy

- Pod Security Admission `restricted` rollout — Talos enforces `baseline` by default; 6 infra namespaces stay `privileged` by exception (Longhorn, monitoring, etc.); homepage is restricted-ready pilot — moved from v1, requires full project to validate
- NetworkPolicy gap-closing & hardening — per-namespace allows exist (10 charts); missing policies for external-secrets/argocd, Vault Raft 8201 audit, tighten broad allows — moved from v1, must re-validate with every new app
- Security architecture documentation (minimal threat model, attack surface, incident response) — moved from v1
- Kyverno — admission-time policy enforcement (policy-as-code)
- CIS Benchmark — automated Kubernetes security validation
- RBAC audit — access pattern reports
- Compliance dashboard (SOC 2 / PCI-DSS) in Grafana

### Observability & audit

- Centralized audit logging (Kubernetes API + Vault → Loki) — moved from v1, requires infra-talos-homelab changes + control-plane restart

### Supply chain & image security

- Supply chain hardening — chart signing, SBOM, dependency scanning
- Trivy Operator via ArgoCD (`trivy-system`, automated sync, `ignoreUnfixed: true`) — ✅ chart + Application added (`platform/trivy-operator`, wave 3); continuous in-cluster scanning every 6h, results as CRDs integrated with Prometheus; complements CI-time `Security` workflow

### Backup & recovery

- Velero restore drills (RTO/RPO validation)

### Automation

- Automated secrets rotation (Tailscale, S3, API keys) via CronJob

### Python automation & image security

- Ops CLI (`gitops-ops`) built with Typer + a Kubernetes client + HVAC, for bootstrap, health checks, image scanning, secrets rotation, and cluster diagnostics
- Infrastructure tests with pytest + testinfra (Vault unsealed, ArgoCD healthy, secrets synced, no root pods)
- Observability exporter with custom Prometheus metrics (Vault seal state, ArgoCD drift, Longhorn rebuilds)
- Automated compliance scanning (CIS, PCI-DSS checklist, policy violation alerts)

### Documentation & onboarding

- Customization guide refreshed (current `platform/*.yaml` layout + real wave table) and tested end-to-end — moved from v1, waits until the app set stabilizes (v2 changes ingress)

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
- [x] Git secrets gate (pre-commit + baseline + CI step)
- [x] Trivy `Security` workflow (non-blocking image + misconfig scans, SARIF)
- [x] Architecture Decision Records

**Still pending for v1.0:**
- [x] Cilium CNI (eBPF, Gateway API, CiliumNetworkPolicy) — Cilium 1.20.1 + Gateway API 1.2.3 (ADR-014) ✅ Complete
- [x] CiliumNetworkPolicy — 10 charts with allow-dns / allow-egress / allow-ingress (ADR-014) ✅ Complete
- [ ] Trivy in CI (non-blocking `Security` workflow live; fail-closed after digest pinning)
- [x] Git secrets detection (`detect-secrets` hook + baseline + CI step) ✅ Complete
- [x] Real application example (Homepage v2.3.0 pinned, wave 3 `apps/homepage`)

**Planned for v2.0:**
- [ ] Decoupling & vendor-agnostic ingress — Gateway API BYOD (Envoy Gateway, `GatewayClass: tailscale`; 4→3 devices — `vault-my-cluster` merged into `gateway-envoy`; MagicDNS kept, own-domain split DNS deferred)
- [ ] Compliance & policy (PSA restricted rollout, NetworkPolicy hardening, threat-model doc, Kyverno, CIS Benchmark, RBAC audit, compliance dashboard)
- [ ] Documentation & onboarding (customization guide refresh + e2e)
- [ ] Observability & audit (centralized audit logging)
- [ ] Supply chain & image security (supply chain hardening + Trivy Operator)
- [ ] Backup & recovery (Velero restore drills)
- [ ] Automation (secrets rotation via CronJob)
- [ ] Python automation & image security (Ops CLI, infrastructure tests, observability exporter, compliance scanning)

---

## Related documentation

- [Getting Started](./docs/getting-started.md)
- [Customization Guide](./docs/customization-guide.md)
- [Secrets Structure](./docs/secrets-structure.md)
- [Architecture Decision Records](./docs/adrs/)
