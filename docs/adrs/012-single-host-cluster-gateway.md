# ADR-012: Single-Host Cluster Gateway via Path-Based Ingress

**Status:** Accepted · **Date:** 2026-09-02 · **Deciders:** Seom88 · **Supersedes:** part of [ADR-001](001-tailscale-ingress-placement.md) · **Related:** [ADR-010](010-tailscale-oauth-ci-generated.md), [ADR-011](011-tailscale-dns-np.md)

## Context

The cluster historically exposed platform services via 7 separate Tailscale `Ingress` resources (`platform/tailscale/templates/platform/*ingress.yaml`), each with `ingressClassName: tailscale` and `tls.hosts: [service]`. Each `Ingress` creates a distinct Tailscale device, MagicDNS name (`grafana.lonk-mirfak.ts.net`, `argocd...`, etc) and Let's Encrypt certificate. At homelab scale this wastes tailnet devices (one per platform service) and burns weekly cert quota (50 unique / 5 duplicate).

Requirement: expose the entire platform through **one** tailnet device/hostname `my-cluster.lonk-mirfak.ts.net` with path routing (`/argocd`, `/grafana`, `/prometheus`, `/vault`, `/longhorn`, `/seaweedfs-s3`, `/seaweedfs-admin`) to avoid adding devices per service. The cluster currently uses Flannel CNI (no `NetworkPolicy` enforcement, but manifests remain Cilium-compatible); `coredns-patch` and `velero` Tailscale scoping stays unchanged.

Kubernetes constraint: an `Ingress` backend `Service` must be in the same namespace as the `Ingress`. A single cross-namespace `Ingress` fanning out to `argocd/argocd-server`, `monitoring/monitoring-grafana`, `longhorn-system/longhorn-frontend`, etc. is not valid. The Tailscale operator also rejects duplicate `spec.tls.hosts` across `Ingress`es in one cluster (`validateIngress: duplicate hostname`).

## Decision

**Single Tailscale Ingress + in-namespace NGINX gateway. Path-based, one device.**

- Keep Tailscale operator at wave `-1` `healthy` (no change).
- Replace 7 platform `Ingress`es with a **single** `Ingress` `my-cluster` in namespace `tailscale` (`ingressClassName: tailscale`, `tls.hosts: [my-cluster]`, `rules.http.paths: [{path:/ -> cluster-gateway:80}]`). This yields one device `my-cluster.lonk-mirfak.ts.net` and one cert.
- Deploy a lightweight NGINX `Deployment` + `Service` `cluster-gateway` in namespace `tailscale` (wave `4`, same chart) that reverse-proxies `/argocd`, `/grafana`, `/prometheus`, `/vault`, `/longhorn`, `/seaweedfs-s3`, `/seaweedfs-admin` to their respective cluster-internal `Service` DNS names (`argocd-server.argocd.svc.cluster.local:443`, `monitoring-grafana.monitoring.svc...`, etc). Routing table lives in a `ConfigMap` `cluster-gateway-nginx` mounted as `nginx.conf`.
- Gate per-service locations in `ConfigMap` with existing `.Values.{argocd,vault,grafana,prometheus,longhorn,seaweedfs.*}.enabled` toggles (same as before; now controls `location` blocks instead of separate `Ingress` files).
- Introduce `hostname` value (`my-cluster` / `dev-my-cluster` via `values-dev.yaml`) — hostnames differ per env, Service names do not.
- Simplify Service names: unify `gitops/templates/apps/*.yaml` `metadata.name` (remove `{{- if .Values.developmentApp.enabled }}-dev{{- end }}` except `root-prod-app.yaml` which keeps `gitops-dev`), and gateway upstreams now use unified DNS (`monitoring-grafana`, `vault`, `seaweedfs-s3`, `monitoring-kube-prometheus-prometheus`, `monitoring-loki-gateway`). `developmentApp.enabled` still selects `targetRevision: dev/main` and `values-dev.yaml` overlay, but no longer creates `-dev` service suffixes (ADR-012 follow-up 2026-09-02).
- Leave `coredns-patch` (wave `0`), `velero` (`Service/rustfs-egress` + `NetworkPolicy`), and all `NetworkPolicy` manifests unchanged — Flannel ignores them, Cilium will enforce later.
- Configure subpath-aware apps via their own charts (not via Ingress rewrite; Tailscale Ingress has no `rewrite-target`):
  - Grafana: `server.root_url = https://my-cluster.lonk-mirfak.ts.net/grafana/` + `serve_from_sub_path = true`
  - Prometheus: `--web.external-url=https://my-cluster.../prometheus` + `--web.route-prefix=/prometheus`
  - ArgoCD: `server.baseHRef: /argocd` (or `argocd-cmd-params: --basehref /argocd`)
  - Vault/Longhorn/SeaweedFS: served via `proxy_pass` with trailing-slash rewrite; verified functional behind prefix without app config (Longhorn requires `location /longhorn/ { proxy_pass http://.../; }` plus redirect for `/longhorn`).

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| 7 Ingress + `ProxyGroup type: ingress` shared StatefulSet | Consolidates proxy **pods**, not hostnames/devices — still 7 MagicDNS + 7 certs | Rejected — doesn't solve device sprawl |
| 7 Ingress with `tailscale.com/hostname: my-cluster` same host | Operator rejects duplicate hostname across Ingresses per cluster (`validateIngress` duplicate check) | Invalid |
| One Ingress with cross-namespace backends | Kubernetes API forbids `Service` in different namespace than `Ingress` | Invalid |
| Expose `ingress-nginx` via single Tailscale Ingress (B) | Same effect as chosen but adds external `ingress-nginx` chart; heavier than embedded NGINX gateway | Deferred — embedded gateway is lighter for homelab; can migrate to `ingress-nginx` later without changing tailnet hostname |
| L3 `Service loadBalancerClass: tailscale` | Loses L7 TLS automation (Let's Encrypt via `tailscale serve`), no path routing | Rejected |

## Consequences

### Positive
- 1 tailnet device + 1 cert instead of 7. `tailscale admin` stays clean; cert quota no longer multiplied.
- Single source of truth for platform exposure stays in `platform/tailscale` (same boundary as ADR-001), now as gateway `ConfigMap`.
- Flannel-compatible; no `NetworkPolicy` or CNI change required.
- Rollback is `git revert` to 7 Ingresses (no operator or DNS change).
- `platform/tailscale` remains ingress-only + gateway; operator concerns stay in `platform/tailscale-operator`.

### Negative
- Apps that don't natively support subpath require NGINX `sub_filter`/`rewrite` trickery (Longhorn, SeaweedFS admin). Tested via gateway rewrite rules.
- Additional hop (`tailscale proxy -> gateway -> Service`). Negligible latency homelab-local.
- Gateway is a single point of failure within the `tailscale` namespace (mitigated by `replicas: 1` homelab, can scale to 2).

## Wave Ordering After Change

| Wave | Apps | Policy |
|---|---|---|
| `-1` | `tailscale-operator` (`platform/tailscale-operator`) | `healthy` |
| `0` | `coredns-patch`, `longhorn`, `velero` (+ bucket-init hook) | `healthy` |
| `1` | `vault` | `healthy` |
| `2` | `seaweedfs` | `healthy` |
| `3` | `monitoring` | `sync-only` |
| `4` | `tailscale` (gateway `Deployment/Service/ConfigMap` + single `Ingress my-cluster`) | `sync-only` |

## Verification

- `helm template platform/tailscale | grep -c "kind: Ingress"` → `1` (was `7`)
- `helm template platform/tailscale | grep "my-cluster"` → present; no `argocd.lonk-mirfak`, `grafana.lonk-mirfak` hosts
- `helm template platform/tailscale | grep "cluster-gateway"` → `Deployment/Service/ConfigMap`
- `helm lint platform/tailscale` + `just validate` pass
- `kubectl get ingress -n tailscale my-cluster -o jsonpath='{.status.loadBalancer.ingress}'` → `my-cluster.lonk-mirfak.ts.net`
- From tailnet: `curl -k https://my-cluster.lonk-mirfak.ts.net/grafana/login` 200, `/argocd` 307, `/prometheus` 302, `/vault/ui` 200, `/longhorn` 200

## References

- ADR-001: `001-tailscale-ingress-placement.md` — original centralized placement (superseded in part)
- ADR-010: `010-tailscale-oauth-ci-generated.md` — wave topology and CI secret flow
- ADR-011: `011-tailscale-dns-np.md` — CoreDNS stub + NetworkPolicy scoping (unchanged)
- Tailscale KB 1236: https://tailscale.com/kb/1236/kubernetes-operator — `ingressClassName: tailscale`, `tailscale serve`, `TLS hosts` single label
- Tailscale operator `ingress-for-pg.go:validateIngress()` — duplicate hostname + `ValidLabel` checks
- Tailscale issue #10330, #20604 — single-host funnel workaround and shared-identity FR
