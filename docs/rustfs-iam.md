# RustFS IAM — Per-Service Backup Keys

> **Scope:** RustFS is an **external system** (separate VM, managed outside this repo).
> This doc is the runbook for creating least-privilege S3 keys for cluster
> consumers (Longhorn, Velero). Cluster side (SOPS + bootstrap fallback) is
> wired here; the keys themselves are created in RustFS and never committed.

## Concepts (what matters here)

- **Service accounts (Access Keys)** are derived credentials owned by a parent
  user. They inherit the parent's permissions, **optionally restricted further
  by an embedded session policy**, and can carry an expiration time.
  They are the right shape for app keys: one per consumer, scoped, expirable.
- **Session policy = intersection**: parent policies AND session policy must
  both allow. A session policy can only *narrow*, never widen.
- **"Use main account policy" toggle** (Console): when ON, the key inherits
  the parent's full policy. Our parent is root-equivalent (`admin:*`,
  `kms:*`, `s3:*` on `arn:aws:s3:::*`) — **always leave it OFF** for service
  keys and attach a scoped session policy instead.
- Reference: [RustFS IAM](https://docs.rustfs.com/en/security-compliance/iam),
  [policies](https://docs.rustfs.com/en/security-compliance/iam/policies),
  [service accounts](https://docs.rustfs.com/en/security-compliance/iam/sts).

## Console flow (verified 2026-09-21)

Console → left nav **Access Keys** → **Add Access Key** (top right) →
**Create Key** dialog:

1. **Name**: `longhorn-backup` / `velero-backup`. **Description**: what it is
   for (e.g. `Longhorn daily backups - homelab`).
2. **Access Key**: leave blank to autogenerate; if Submit complains, type the
   name by hand. **Secret Key** comes pre-generated (masked).
3. **Expiry**: set ~1 year out (e.g. `2027-09-21`). Empty = permanent;
   acceptable in a homelab but then rotation never happens — prefer expirable
   and calendar the rotation (see below).
4. **"Use main account policy"**: leave **OFF**.
5. If a policy box appears with the toggle off, paste the scoped JSON for the
   consumer (see examples). If no policy box appears, Submit anyway and scope
   afterwards via admin API — the key is still isolated from root, scoping is
   follow-up, not blocker.
6. On confirm the pair is shown **once** — Copy/Export immediately, there is
   no second chance.

## Scoped policies

Backups need **delete** (Longhorn `retain: 3` prunes old backups; Velero
prunes by TTL), so these allow `s3:DeleteObject` — scoped to the single
bucket. (A WORM/archive key would deny deletes; not our case.)

### Longhorn (`longhorn-homelab`)

` s3:CreateBucket` is required: the `longhorn-bucket-init` Job creates the
bucket idempotently with the scoped key itself (scoped to this one ARN, so
least-privilege still holds — the key cannot create or touch any other
bucket).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:CreateBucket"],
      "Resource": ["arn:aws:s3:::longhorn-homelab"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::longhorn-homelab/*"]
    }
  ]
}
```

### Velero (`velero-homelab`)

Same `s3:CreateBucket` requirement as Longhorn — the `velero-bucket-init`
Job creates the bucket with the scoped key.

Mirrors the upstream [minimal policy](https://github.com/velero-io/velero-plugin-for-aws/)
(EC2 snapshot actions omitted — no EBS here; `GetBucketLocation` added: harmless
read that helps `head-bucket`/diagnostics). No `ListAllMyBuckets` — Velero never
lists buckets, it goes straight to its own:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:CreateBucket"],
      "Resource": ["arn:aws:s3:::velero-homelab"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::velero-homelab/*"]
    }
  ]
}
```

## Cluster handoff (SOPS — operator encrypts, never shares plaintext)

1. Scaffolds already exist with `CHANGEME` placeholders — replace the values
   with the real keys (shapes below for reference):
   `platform/longhorn/sops/backup-credentials.enc.yaml`,
   `platform/velero/sops/cloud-credentials.enc.yaml`.
   Then encrypt from the repo root per [docs/sops.md](sops.md):
2. Exact Secret shapes (no Helm templating inside `.enc.yaml` — pure YAML):

   `platform/longhorn/sops/backup-credentials.enc.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: longhorn-backup-secret
     namespace: longhorn-system
   stringData:
     AWS_ACCESS_KEY_ID: <longhorn key>
     AWS_SECRET_ACCESS_KEY: <longhorn secret>
     AWS_ENDPOINTS: https://rustfs.lonk-mirfak.ts.net
   ```
   (Endpoint duplicates `sharedS3.tailnetFqdn` — known tradeoff, FQDN rarely
   changes.)

   `platform/velero/sops/cloud-credentials.enc.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloud-credentials
     namespace: velero
   stringData:
     cloud: |-
       [default]
       aws_access_key_id=<velero key>
       aws_secret_access_key=<velero secret>
   ```
3. Apply: `just secrets-apply` (decrypt + `kubectl apply`, shreds key after).
4. `bootstrap/init-gitops.sh` (`ensureVeleroCredentials`,
   `ensureLonghornBackupCredentials`) stays as **fallback**: if the Secret
   already exists via SOPS and no env creds are set, it does not touch it;
   env creds still allow bootstrap/rotation without SOPS.

## Automation (Terraform)

Short answer: possible, not recommended yet.

- Community provider [`weinmann-emt/rustfs`](https://github.com/weinmann-emt/terraform-provider-rustfs)
  (`~> 0.0.7`, ~15 stars, MPL-2.0) exposes `rustfs_user` (with `policy`),
  `rustfs_serviceaccount`, `rustfs_policy`, `rustfs_group`. It exists precisely
  because `mc admin` does not work against RustFS
  ([issue #567](https://github.com/rustfs/rustfs/issues/567)).
- Caveats: immature (pin the version, test against dev first); the provider
  author's own note says IAM support was bolted on; `secret_key` lands in
  **Terraform state in plaintext** — acceptable only with an encrypted
  backend; and RustFS itself lives in the **infra repo**, so this code would
  not live here anyway.
- `rc` CLI gained user creation (`v0.1.2`) but policy attach was still
  `NotImplemented` ([issue #1571](https://github.com/rustfs/rustfs/issues/1571));
  raw admin API (`PUT /rustfs/admin/v3/...`, SigV4-signed) is always available
  as escape hatch.
- **Decision (2026-09-21): console for now (2 keys), revisit when key count
  grows or the provider matures.** ClickOps on an external box twice a year
  beats maintaining TF glue against a 15-star provider.

## Rotation

1. Create the replacement key in console (same name + `-next`, same policy).
2. Re-encrypt the SOPS file (`sops platform/<chart>/sops/<name>.enc.yaml`),
   `just secrets-apply`, verify consumer works (Longhorn backup target OK /
   Velero BSL Available).
3. Disable (don't delete yet) the old key → wait one backup cycle → delete.
