# ADR-002: Vault Configuration Decentralization

**Status:** Accepted · **Date:** 2026-05-30

## Context

Vault initialization was handled by a single monolithic script (`platform/vault/scripts/init-vault.sh`) that mixed three distinct responsibilities:

1. **Bootstrap** — wait for pods, initialize, save unseal keys, unseal all pods
2. **Configuration** — enable engines, write policies, create auth roles, seed secrets
3. **Orchestration** — trigger ArgoCD syncs for dependent applications

Every time a new service (e.g., tailscale, monitoring, seaweedfs) was added, the script had to be edited to add:
- A new Vault policy
- An update to the shared `eso-role` to include the new policy
- Commands to seed the service's secrets

This created tight coupling between the Vault chart and every service that consumed secrets from it. Changes were imperative (bash), not declarative, and invisible in PR reviews beyond "lines changed in a script."

Additionally, all services shared a single `ClusterSecretStore` (`vault-backend`) that authenticated via a single Vault role (`eso-role`). This violated least-privilege: every service had access to every policy attached to that role, even policies for unrelated services.

## Options Considered

### Option A — Centralized YAML config file

Keep the monolithic init script but make it read a `vault-config.yaml` that declares policies, roles, and seeds declaratively. Adding a new service means editing the YAML.

**Pros:** Declarative, PR-friendly.  
**Cons:** Still a single point of change. The config file lives in the vault chart, coupling it to every service.

### Option B — Vault Secrets Operator (VSO)

Install the HashiCorp Vault Secrets Operator and use its CRDs (`VaultPolicy`, `VaultAuth`, etc.) to declare Vault configuration as Kubernetes resources.

**Pros:** Fully Kubernetes-native, ArgoCD manages everything.  
**Cons:** VSO does **not** have `VaultPolicy` or `VaultRole` CRDs — it only handles `VaultAuth`, `VaultStaticSecret`, `VaultDynamicSecret`. Policies and roles must still be managed externally. Additionally, adding another operator just for this is disproportionate.

### Option C — Terraform / OpenTofu

Manage Vault configuration (policies, roles, auth methods) via Terraform's `vault` provider.

**Pros:** Industry standard, declarative, stateful.  
**Cons:** Another tool in the stack, external state management, doesn't integrate with ArgoCD's GitOps model.

### Option D — Per-service Jobs + ClusterSecretStores (SELECTED)

**Bootstrap** stays as a lean script. **Configuration** moves to per-service ArgoCD sync Jobs that each own their own Vault policy, role, and secrets. The shared `ClusterSecretStore` is replaced by per-service `ClusterSecretStore` resources colocated in the vault chart, each referencing a dedicated Vault role.

## Decision

**Option D: Decentralized per-service configuration via sync Jobs and ClusterSecretStores.**

### Architecture

```
platform/vault/scripts/
├── bootstrap-vault.sh               # Init + unseal only

platform/vault/templates/eso/
├── vault-config-rbac.yaml            # SA + Role for config Jobs (sync-wave 0)
├── vault-config-tailscale.yaml       # sync-wave 1 Job: policy + role + seeds
├── vault-config-monitoring.yaml      # sync-wave 1 Job: policy + role + seeds
├── cluster-store-tailscale.yaml      # sync-wave 2 ClusterSecretStore
├── cluster-store-monitoring.yaml     # sync-wave 2 ClusterSecretStore

platform/tailscale/templates/
├── secret-tailscale.yaml             # ExternalSecret → ClusterSecretStore vault-tailscale

platform/monitoring/templates/
├── secret-monitor.yaml               # ExternalSecret → ClusterSecretStore vault-monitoring
```

### Sync-wave Ordering

The vault Application uses ArgoCD sync-waves to ensure Vault roles exist before the ClusterSecretStore is created:

```
Wave 0: RBAC (SA vault-config, Role, RoleBinding) + Vault StatefulSet + all Helm resources
Wave 1: vault-config-monitoring Job     ← waits for Vault unsealed, creates role + seed
        vault-config-tailscale Job      ← waits for Vault unsealed, creates role + seed
Wave 2: ClusterSecretStore vault-monitoring   ← ESO picks it up, role already exists
        ClusterSecretStore vault-tailscale    ← ESO picks it up, role already exists
```

Within a sync-wave, resources are applied in parallel. Wave 2 does not wait for wave 1 Jobs to complete before creating the ClusterSecretStore. In practice, the Jobs complete in seconds (simple `vault write` commands through `kubectl exec`), and ESO's controller enqueues the ClusterSecretStore with a brief processing delay — enough for roles to be ready by the time ESO attempts authentication.

If ESO does encounter a transient "role not found" error, it retries with backoff (starting at 15s). Once the Job finishes, the next retry succeeds.

### Config Job Pattern

Each Job is a regular Kubernetes `Job` resource (not an ArgoCD hook) in the `vault` namespace with:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-config-monitoring
  namespace: vault
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  ttlSecondsAfterFinished: 3600
```

Key properties:
- **Not a hook.** The Job is a managed resource. ArgoCD tracks its health (failed Jobs degrade the app).
- **`ttlSecondsAfterFinished: 3600`.** Completed Jobs are cleaned up automatically after one hour.
- **Wait loop.** The Job starts by polling `vault status` through `kubectl exec` until Vault is unsealed and responsive. This handles the race between the Job container starting and Vault finishing initialization.
- **Idempotent.** All operations (`vault policy write`, `vault write auth/kubernetes/role/...`, `vault kv put`) are safe to re-run. Secrets are skipped if they already exist.

The Job:
1. Polls Vault until unsealed and responsive
2. Reads the Vault root token from the `*-unseal-keys` secret
3. Writes its policy via `vault policy write` (heredoc to `kubectl exec`)
4. Creates its Vault role via `vault write auth/kubernetes/role/eso-<service>`
5. Seeds its secrets (static or generated) via `vault kv put`

### ClusterSecretStore Pattern

Each service's Vault connection is defined as a `ClusterSecretStore` in the vault chart, referencing a dedicated Vault role:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-monitoring
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  provider:
    vault:
      server: {{ .Values.vaultAddress | default "https://vault.vault.svc:8200" }}
      caProvider:
        type: Secret
        name: vault-tls
        key: ca.crt
        namespace: vault
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-monitoring"
```

Key design decisions:
- **`ClusterSecretStore` (not namespaced `SecretStore`).** The `caProvider.namespace: vault` references the `vault-tls` TLS secret in the `vault` namespace. A namespaced `SecretStore` cannot read secrets across namespaces — ESO's validation rejects `caProvider.namespace` that differs from the store's namespace. A `ClusterSecretStore` is cluster-scoped and can reference the TLS secret in any namespace.
- **No `serviceAccountRef`.** ESO uses its own pod service account in the `external-secrets` namespace. The Vault role `bound_service_account_names` includes the default `external-secrets` SA.
- **Ownership in the vault chart.** The ClusterSecretStore is infrastructure, not application configuration. It lives alongside the vault chart and the config Jobs that create its matching Vault role.

The service chart only defines an `ExternalSecret`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin-credentials
  namespace: monitoring
spec:
  secretStoreRef:
    name: vault-monitoring
    kind: ClusterSecretStore
```

This keeps the service chart clean: it declares what secrets it needs, not how to connect to Vault.

## Rationale

1. **Least-privilege.** Each service has its own Vault role with only its own policy. No service can accidentally read another service's secrets.

2. **Ownership boundary.** Adding a new service means adding:
   - A vault-config Job in the vault chart (creates the policy + role in Vault)
   - A ClusterSecretStore in the vault chart (defines the Vault connection)
   - An ExternalSecret in the service's own chart (consumes the secret)

   Each change is isolated, visible in PRs, and doesn't modify shared infrastructure.

3. **GitOps-native.** Sync-wave ordering guarantees roles exist before the ClusterSecretStore is available to ESO. No manual orchestration, no imperative scripts.

4. **No new operators.** The Jobs use `kubectl exec vault-0 -- vault ...` — the same pattern as the original script. No `vault` binary needed in the Job image.

5. **Idempotent by design.** All operations can be re-run safely. The wait loop handles Vault readiness without failing the bootstrap.

## Consequences

- **Positive:** Clean separation of concerns, least-privilege roles, PR-visible changes, no more shared `ClusterSecretStore`, each service independently deployable.
- **Positive:** Sync-wave ordering removes the timing race between Vault role creation and ESO store processing.
- **Negative:** More Kubernetes resources (one Job + one ClusterSecretStore per service). The `vaultAddress` Helm value must be configured per-service chart (default: vault.vault.svc:8200, override for dev: vault-dev.vault.svc:8200).
- **NetworkPolicy:** Currently open to all namespaces (`namespaceSelector: {}`). A future change will restrict access to only `vault` and `external-secrets` namespaces.

## Files

| Action | File |
|--------|------|
| Created | `platform/vault/scripts/bootstrap-vault.sh` |
| Created | `platform/vault/templates/eso/vault-config-rbac.yaml` |
| Created | `platform/vault/templates/eso/vault-config-tailscale.yaml` |
| Created | `platform/vault/templates/eso/vault-config-monitoring.yaml` |
| Created | `platform/vault/templates/eso/cluster-store-tailscale.yaml` |
| Created | `platform/vault/templates/eso/cluster-store-monitoring.yaml` |
| Updated | `platform/tailscale/templates/secret-tailscale.yaml` — store ref to ClusterSecretStore |
| Updated | `platform/monitoring/templates/secret-monitor.yaml` — store ref to ClusterSecretStore |
| Updated | `bootstrap/01-init-gitops.sh` — script reference, removed TS prompts |
| Deleted | `platform/vault/scripts/init-vault.sh` |
| Deleted | `platform/vault/templates/eso/vault-eso-backend.yaml` |
