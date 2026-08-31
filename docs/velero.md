# Velero + RustFS — Backup & Restore

> **Stack:** Velero `9.0.2` (vmware-tanzu) → RustFS S3 `velero-homelab` (`https://rustfs.lonk-mirfak.ts.net`) · **Namespace:** `velero` · **Chart:** `platform/velero` · **ArgoCD wave:** `0` (junto a Longhorn)
> **Referencia precedente:** [ADR-004](adrs/004-tailscale-oauth-seed-strategy.md) opción A — por qué algunos secretos no pasan por Vault/ESO.

> **CI/CD general:** Ver [CI / CD](./ci-cd.md) para workflows `validate.yaml` / `deploy.yaml`, quality gates, Justfile y Renovate. Este documento cubre solo Velero.

## 1. El problema: chicken-egg

Velero necesita credenciales S3 para escribir backups. El camino "natural" en este repo sería:

```
Vault (secret/rustfs) → ExternalSecret → Secret Kubernetes → Velero
```

Pero Velero **respalda Vault** (sus PVCs Raft y los Secrets `vault-tls`, `vault-unseal-keys`). Si las credenciales de Velero vienen de Vault, un restore desnudo no puede arrancar Velero porque Vault aún no está disponible — deadlock.

La solución es la misma que el precedente de ADR-004 opción A: un **bootstrap Secret efímero fuera de Vault/ESO**, creado por `bootstrap/init-gitops.sh` desde variables de entorno locales/CI, y referenciado por el chart via `credentials.existingSecret`.

Velero nunca lee de Vault; Vault es *consumidor* del backup, no fuente.

## 2. Flujo completo

```mermaid
flowchart LR
    subgraph Local / CI
        ENV[Env vars<br/>VELERO_AWS_ACCESS_KEY_ID<br/>VELERO_AWS_SECRET_ACCESS_KEY<br/>fallback: AWS_*]
    end
    subgraph Bootstrap
        SCRIPT[bootstrap/init-gitops.sh<br/>ensureVeleroCredentials()]
        SECRET[(Secret velero/cloud-credentials<br/>key: cloud<br/>[default] ini)]
    end
    subgraph ArgoCD
        APP[Application velero<br/>wave 0<br/>CreateNamespace=true]
        CHART[Helm chart velero<br/>vmware-tanzu 9.0.2<br/>credentials.existingSecret=cloud-credentials]
    end
    subgraph Storage
        RUSTFS[RustFS S3<br/>https://rustfs.lonk-mirfak.ts.net<br/>bucket: velero-homelab<br/>prefix: velero/]
        SCHED1[(Schedule daily-full<br/>0 2 * * *<br/>TTL 30d)]
        SCHED2[(Schedule vault-hourly<br/>0 * * * *<br/>TTL 7d)]
    end

    ENV --> SCRIPT --> SECRET --> CHART --> RUSTFS
    APP --> CHART
    RUSTFS --> SCHED1
    RUSTFS --> SCHED2
```

**Orden de waves (ArgoCD `argocd.argoproj.io/sync-wave`):**

| Wave | Apps | Política | Notas |
|------|------|----------|-------|
| `0` | `longhorn`, `velero` | `healthy` | Almacenamiento y backup deben estar sanos antes que nada |
| `1` | `vault` | `healthy` | Depende de Longhorn (PVCs) y opcionalmente Velero (restore) |
| `2` | `seaweedfs` | `healthy` | S3 interno (no usado por Velero, que va a RustFS) |
| `3` | `monitoring` | `sync-only` | Puede tolerar degraded |
| `4` | `tailscale` | `sync-only` | Siempre último, expone Ingress |

Velero en wave `0` junto a Longhorn (no `1` como Vault) garantiza que `BackupStorageLocation` y `node-agent` estén listos antes de que Vault cree PVCs.

## 3. Bucket — creación automática vía Job wave -1 (idempotente)

Velero no crea el bucket por sí mismo. En este repo el bucket `velero-homelab` se crea **automáticamente dentro del cluster** — no necesitas `aws-cli` local ni pasos extra en CI.

### 3.1 Automático (por defecto) — Job `velero-bucket-init` wave -1

`platform/velero/templates/job-bucket-init.yaml` despliega un `Job` (`batch/v1`) que se ejecuta **antes** que el chart de Velero:

- **Wave:** `argocd.argoproj.io/sync-wave: "-1"` (ArgoCD lo crea antes que la `Application velero` wave `0`).
- **No prune:** `argocd.argoproj.io/sync-options: Prune=false` + `ttlSecondsAfterFinished: 600` — Argo no lo borra tras `Synced`; Kubernetes lo GC pasados 10 min y los logs quedan inspeccionables.
- **Imagen:** `amazon/aws-cli:2.15.0` (oficial, liviana; alternativa `bitnami/aws-cli:latest`).
- **Credenciales:** monta el mismo `Secret velero/cloud-credentials` (key `cloud` con formato `[default]\naws_access_key_id=...\naws_secret_access_key=...`) creado por `bootstrap/init-gitops.sh:ensureVeleroCredentials()` en `/etc/velero/cloud` y lo parsea con `grep`/`cut` para exportar `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` + `AWS_DEFAULT_REGION=us-east-1`. No requiere `envFrom` ni duplicar el Secret.
- **Idempotente:** `aws s3api create-bucket --bucket velero-homelab --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1 2>&1 || true`; si el error es `BucketAlreadyOwnedByYou` / `BucketAlreadyExists` / `already exists` lo considera éxito. Luego verifica con `aws s3api head-bucket` y loguea el resultado. `s3ForcePathStyle` es path-style via `--endpoint-url`, no necesita config extra.
- **Reintentos:** `restartPolicy: OnFailure`, `backoffLimit: 3`. Usa `serviceAccountName: default` en wave `-1` para evitar chicken-egg con el `ServiceAccount velero` del subchart (puedes cambiarlo a `velero` si añades RBAC propio).
- **Dependencia:** requiere que `ensureVeleroCredentials()` haya creado `cloud-credentials` antes del sync (el bootstrap lo hace siempre); si el Secret no existe el Job falla con mensaje explícito.

No necesitas instalar `aws-cli` localmente ni añadir steps en `.github/workflows/deploy.yaml` — el Job reutiliza las credenciales que ya inyecta `deploy.yaml` → `init-gitops.sh`.

Verificación tras el sync:

```bash
kubectl -n velero get job velero-bucket-init
kubectl -n velero logs job/velero-bucket-init
kubectl -n velero get backupstoragelocations.velero.io -o yaml  # debe estar Ready
```

### 3.2 Manual (fallback) — solo si el Job no puede ejecutarse

Si necesitas crear el bucket fuera del cluster (p.ej. bootstrap sin cluster aún):

```bash
# Requiere AWS CLI con credenciales RustFS en env
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_ENDPOINT_URL="https://rustfs.lonk-mirfak.ts.net"

aws s3api create-bucket \
  --bucket velero-homelab \
  --endpoint-url https://rustfs.lonk-mirfak.ts.net \
  --region us-east-1

# Verificar
aws s3 ls --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1
aws s3api get-bucket-location --bucket velero-homelab --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1

# Opcional: lifecycle (ej. 30 días) si RustFS lo soporta
# aws s3api put-bucket-lifecycle-configuration --bucket velero-homelab --endpoint-url ... --lifecycle-configuration file://lifecycle.json
```

> **Notas RustFS:** `us-east-1` es obligatorio aunque RustFS no valide regiones. `s3ForcePathStyle: "true"` y `s3Url` deben coincidir con el endpoint público del ingress Tailscale (`lonk-mirfak.ts.net`). El chart usa `prefix: velero/` para aislar objetos. El Job ya usa estos valores; el fallback manual debe usar los mismos.

## 4. Secrets — local, GitHub y CI

### 4.1 Local (bootstrap manual)

`ensureVeleroCredentials()` resuelve credenciales con este orden:

1. `VELERO_AWS_ACCESS_KEY_ID` / `VELERO_AWS_SECRET_ACCESS_KEY` (preferidas, permiten separar del Terraform state)
2. Fallback `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (mismas que usa `infra-talos-homelab` para el backend S3 `terraform-homelab`)

```bash
# Opción separada (recomendada si quieres rotar independiente)
export VELERO_AWS_ACCESS_KEY_ID="AKIA..."
export VELERO_AWS_SECRET_ACCESS_KEY="..."
./bootstrap/init-gitops.sh prod

# O reusar las de Terraform
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
./bootstrap/init-gitops.sh prod

# Verificar
kubectl -n velero get secret cloud-credentials -o jsonpath='{.data.cloud}' | base64 -d
# Debe mostrar:
# [default]
# aws_access_key_id=...
# aws_secret_access_key=...
```

Si no hay vars, el script **no falla** — loguea `WARNING` y Velero quedará `Pending` (`BackupStorageLocation` inválida) hasta que se cree el Secret. Es idempotente: `--dry-run=client -o yaml | kubectl apply -f -`.

### 4.2 GitHub Actions — `deploy.yaml`

El workflow `.github/workflows/deploy.yaml` sigue el patrón de `infra-talos-homelab/docs/ci-cd.md` (`deploy.yaml` → `terraform init` con `AWS_*`):

- `secured-gitops-tailscale-homelab/.github/workflows/deploy.yaml` ya inyecta `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` para restaurar `kubeconfig` desde el state S3 (`terraform output -raw kubeconfig`).
- Para Velero, **no hace falta** añadir `VELERO_AWS_*` si reusas las mismas credenciales RustFS — el step `Bootstrap` hereda el env del job. Si prefieres separar, añade dos secrets opcionales al repo:

| GitHub Secret | Requerido | Descripción |
|---------------|-----------|-------------|
| `AWS_ACCESS_KEY_ID` | sí (ya existe) | RustFS S3 — usado para Terraform state y fallback Velero |
| `AWS_SECRET_ACCESS_KEY` | sí (ya existe) | RustFS S3 secret |
| `VELERO_AWS_ACCESS_KEY_ID` | no | Si se define, `deploy.yaml` lo exporta como `VELERO_AWS_ACCESS_KEY_ID` antes de `./bootstrap/init-gitops.sh` |
| `VELERO_AWS_SECRET_ACCESS_KEY` | no | Idem |

Actualmente `deploy.yaml` expone `KUBECONFIG` y ejecuta:

```yaml
- name: Bootstrap (delegates to init-gitops.sh — single source of truth)
  env:
    KUBECONFIG: /tmp/kubeconfig.yaml
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    # Opcional si se crean:
    VELERO_AWS_ACCESS_KEY_ID: ${{ secrets.VELERO_AWS_ACCESS_KEY_ID }}
    VELERO_AWS_SECRET_ACCESS_KEY: ${{ secrets.VELERO_AWS_SECRET_ACCESS_KEY }}
  run: ./bootstrap/init-gitops.sh "$ENV" $FORCE
```

> Si no añades `VELERO_AWS_*`, el fallback `AWS_*` cubre el caso sin pasos extra — coherente con ADR-004 opción C (simplicidad > pureza).

### 4.3 Referencia `infra-talos-homelab/.github/workflows/deploy.yaml`

El infra repo documenta en `docs/ci-cd.md` que `deploy` inyecta `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` para `terraform init -reconfigure` contra RustFS (`terraform-homelab` bucket, `skip_*` para S3-compatible). El flujo aquí es idéntico pero el bucket destino es `velero-homelab`.

## 5. Verificación

```bash
# ArgoCD — velero debe estar Synced/Healthy en wave 0 antes que vault (wave 1)
kubectl get applications -n argocd | grep -E 'velero|vault|longhorn'

# Velero — BSL y pods
kubectl -n velero get backupstoragelocations.velero.io -o yaml
kubectl -n velero get volumesnapshotlocations.velero.io -o yaml
kubectl -n velero get pods -l app.kubernetes.io/name=velero
kubectl -n velero get daemonset -l app.kubernetes.io/name=velero  # node-agent
kubectl logs -n velero deploy/velero --tail=50

# Backup manual (prueba de escritura)
velero backup create manual-$(date +%Y%m%d%H%M) --wait --storage-location default
velero backup get
velero backup describe manual-... --details
velero backup logs manual-...

# Listar objetos en RustFS (debe aparecer prefix velero/)
aws s3 ls s3://velero-homelab/velero/backups/ --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1 --recursive | head

# Restore de prueba (namespace aislado)
velero restore create --from-backup manual-... --wait
velero restore get
velero restore describe <name> --details
```

**Schedules instalados por el chart (`values.yaml:schedules`):**

- `daily-full` `0 2 * * *` — all namespaces, `defaultVolumesToFsBackup: true` (Longhorn PVCs via node-agent), TTL 30d
- `vault-hourly` `0 * * * *` — `vault` namespace (`secrets`, `configmaps`, `pvc`, `cronjobs`), TTL 7d

```bash
kubectl -n velero get schedules.velero.io -o yaml
velero schedule get
```

## 6. Troubleshooting

| Síntoma | Causa | Solución |
|---------|-------|----------|
| `secret "cloud-credentials" not found` / `CreateContainerConfigError` | `ensureVeleroCredentials()` no se ejecutó con vars | `VELERO_AWS_ACCESS_KEY_ID=... VELERO_AWS_SECRET_ACCESS_KEY=... ./bootstrap/init-gitops.sh prod` o `AWS_*` fallback; verificar `kubectl -n velero get secret cloud-credentials`. El Job `velero-bucket-init` también falla si falta el Secret — revisar `kubectl -n velero logs job/velero-bucket-init` |
| `NoSuchBucket: The specified bucket does not exist` | Bucket `velero-homelab` no creado (Job no corrió o Secret faltaba) | Automático: verificar `kubectl -n velero get job velero-bucket-init` y `kubectl -n velero logs job/velero-bucket-init` — el Job wave `-1` lo crea idempotente. Fallback manual: `aws s3api create-bucket --bucket velero-homelab --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1` |
| `PermanentRedirect` / `SignatureDoesNotMatch` | `s3ForcePathStyle` o `s3Url` incorrectos | Chart debe tener `s3ForcePathStyle: "true"` y `s3Url: https://rustfs.lonk-mirfak.ts.net` (no virtual-hosted style) |
| `BackupStorageLocation default is not in Ready state` | Credenciales inválidas o RustFS inaccesible vía Tailscale | Validar `aws s3 ls --endpoint-url ...` desde cluster, y que `cloud` key sea exactamente `[default]\naws_access_key_id=...\naws_secret_access_key=...` (sin espacios extra) |
| `defaultVolumesToFsBackup` no respalda PVC | `nodeAgent.enabled: false` | Debe estar `true` en `values.yaml`; verificar DaemonSet `node-agent` en `velero` |
| Velero `ImagePullBackOff` para `velero-plugin-for-aws` | Tag inexistente | Fijar `velero/velero-plugin-for-aws:v1.10.2` (compatible Velero 1.14) |

**Relación con Vault DR:** el backup VM de Proxmox **no es atómico** para Raft (§1 del runbook). Velero complementa pero no reemplaza `vault operator raft snapshot save/restore`. Para recuperación de Vault seguir [`docs/runbook-vault-restore.md`](runbook-vault-restore.md) (regla de oro: restaurar 1 sola VM `vault-2` y re-join de seguidores vacíos, autocuración cada 2 min via `vault-autounseal`).

## 7. Referencias

- Precedente bootstrap fuera de Vault: [ADR-004 opción A](adrs/004-tailscale-oauth-seed-strategy.md) — `secretKeyRef` temporal vs. placeholder.
- Infra CI/CD RustFS S3: `infra-talos-homelab/docs/ci-cd.md` (workflow `deploy.yaml` — `terraform init` con `AWS_*`, `skip_*` para S3 compatible).
- Velero docs: https://velero.io/docs/ — AWS plugin + `BackupStorageLocation` + `nodeAgent` (restic successor).
- Runbook Vault: [`docs/runbook-vault-restore.md`](runbook-vault-restore.md) — recuperación Raft tras restore VM Proxmox (golden rule `vault-2` only + `vault-autounseal` `*/2`).
- Chart wrapper: `platform/velero/Chart.yaml` (vmware-tanzu/velero `9.0.2`), `platform/velero/values.yaml`, `platform/velero/README.md`.

---

*Documento para bootstrap CI/CD sin chicken-egg. Velero queda en wave 0 y crea el Secret fuera de Vault — el mismo patrón que ADR-004 evalúa como opción A.*
