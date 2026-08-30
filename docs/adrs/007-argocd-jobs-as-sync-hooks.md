# ADR-007: ArgoCD Jobs as Sync Hooks

**Status:** Accepted · **Date:** 2026-08-30

## Context

One-shot configuration Jobs (`vault-config-tailscale`, `vault-config-monitoring`, `longhorn-csi-wait`) were managed as regular ArgoCD-tracked resources with `argocd.argoproj.io/sync-wave: "1"` and `argocd.argoproj.io/sync-options: Replace=true`.

They failed deterministically on every re-sync after initial creation:

```
Job.batch "vault-config-tailscale" is invalid:
  spec.selector: Invalid value: v1.LabelSelector{... controller-uid=<uid> ...}:
    field is immutable
  spec.template.metadata.labels[batch.kubernetes.io/controller-uid]: Required value: must be '<uid>'
```

Root cause is Kubernetes Job immutability:

- `spec.selector` and `spec.template` are immutable after creation.
- On Job creation the Job controller injects `spec.selector.matchLabels[controller-uid]` and `spec.template.metadata.labels[batch.kubernetes.io/controller-uid]` / `controller-uid` with the Job's UID.
- A subsequent `kubectl apply` / Argo `Replace` sends the manifest **without** those injected values (they are not in Git). The API server rejects it as an immutable-field mutation and as a missing required `controller-uid`.

ArgoCD's `Replace=true` (delete + create via `kubectl replace --force` semantics) did not fix this: the Job must be deleted **before** a create with a server-generated UID. Argo's replace path still validated the replacement payload against the live object and hit the immutability check. `ignoreDifferences` on `spec.selector` / `spec.template` only hid the diff in the UI — the payload still lacked `controller-uid` and was rejected.

Affected resources: all `vault-config-*` Jobs in `platform/vault/templates/eso/` and `longhorn-csi-wait` in `platform/longhorn/templates/`. Each sync left the Application `Degraded` with `OutOfSync` Jobs that required manual `kubectl delete job`.

## Decision

All one-shot, idempotent Jobs are ArgoCD **Resource Hooks** of type `Sync`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-config-monitoring
  namespace: vault
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
spec:
  ttlSecondsAfterFinished: 600  # GC fallback if hook delete fails
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: config
          # idempotent: vault policy write / vault write auth/kubernetes/role / vault kv put
```

Key properties:

- **`hook: Sync`** — hook runs on every sync (including initial and re-syncs), not only `PreSync`/`PostSync`. Hooks still respect `sync-wave` ordering: `Sync` hooks in wave `1` run in wave `1` order, after wave `0` (`vault` StatefulSet, RBAC) and before wave `2` (`ClusterSecretStore`). This preserves the `vault-config-* (1) -> ClusterSecretStore (2)` ordering established in ADR-002.
- **`hook-delete-policy: BeforeHookCreation,HookSucceeded`** — `BeforeHookCreation` deletes any previous hook Job **before** creating the new one, which is the correct fix for immutable Jobs (delete-then-create with a fresh UID). `HookSucceeded` deletes the Job after it succeeds so it does not linger as a tracked resource.
- **`ttlSecondsAfterFinished: 600` (vault) / `600` (longhorn)** — GC fallback if Argo fails to delete the hook (controller down, sync interrupted). Not the primary cleanup mechanism; the hook policy is. Previous `3600` for managed Jobs is reduced since hooks are ephemeral.
- **`sync-wave: "1"` retained** — required. Without it, hooks run unordered. With it, wave `1` hooks still gate correctly.

Why `Sync` and not `PreSync`:

- `vault-config-*` Jobs are **not** a gate for `ClusterSecretStore` creation. The ClusterSecretStore is wave `2` and tolerates a transient `role not found` (ESO retries with backoff, see ADR-002). Making them `PreSync` would block the entire Application sync on every run for no benefit and would couple hook failure to sync failure more aggressively than needed.
- `longhorn-csi-wait` (`platform/longhorn/templates/csi-wait-job.yaml`) is intentionally `Sync` in wave `1` as well: it gates CSI readiness. Keeping it `Sync` with wave ordering is consistent; `PreSync` would run before wave `0` and lose the ordering guarantee.

`CronJob` (`vault-autounseal` in `platform/vault/templates/cronjob-autounseal.yaml`) is **not** converted. A `CronJob` is mutable and generates uniquely-named `Job` children per schedule (`vault-autounseal-<timestamp>`). It does not hit the `controller-uid` immutability problem.

## Alternatives Considered

### Option A — `Replace=true` + `ignoreDifferences` (FAILED)

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Replace=true
    argocd.argoproj.io/sync-wave: "1"
spec:
  ignoreDifferences:
    - group: batch
      kind: Job
      jsonPointers:
        - /spec/selector
        - /spec/template/metadata/labels
```

Hides the diff in Argo UI but does **not** add `controller-uid` to the replacement payload. API server still rejects the create. Verified: `vault-config-*` and `longhorn-csi-wait` remained `Degraded` with `field is immutable`.

### Option B — `Prune=false` / `syncOptions: Prune=false`

Prevents Argo from deleting the Job, but then re-apply is still an update against the live Job and hits the same immutability error. Leaves orphaned Jobs.

### Option C — Deterministic `selector` / stable `controller-uid`

Attempting to set `spec.selector.matchLabels[controller-uid]` to a deterministic value in Git is rejected by the Job controller (must be the Job's own UID). Not viable.

### Option D — ArgoCD Resource Hooks with `BeforeHookCreation` (SELECTED)

Delete-before-create gives each sync a fresh UID. No payload needs to carry `controller-uid`. This is the documented pattern for immutable Jobs in ArgoCD.

## Consequences

- **Positive:** Every sync cleanly re-runs idempotent Jobs. No more `field is immutable` / `Required value must be <uid>` failures. `BeforeHookCreation` is the semantically correct fix for Job immutability.
- **Positive:** No `OutOfSync` noise. Successful hooks (`HookSucceeded`) are deleted and **not** tracked as Application resources. The Application stays `Synced/Healthy` after hook success.
- **Positive:** Safe re-run. All `vault-config-*` operations (`vault policy write`, `vault write auth/kubernetes/role/...`, `vault kv put`) and `longhorn-csi-wait` (`kubectl wait --for=condition=ready`) are idempotent.
- **Negative:** Hook logs are ephemeral. `argocd app logs` shows `hookPhase: Running/Succeeded` but Job pods are deleted after success. Debugging requires re-syncing or checking `ttlSecondsAfterFinished` fallback window. Not suitable for Jobs whose logs must persist — use a managed Job or CronJob in that case.
- **Negative:** Hooks are not part of `argocd app diff` / drift detection. If a hook is expected to enforce state continuously, it will not show `OutOfSync` when drift occurs — it only runs on sync. Acceptable here because Vault state is write-once idempotent, not continuously reconciled.
- **Neutral:** `ttlSecondsAfterFinished` is now a safety net, not the primary GC. If hook deletion fails (Argo controller restart mid-sync), the Job self-deletes after `600s`.
- **Constraint:** Hook Jobs must remain idempotent and fast (< `progressDeadlineSeconds`). Non-idempotent or long-running Jobs should not use this pattern.

## References

- ArgoCD — Resource Hooks: https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/ — `argocd.argoproj.io/hook: Sync|PreSync|PostSync|SyncFail` and `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation|HookSucceeded|HookFailed`
- Kubernetes — Job controller UID injection: `spec.selector` and `spec.template` immutability; controller injects `batch.kubernetes.io/controller-uid` and `controller-uid` labels. See `pkg/controller/job/job_controller.go` and API validation `spec.selector: field is immutable`
- This repo: `platform/vault/templates/eso/vault-config-*.yaml`, `platform/longhorn/templates/csi-wait-job.yaml` (now hooks), `platform/vault/templates/cronjob-autounseal.yaml` (remains CronJob)

## Files

| Action | File |
|--------|------|
| Created | `docs/adrs/007-argocd-jobs-as-sync-hooks.md` — this ADR |
| Updated | `docs/adrs/002-vault-config-decentralization.md` — Config Job pattern now shows hook annotations |
| Updated | `platform/vault/templates/eso/vault-config-tailscale.yaml` — `hook: Sync`, `hook-delete-policy: BeforeHookCreation,HookSucceeded`, `ttlSecondsAfterFinished: 600` |
| Updated | `platform/vault/templates/eso/vault-config-monitoring.yaml` — same |
| Updated | `platform/longhorn/templates/csi-wait-job.yaml` — `hook: Sync`, `hook-delete-policy: BeforeHookCreation,HookSucceeded`, `ttlSecondsAfterFinished: 600` |
| Kept | `platform/vault/templates/cronjob-autounseal.yaml` — remains `CronJob` (mutable, unique Jobs) |
