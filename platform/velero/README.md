# Velero — Backup & Restore (RustFS S3)

![Backend](https://img.shields.io/badge/Backend-RustFS_S3_velero--homelab-blue?style=flat-square)
![Namespace](https://img.shields.io/badge/Namespace-velero-green?style=flat-square)
![Chart](https://img.shields.io/badge/Chart-vmware--tanzu%2Fvelero_12.1.0-orange?style=flat-square)
![App](https://img.shields.io/badge/App-1.18.1-yellow?style=flat-square)

Velero backs up cluster manifests and workload data (everything except Vault — see Vault policy below) to an external RustFS S3 bucket (`velero-homelab` at `https://rustfs.lonk-mirfak.ts.net`) with GitOps automation and no manual bucket setup.

## Why this design

Velero never touches Vault (Raft PVCs, TLS, unseal material are excluded — restoring them corrupts the cluster; DR is re-bootstrap + rotation). If Velero's own S3 credentials came from Vault via ExternalSecrets, a bare-metal restore would deadlock: Vault down → no Secret → Velero can't start. Credentials are injected as a plain Kubernetes Secret before ArgoCD syncs the chart (`credentials.existingSecret: cloud-credentials`), following ADR-004 option A. Velero never reads from Vault.

Credentials file format (key `cloud`):

```ini
[default]
aws_access_key_id=AKIA...
aws_secret_access_key=...
```

## Architecture

```mermaid
flowchart LR
    ENV["Env vars<br/>VELERO_AWS_*"] --> BOOT["bootstrap/init-gitops.sh<br/>Secret cloud-credentials"]
    BOOT --> JOB["Job velero-bucket-init<br/>hook Sync wave 0"]
    JOB --> CHART["Helm chart velero<br/>vmware-tanzu 12.1.0 / app 1.18.1"]
    CHART --> BSL["BackupStorageLocation default<br/>bucket velero-homelab (RustFS)"]
    BSL --> RUSTFS[("RustFS S3")]
    CHART -.->|excluded| VAULT["Vault ns<br/>re-bootstrap, never restore"]
```

Wave `-1` `tailscale-operator` → wave `0` `coredns-patch` (ts.net MagicDNS) + `velero` + `longhorn` → wave `1` `vault`. Guarantees DNS and storage are ready before Vault creates PVCs.

## Schedules

| Schedule | Cron | Scope | TTL | Status |
|----------|------|-------|-----|--------|
| `daily-full` | `0 2 * * *` | all namespaces except `vault`, control-plane (`velero`, `kube-*`, `longhorn-system`, `argocd`) | 30d | active |
| `vault-hourly` | `0 * * * *` | `vault` namespace (retired) | 7d | `disabled: true` — see Vault policy |

- `defaultVolumesToFsBackup: true` + `deployNodeAgent: true` + `nodeAgent.enabled: true` → Longhorn PVCs backed up via filesystem copy (no CSI snapshots). The node-agent gate and the FsBackup default must stay on together.
- Resource guard: `resources.limits.memory: 512Mi` (chart default `128Mi` OOMKills during FsBackup on this homelab) — do not lower it.
- Storage: `s3ForcePathStyle: true`, `s3Url: https://rustfs.lonk-mirfak.ts.net`, `region: us-east-1`, `prefix: velero/`, single BSL `default`.

## Vault policy — excluded, re-bootstrap + rotation

Nothing of Vault is stored in Velero: `daily-full` carries `vault` in `excludedNamespaces`, and `vault-hourly` is disabled (kept in `values.yaml` as documentation of the retired schedule).

Restoring Raft state from Velero corrupts the cluster, and Vault holds no irreplaceable PKI/transit material, so DR is `platform/vault/scripts/bootstrap-vault.sh` (init when `initialized==false`, unseal, kv-v2 + k8s auth) followed by secret rotation — never a Velero restore.

Hourly crash-consistency for Vault volumes is a Longhorn local snapshot instead: `platform/longhorn/templates/recurringjobs.yaml` (`RecurringJob` `vault-hourly-snapshot`, `task: snapshot`, `cron: 0 * * * *`, `retain: 24`). `snapshot` is local copy-on-write; `backup` would need an S3/NFS target that is intentionally unconfigured. Volumes opt in via the `vault-hourly` group label (`recurring-job-group.longhorn.io/vault-hourly=enabled`). Daily snapshot templates for `seaweedfs`/`monitoring` are commented out in the same file.

## Quick start

```bash
# 1. Create Secret and sync
VELERO_AWS_ACCESS_KEY_ID=... VELERO_AWS_SECRET_ACCESS_KEY=... ./bootstrap/init-gitops.sh prod

# 2. Verify
kubectl -n velero get backupstoragelocations -o yaml  # phase: Ready
kubectl -n velero get pods -l app.kubernetes.io/name=velero
kubectl -n velero logs job/velero-bucket-init

# 3. Test backup
velero backup create manual-$(date +%Y%m%d%H%M) --wait
velero backup get
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `secret cloud-credentials not found` | Re-run bootstrap with `VELERO_AWS_*` or `AWS_*` env vars |
| `NoSuchBucket` | Check `kubectl -n velero logs job/velero-bucket-init`; re-sync ArgoCD |
| `BSL not Ready` | Verify `s3Url`/`s3ForcePathStyle` and `cloud` key format is `[default]` ini |
| `nslookup rustfs.lonk-mirfak.ts.net` fails | Verify `kubectl -n kube-system get cm coredns -o yaml | grep ts.net` |

## Files

| Path | Purpose |
|------|---------|
| `Chart.yaml` / `values.yaml` | Wrapper chart and schedules/storage config |
| `templates/job-bucket-init.yaml` | Sync hook that creates the bucket idempotently |
| `templates/networkpolicies.yaml` | Scopes tailnet egress to `velero` namespace |
| `gitops/templates/apps/05-velero.yaml` | ArgoCD Application (wave 0) |
| `bootstrap/init-gitops.sh` | Creates `cloud-credentials` Secret |

## References

- [docs/velero.md](../../docs/velero.md) — detailed flow and wave ordering
- [docs/runbook-vault-restore.md](../../docs/runbook-vault-restore.md) — Vault DR procedure
- [ADR-004](../../docs/adrs/004-tailscale-oauth-seed-strategy.md) — bootstrap secret precedent
