# ADR-005: Move Longhorn back to the GitOps repo (drop ArgoCD redis-ha)

**Status:** Accepted · **Date:** 2026-08-19

## Context

[ADR-003](003-argocd-longhorn-to-infra.md) moved Longhorn and ArgoCD to the companion infra repo's `platform/` Terraform root. One of the drivers was a hard ordering requirement: the ArgoCD chart with `redis-ha` enabled needs PersistentVolumeClaims for its Redis queue, and a bare Talos cluster ships no PVC provisioner — so storage had to exist **before** ArgoCD.

New evaluation: `redis-ha` adds no value in this homelab. Redis in ArgoCD is an ephemeral cache — ArgoCD reconstructs its state from Kubernetes (CRDs, Secrets, config maps), so losing the Redis PVC cache is a non-event. With `redis-ha` removed, ArgoCD needs no storage at all, and the forced storage → ArgoCD ordering disappears.

That unblocks a partial reversal: Longhorn can come back to this GitOps repo as a declarative platform app, ordered by sync waves and a real CSI readiness health gate — which is exactly how GitOps should express dependencies — instead of being a Terraform imperative step in another repo.

## Options Considered

### Option A — Keep Longhorn in the infra repo, just drop `redis-ha`

Remove `redis-ha` from the infra ArgoCD values but leave Longhorn installed by Terraform.

**Pros:** Minimal diff; the storage ordering already works via Terraform dependencies.

**Cons:** A cluster feature (Longhorn version, StorageClass, settings) is versioned outside Git + ArgoCD, so no self-heal and no declarative history; this repo stays non-distro-agnostic about storage; the ordering stays an imperative Terraform step instead of sync-waves.

### Option B — Move Longhorn back to this repo as a wave-0 app (SELECTED)

Longhorn becomes a local chart (`platform/longhorn/`) managed by the App-of-Apps, applied at wave 0 with a CSI readiness Job gating later waves.

**Pros:** Longhorn is versioned in Git, self-healed by ArgoCD, and ordered by declarative sync waves; storage becomes as declarative as every other app; infra `platform/` shrinks to ArgoCD only.

**Cons:** Cross-repo migration needed (terraform `state rm` before the reduced apply, with a documented runbook); the Longhorn chart does not template the `longhorn-csi-plugin` DaemonSet (the driver-deployer creates it dynamically), so a naive ArgoCD health check would report Healthy before CSI exists — a custom readiness gate Job is required.

### Option C — Keep `redis-ha`, move only Longhorn

**Pros:** ArgoCD keeps HA Redis.

**Cons:** `redis-ha` still forces storage before ArgoCD, keeping the ordering problem alive; it adds PVCs, a Redis cluster, and operational complexity for zero benefit in a single-operator homelab.

## Decision

1. Remove `redis-ha` from the ArgoCD values in the infra repo (`platform/values/argocd/values.yaml`). ArgoCD's ephemeral single Redis needs no PVCs.
2. Move Longhorn back to this repo as a local chart `platform/longhorn/`, deployed as wave 0 by the App-of-Apps, with a CSI readiness gate: the `longhorn-csi-wait` Job (wave 1 within the app) polls the `longhorn-csi-plugin` DaemonSet until ready. This is required because the upstream chart does not template that DaemonSet — the longhorn-driver-deployer creates it dynamically after the chart is applied.
3. The infra repo `platform/` Terraform root becomes ArgoCD-only (wait nodes Ready → install ArgoCD, no storage prerequisite).
4. Longhorn node prerequisites stay in the infra repo by nature: `iscsi-tools` / `util-linux-tools` system extensions and kubelet extraMounts for `/var/lib/longhorn` are cluster-machine concerns, not app concerns.

## Consequences

- The storage → apps ordering becomes declarative: sync waves (Longhorn at wave 0, later apps at waves 1+) plus the `longhorn-csi-wait` health gate. ArgoCD marks the longhorn app Healthy only once the Job completes (`kubectl rollout status` of `longhorn-driver-deployer` and `longhorn-csi-plugin`), so downstream waves stay blocked until CSI is genuinely ready.
- Longhorn versioning = Git + ArgoCD sync with self-heal; version bumps are PRs, not Terraform variable edits.
- Migration requires `terraform state rm` in infra *before* applying the reduced platform layer — see the runbook in the infra repo's README. `terraform destroy` on the old Longhorn resources (or deleting the ArgoCD app/namespace) would delete volumes; this risk is documented.
- Infra `platform/` loses the `kubernetes` provider, `longhorn_version` variable, and the storage values directory.
- Post-migration, Longhorn is managed by ArgoCD's prune/self-heal like every other platform app.