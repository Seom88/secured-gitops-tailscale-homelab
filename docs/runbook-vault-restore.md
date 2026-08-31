# Vault DR Runbook — Proxmox VM Restore & Raft Recovery

> **Scope:** Vault HA Raft (3 replicas, `vault-0/1/2`), Proxmox `vzdump` VM-level backup, Longhorn PVCs, `vault-autounseal` CronJob `*/2`, Velero/RustFS complement.
> **Golden rule:** **Restore only `vault-2` at Proxmox VM level, wipe followers (`vault-0`, `vault-1`) via PVC delete + Raft re-join, let `vault-autounseal` heal.** Never restore all 3 Vault VMs simultaneously from vzdump.
> **Canonical location:** `docs/runbook-vault-restore.md` (moved from `platform/vault/scripts/`). Stub remains at the old path for backward links.

---

## Table of Contents

1. [Context](#1-context)
2. [Observed Failure State](#2-observed-failure-state)
3. [Why Proxmox vzdump Breaks Raft](#3-why-proxmox-vzdump-breaks-raft)
4. [Golden Rule](#4-golden-rule)
5. [Prerequisites](#5-prerequisites)
6. [Procedure A — Single-Leader VM Restore (Primary)](#6-procedure-a--single-leader-vm-restore-primary)
7. [Procedure B — Raft Snapshot Save/Restore (Atomic)](#7-procedure-b--raft-snapshot-saverestore-atomic)
8. [Procedure C — Velero/RustFS Complement](#8-procedure-c--velerorustfs-complement)
9. [Autounseal & Raft Recovery (`*/2`)](#9-autounseal--raft-recovery-2)
10. [Verification](#10-verification)
11. [Troubleshooting](#11-troubleshooting)
12. [Prevention & Hardening](#12-prevention--hardening)
13. [Appendix — Useful Commands](#13-appendix--useful-commands)
14. [References](#14-references)

---

## 1. Context

- **Chart:** `platform/vault` (HashiCorp Vault `1.15+`, Helm `vault 0.34.1`), 3 replicas (`vault-0`, `vault-1`, `vault-2`), Raft integrated storage on Longhorn PVCs (`data-vault-0/1/2`), TLS via `vault-tls` (cert-manager), autounseal via `vault-autounseal` CronJob.
- **Infra backup:** Proxmox `vzdump` at hypervisor level snapshots each VM (`cp-1`, `cp-2`, `cp-3` or similar) **sequentially**. Each VM dump is consistent locally, but the three dumps are **not coordinated** — there is no cross-VM barrier.
- **Kubernetes backup:** Velero `9.0.2` (`platform/velero`, wave `0`) with RustFS S3 `velero-homelab` (`https://rustfs.lonk-mirfak.ts.net`, `prefix velero/`) provides `daily-full` (all ns, 30d) and `vault-hourly` (namespace `vault`, 7d, `secrets/configmaps/pvc/cronjobs`). See `docs/velero.md`.
- **Chicken-egg:** Velero backs up Vault (`vault-tls`, `vault-unseal-keys`, PVCs). Velero credentials (`velero/cloud-credentials`) live **outside** Vault/ESO (`bootstrap/init-gitops.sh:ensureVeleroCredentials()`), wave `-1` Job `velero-bucket-init` creates the bucket. Vault is never in Velero's credential path.
- **Waves:** `longhorn` + `velero` wave `0`, `vault` wave `1`, `seaweedfs` wave `2` — Velero must be `Ready` before Vault creates PVCs.

## 2. Observed Failure State

After restoring **all 3 Vault VMs** from Proxmox vzdumps taken minutes apart (non-atomic):

| Pod | Status | `vault status` | Symptom |
|-----|--------|----------------|---------|
| `vault-0` | `CrashLoopBackOff` | `sealed=true` or TLS `x509: certificate signed by unknown authority` | Raft log diverged; follower cannot join leader with stale term |
| `vault-1` | `Running` but `initialized=false` | `initialized=false` | Raft data wiped or peers.json inconsistency; not part of quorum |
| `vault-2` | `Running` `initialized=true sealed=false standby=false` | **Unsealed, leader** | Only peer with quorum-real data; survives as single source of truth |

Logs:
```
vault-0: failed to join raft cluster: failed to join raft cluster: not a member
vault-1: core: vault is uninitialized
vault-2: core: vault is unsealed
```

Autounseal at `*/15` (legacy) did **not** self-heal: it only attempted `vault operator unseal`, not `raft remove-peer` / `raft join`. Followers stayed `CrashLoop` or `not initialized` indefinitely until manual intervention. Fixed to `*/2` with full Raft recovery (see §9).

**Lesson:** Hypervisor-level VM restore is **not** a substitute for Raft-consistent backup.

## 3. Why Proxmox vzdump Breaks Raft

Raft guarantees linearizability only when **one** log is the source of truth. vzdump captures each VM's disk at `T0`, `T1`, `T2` seconds apart:

```
T0: vzdump cp-1 (vault-0) — Raft term 42, index 1200
T1: vzdump cp-2 (vault-1) — term 42, index 1207
T2: vzdump cp-3 (vault-2) — term 43, index 1215 (leader advanced)
```

Restoring all three replays divergent logs. No peer has a majority for term 43, so quorum fails. Peers reject each other's `AppendEntries` (term mismatch, `peers.json` stale). Result is split-brain CrashLoop.

**Fix:** Restore **one** peer (the latest or the known unsealed `vault-2`), wipe followers' PVCs, re-join them empty.

## 4. Golden Rule

> **Restore exactly ONE Vault VM at Proxmox level — `vault-2` if it was the unsealed leader — then delete followers' PVCs and let them re-join empty. Let `vault-autounseal` (`*/2`) do `remove-peer` + `join` + `unseal`.**

- `vault-2` is conventional: scheduler places it on `cp-3` (configurable via `affinity`), but any *single* VM works if you are sure it was leader. `vault-2` naming is stable due to StatefulSet ordinal; picking `-2` avoids human choice error.
- Do **not** restore `vault-0` + `vault-1` + `vault-2` together.
- Do **not** `kubectl delete pvc data-vault-2` — that would destroy the only good Raft log.
- Alternatives: Raft snapshot (§7) is preferred for point-in-time atomic restore; Velero (§8) is for Kubernetes objects, not Raft log.

## 5. Prerequisites

- `kubectl` with kubeconfig from infra state (`terraform output -raw kubeconfig` or `aws s3api get-object` fallback — see `docs/ci-cd.md`).
- Access to Proxmox VE (VMs `vault-*` nodes, vzdump storage `local`/`nfs`).
- `VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt`, `vault` CLI if doing snapshot path.
- Confirm which VM holds `vault-2` today: `kubectl -n vault get pods -o wide` → node, then `pvesh get /nodes/<node>/qemu` or Proxmox UI.
- Bucket `velero-homelab` exists (Job `velero-bucket-init` wave `-1` already ran). Not required for golden rule, but needed if you will also Velero-restore.

## 6. Procedure A — Single-Leader VM Restore (Primary)

### 6.1 Identify leader before restore (if cluster still partially up)

```bash
for p in vault-0 vault-1 vault-2; do
  echo "== $p =="; kubectl -n vault exec $p -c vault -- \
    sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault status -format=json -tls-server-name=vault 2>/dev/null | jq -r "[.ha_mode,.sealed,.initialized,.leader_address] | @tsv"'
done
# Choose the peer with sealed=false, ha_mode=active or standby=false and highest term
```

If cluster is fully down, pick `vault-2` by convention.

### 6.2 Quiesce workloads (optional but recommended)

```bash
kubectl -n argocd patch application vault --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n vault scale statefulset vault --replicas=0 --timeout=60s || true
# Wait for pods terminated: kubectl -n vault get pods -w
```

### 6.3 Proxmox restore — ONE VM only

In Proxmox UI or CLI, restore **only** the VM backing `vault-2` (e.g., `qemu 102` on `cp-3`) from its vzdump archive:

```bash
# Example on Proxmox host (pvesh / qmrestore)
qmrestore /var/lib/vz/dump/vzdump-qemu-102-2026_08_30-02_00_01.vma.zst 102 --force 1 --storage local-lvm
qm start 102
# Wait VM boots, k3s/talos agent joins: pvesh get /nodes/cp-3/qemu/102/status/current
```

Verify the node is Ready:
```bash
kubectl get nodes -o wide   # vault-2's node should be Ready, others remain NotReady or stay as before
kubectl -n vault get pods -o wide  # expect vault-2 pending/running after node Ready
```

### 6.4 Wipe followers' Raft data (do NOT touch vault-2)

```bash
# Delete PVCs for vault-0 and vault-1 — Longhorn will recreate empty volumes
kubectl -n vault delete pvc data-vault-0 data-vault-1 --wait=true --ignore-not-found
# If StatefulSet still at 3, delete the pods so they recreate with empty PVCs
kubectl -n vault delete pod vault-0 vault-1 --ignore-not-found --force --grace-period=0 || true
# Do NOT delete data-vault-2
```

If Longhorn `volumeAttachment` lingers:
```bash
kubectl -n vault get pvc data-vault-0 data-vault-1
kubectl get volumeattachments | grep vault
kubectl delete volumeattachment <id> --ignore-not-found
```

### 6.5 Let autounseal heal (or trigger manually)

The CronJob `vault-autounseal` (`schedule: "*/2 * * * *"`, `platform/vault/templates/unseal/cronjob-autounseal.yaml`, script `platform/vault/templates/unseal/configmap-autounseal.yaml`) runs every 2 minutes:

- discovers pods, reads `vault-unseal-keys` Secret (`key1..keyN` dynamic, supports 3 or 5),
- validates `vault-tls` CA,
- for each pod: if `CrashLoop` or `not Running` → `vault operator raft remove-peer $POD` via healthy leader,
- if `initialized=false` → `vault operator raft join https://<healthy>.vault-internal.vault.svc.cluster.local:8200`,
- if `sealed=true` → `vault operator unseal` with all keys (TLS-aware, retry 3).

Wait 2–4 minutes:
```bash
kubectl -n vault logs -l app.kubernetes.io/name=vault-autounseal --tail=100 -f
kubectl -n vault get cronjob vault-autounseal -o yaml | grep schedule
kubectl -n vault get pods -w
```

Manual trigger if you cannot wait:
```bash
kubectl -n vault create job --from=cronjob/vault-autounseal vault-autounseal-manual-$(date +%s)
kubectl -n vault logs job/vault-autounseal-manual-... -f
```

Or run the recovery inline (fallback without CronJob):
```bash
HEALTHY=vault-2
for POD in vault-0 vault-1; do
  kubectl -n vault exec $HEALTHY -c vault -- sh -c "VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft list-peers -tls-server-name=vault || true"
  kubectl -n vault exec $HEALTHY -c vault -- sh -c "VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft remove-peer -tls-server-name=vault $POD || VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft remove-peer $POD || true"
done
for POD in vault-0 vault-1; do
  kubectl -n vault exec $POD -c vault -- sh -c "VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft join -tls-server-name=vault https://${HEALTHY}.vault-internal.vault.svc.cluster.local:8200 2>&1 || VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft join https://${HEALTHY}.vault-internal.vault.svc.cluster.local:8200"
done
```

### 6.6 Unseal if still sealed (autounseal does this automatically)

If `vault-0`/`vault-1` still report `sealed=true` after join:
```bash
SECRET=$(kubectl -n vault get pod vault-2 -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}')
for POD in vault-0 vault-1; do
  for K in $(kubectl -n vault get secret ${SECRET}-unseal-keys -o json | jq -r '.data | keys[] | select(test("^key"))'); do
    KEY=$(kubectl -n vault get secret ${SECRET}-unseal-keys -o jsonpath="{.data.$K}" | base64 -d)
    kubectl -n vault exec $POD -c vault -- sh -c "VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator unseal -tls-server-name=vault '$KEY' >/dev/null 2>&1 || VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator unseal '$KEY' >/dev/null 2>&1 || true"
  done
done
```

### 6.7 Restore workloads

```bash
kubectl -n vault scale statefulset vault --replicas=3 || true
kubectl -n argocd patch application vault --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' || true
```

## 7. Procedure B — Raft Snapshot Save/Restore (Atomic)

Preferred for **point-in-time** consistency when Vault is still reachable (even degraded). This is the only atomic DR primitive for Raft.

### Save (before disaster or from healthy leader)

```bash
# From inside leader or via kubectl exec
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft snapshot save -tls-server-name=vault /tmp/vault-raft.snap'
kubectl -n vault cp vault/vault-2:/tmp/vault-raft.snap ./vault-raft-$(date +%Y%m%d%H%M).snap
# Store off-cluster (RustFS, local encrypted disk) — NOT on a Longhorn PVC
ls -lh vault-raft-*.snap
```

Schedule periodic snapshots via CronJob if desired (not yet in this repo; Velero does not replace this).

### Restore (after quorum loss)

```bash
# Option 1: restore into empty leader (follow §6.4 wiping followers first)
kubectl -n vault cp ./vault-raft-YYYYMMDDHHMM.snap vault/vault-2:/tmp/vault-raft.snap
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft snapshot restore -tls-server-name=vault /tmp/vault-raft.snap'
# Then wipe followers (§6.4) and let autounseal re-join (§6.5)

# Option 2: local vault CLI with port-forward
kubectl -n vault port-forward svc/vault 18200:8200 &
export VAULT_ADDR='https://127.0.0.1:18200' VAULT_CACERT=/tmp/ca.crt
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
vault operator raft snapshot save ./vault-raft.snap -tls-server-name=vault
vault operator raft snapshot restore ./vault-raft.snap -tls-server-name=vault
```

Verify:
```bash
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft list-peers -tls-server-name=vault'
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault status -format=json -tls-server-name=vault | jq'
```

## 8. Procedure C — Velero/RustFS Complement

**When to use:** you lost Kubernetes objects (Secrets, ConfigMaps, PVC definitions, CronJobs) or need to restore a namespace after `velero backup` + cluster rebuild. **Not** for Raft log atomicity.

- **Schedules:** `daily-full` `0 2 * * *` (all ns, `defaultVolumesToFsBackup: true` via node-agent, 30d TTL), `vault-hourly` `0 * * * *` (ns `vault`, `secrets/configmaps/pvc/cronjobs`, 7d TTL). See `platform/velero/values.yaml`.
- **Precondition:** Velero credentials `velero/cloud-credentials` (key `cloud` ini) must exist — created by `bootstrap/init-gitops.sh:ensureVeleroCredentials()` before Velero sync. Bucket `velero-homelab` created by wave `-1` Job `velero-bucket-init` (`amazon/aws-cli:2.15.0`, `Prune=false`, idempotent `create-bucket || true` + `head-bucket`). No manual `aws s3api` needed unless Job cannot run.
- **Caveat:** SeaweedFS-internal S3 was **rejected** for Velero — if the cluster is lost, SeaweedFS is also lost, so backups are unreachable (chicken-egg). RustFS external (`https://rustfs.lonk-mirfak.ts.net`) survives cluster loss.

### 8.1 Velero backup (manual verification)

```bash
velero backup create manual-$(date +%Y%m%d%H%M) --wait --storage-location default
velero backup get
velero backup describe manual-... --details
velero backup logs manual-...
aws s3 ls s3://velero-homelab/velero/backups/ --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1 --recursive | head
```

### 8.2 Velero restore (after bootstrap)

```bash
# Bootstrap must have run: ensureVeleroCredentials() + velero wave 0 Ready
kubectl -n velero get backupstoragelocations.velero.io -o yaml  # phase Ready
velero restore create --from-backup <backup-name> --wait
velero restore get
velero restore describe <name> --details
# For Vault, reconcile Raft after object restore: still need §6.5 join/unseal
```

**Do not** rely on Velero alone to recover Vault Raft quorum — always follow with §6.5/§7.

## 9. Autounseal & Raft Recovery (`*/2`)

- **Manifests:** `platform/vault/templates/unseal/configmap-autounseal.yaml` (script `unseal.sh`), `platform/vault/templates/unseal/cronjob-autounseal.yaml`.
- **Schedule:** `*/2 * * * *` (was `*/15` — too slow, did not autocure after vzdump restore). `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3`, `activeDeadlineSeconds: 300`.
- **Image:** `bitnami/kubectl:latest` with `jq` if available (fallback `grep`).
- **Behavior per pod:**
  1. Discover pods `-l app.kubernetes.io/name=vault,component=server`.
  2. Derive `*-unseal-keys` Secret from first pod's `app.kubernetes.io/instance` label; read keys `key1..keyN` (dynamic, supports 3 or 5) idempotently; validate `vault-tls` CA (`ca.crt` presence + `/vault/userconfig/vault-tls/ca.crt` inside pod).
  3. Select healthy leader (`initialized=true sealed=false`, prefers `vault-2`).
  4. For each pod:
     - `phase!=Running` or `container not running` → `vault operator raft remove-peer $POD` via leader (no pod deletion).
     - `initialized!=true` → `vault operator raft join https://<leader>.vault-internal.vault.svc.cluster.local:8200`.
     - `sealed=true` → `vault operator unseal` with all keys (TLS-aware, `RETRY_ATTEMPTS=3`, `TIMEOUT=20`).
  5. Exit `1` if any pod failed → CronJob `Failed`, re-tries next `*/2`.

Logs show sanitized progress without leaking keys:
```bash
kubectl -n vault logs -l app.kubernetes.io/name=vault-autounseal --tail=100
# [autounseal] Loaded 3 unseal keys dynamically: key1 key2 key3
# [raft-recovery] Selected leader candidate vault-2 (unsealed, healthy)
# [raft-recovery] Pod vault-0 is NOT initialized — attempting raft join via leader...
# [unseal] Pod vault-0 unsealed successfully.
```

## 10. Verification

```bash
# Vault health
kubectl -n vault get pods -o wide
for p in vault-0 vault-1 vault-2; do
  kubectl -n vault exec $p -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault status -tls-server-name=vault || true'
done
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft list-peers -tls-server-name=vault'
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator members -tls-server-name=vault 2>&1 || true'

# Leader election
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault status -format=json -tls-server-name=vault | jq -r .leader_address'

# ESO
kubectl get clustersecretstores.external-secrets.io -A
kubectl get externalsecrets.external-secrets.io -A

# Velero
kubectl -n velero get backupstoragelocations.velero.io -o yaml
kubectl -n velero get schedules.velero.io
velero backup get | head

# ArgoCD
kubectl -n argocd get applications | grep -E 'vault|velero|longhorn'
```

Expected healthy state:
```
vault-0 Running 1/1 sealed=false initialized=true standby=true
vault-1 Running 1/1 sealed=false initialized=true standby=true
vault-2 Running 1/1 sealed=false initialized=true standby=false (leader)
raft list-peers: 3 peers, voter, leader_address = https://vault-2.vault-internal...
```

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `vault-0 CrashLoopBackOff` after all-3 VM restore | Divergent Raft logs (non-atomic vzdump) | Single-leader restore (§6), wipe `data-vault-0/1`, autounseal `*/2` will `remove-peer` + `join` |
| `vault-1 not initialized` | Empty or stale `peers.json` / wiped PVC | `vault operator raft join` via leader (§6.5); autounseal handles automatically |
| `x509: certificate signed by unknown authority` | `vault-tls` CA mismatch between restored VM and live `vault-tls` Secret | Re-issue cert-manager `Certificate vault-tls` or restore `vault-tls` Secret from Velero `vault-hourly`; autounseal validates CA and logs `WARNING: CA file not found` |
| Autounseal logs `No healthy unsealed peer` | All 3 sealed or not Running | Unseal `vault-2` manually: `vault operator unseal` with keys from `vault-unseal-keys` Secret, then let CronJob heal followers |
| `secret "cloud-credentials" not found` / `velero-bucket-init` fails | `ensureVeleroCredentials()` not run (no `VELERO_AWS_*` or `AWS_*` env) | `VELERO_AWS_ACCESS_KEY_ID=... VELERO_AWS_SECRET_ACCESS_KEY=... ./bootstrap/init-gitops.sh prod` or reuse `AWS_*`; `kubectl -n velero logs job/velero-bucket-init` |
| `NoSuchBucket velero-homelab` | Bucket not created (Job did not run or Secret missing) | `kubectl -n velero get job velero-bucket-init && kubectl logs job/velero-bucket-init`; fallback `aws s3api create-bucket --bucket velero-homelab --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1` |
| `BackupStorageLocation not Ready` | Bad `cloud` format or RustFS unreachable via Tailscale | Verify `kubectl -n velero get secret cloud-credentials -o jsonpath='{.data.cloud}' | base64 -d` is `[default]` ini; `aws s3 ls --endpoint-url https://rustfs.lonk-mirfak.ts.net` from cluster |
| Vault `Sealed` after join | Keys not yet applied | Autounseal `*/2` will unseal in next cycle; or manual `vault operator unseal` loop (§6.6) |

## 12. Prevention & Hardening

- **Prefer Raft snapshots** for Vault DR: `vault operator raft snapshot save` cron outside vzdump (future: `vault-raft-snapshot` CronJob pushing to RustFS). vzdump is for full VM DR, not Vault quorum.
- **Never schedule Proxmox vzdump for all Vault VMs at the same window without coordination** — stagger or exclude Vault VMs and rely on Raft snapshots + Velero.
- **Keep `vault-autounseal` at `*/2`** with Raft recovery. Do not regress to `*/15` unseal-only script.
- **Test restore drill quarterly:** single-leader vzdump restore + follower wipe + autounseal verification + `vault operator raft snapshot restore` dry-run.
- **Velero:** keep `nodeAgent.enabled: true`, `schedules` enabled, verify `BackupStorageLocation Ready` after every bootstrap.

## 13. Appendix — Useful Commands

```bash
# Raft peers
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft list-peers -tls-server-name=vault -detailed || VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft list-peers'

# Snapshot save/restore
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft snapshot save -tls-server-name=vault /tmp/snap && ls -lh /tmp/snap'
kubectl -n vault exec vault-2 -c vault -- sh -c 'VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator raft snapshot restore -tls-server-name=vault /tmp/snap'

# Autounseal manual run
kubectl -n vault create job --from=cronjob/vault-autounseal vault-autounseal-manual-$(date +%s%N | cut -c1-8)
kubectl -n vault logs -l app.kubernetes.io/name=vault-autounseal --tail=50

# Velero
velero backup get; velero schedule get; kubectl -n velero get backupstoragelocations.velero.io
aws s3 ls s3://velero-homelab/ --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1 --recursive
```

## 14. References

- This repo: `platform/vault/values.yaml` (3 replicas, Raft), `platform/vault/templates/unseal/configmap-autounseal.yaml` + `cronjob-autounseal.yaml` (`*/2` with raft recovery), `platform/velero/values.yaml` + `templates/job-bucket-init.yaml` (wave `-1`, `amazon/aws-cli:2.15.0`), `gitops/templates/apps/05-velero.yaml` (wave `0`), `bootstrap/init-gitops.sh:ensureVeleroCredentials()`, `docs/velero.md`, `docs/ci-cd.md`, `docs/adrs/004-tailscale-oauth-seed-strategy.md` (bootstrap outside Vault precedent), `docs/adrs/009-vault-dr-and-velero-backup.md`.
- Vault: `vault operator raft snapshot save/restore`, `vault operator raft join/remove-peer/list-peers`, `vault status -format=json` — https://developer.hashicorp.com/vault/docs/enterprise/raft
- Velero: https://velero.io/docs/ — AWS plugin, `BackupStorageLocation`, `nodeAgent`, `Schedule`
- Proxmox: `vzdump` / `qmrestore` — https://pve.proxmox.com/wiki/Backup_and_Restore
- ADR-009: `docs/adrs/009-vault-dr-and-velero-backup.md` — decision record for this runbook + Velero complement

---

*Golden rule: one VM, empty followers, autounseal heals. Raft snapshot is atomic; vzdump is not; Velero is complement, not replacement.*
