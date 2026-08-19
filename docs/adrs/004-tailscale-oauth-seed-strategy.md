# ADR-004: Tailscale OAuth Seed Strategy — Deliberate Placeholder + Manual UI Entry

**Status:** Accepted · **Date:** 2026-08-18

## Context

The `vault-config-tailscale` Job (introduced in ADR-002) seeds
`secret/tailscale/auth` in Vault during the ArgoCD sync. The initial
implementation wrote `ChangeMeSecret` as the value for `TS_CLIENT_ID` and
`TS_CLIENT_SECRET`.

This looks like a leftover placeholder, but for a single-operator homelab it is
the intended design: the operator creates a Tailscale OAuth client, then enters
the real credentials through the Vault UI (clickops). Until the real credentials
are stored, the Tailscale Operator cannot authenticate, so an unconfigured
cluster fails visibly instead of silently.

Alternatives were evaluated to remove the placeholder from the repository.

## Options Considered

### Option A — One-time Kubernetes bootstrap Secret (`secretKeyRef`)

Create a temporary Kubernetes Secret `tailscale-oauth` (from local env vars),
have the Job read it via `secretKeyRef`, seed Vault, then delete the Secret.

**Pros:** No placeholder in Git; local env vars flow into the cluster.

**Cons:** Adds a manual `kubectl create secret` + `kubectl delete secret`
lifecycle around every bootstrap; ArgoCD re-syncs can re-run the Job after the
temporary Secret is gone (`optional: true` is required just to survive that);
the operator still has to go to the Tailscale admin console anyway to generate
the OAuth client. Complexity without eliminating the manual step.

### Option B — `vault kv put` from the local machine

Provide a documented CLI command that writes the real credentials using local
env vars.

**Pros:** One-liner, no placeholder in Git.

**Cons:** Requires installing and authenticating the Vault CLI locally (`vault`
binary + root token) — extra tooling for a single-operator homelab. The Vault
UI is already reachable via `kubectl port-forward`.

### Option C — Deliberate placeholder + Vault UI (SELECTED)

Keep `ChangeMeSecret` as the seeded placeholder and document the manual Vault
UI entry as the supported path.

**Pros:** Zero extra tooling; the existing `kubectl port-forward` + Vault UI
workflow is already documented and used; the placeholder is a visible reminder
that configuration is pending (Tailscale fails to authenticate until real
values are set); simplest possible bootstrap.

**Cons:** A placeholder string exists in Git; a fresh fork that skips the UI
step gets a silently failing Tailscale Operator.

## Decision

**Option C: keep the deliberate `ChangeMeSecret` placeholder and make the Vault
UI the supported entry path.** The bootstrap stays lean — no local Vault CLI,
no temporary Secret lifecycle. The placeholder is intentional and documented in
`docs/secrets-structure.md`, which links back to this ADR.

## Rationale

1. **Single-operator homelab.** There is no team to coordinate, no
   secrets-in-Git concern beyond the operator's own credentials, and no
   compliance requirement. The cost of extra tooling outweighs the benefit of
   removing one visible placeholder.
2. **The manual step cannot be eliminated anyway.** Generating a Tailscale
   OAuth client requires the operator to visit the Tailscale admin console
   regardless of the chosen seed mechanism.
3. **Fail-visible.** A placeholder value means the Tailscale Operator cannot
   authenticate; the symptom is obvious during validation rather than silent
   misuse of a stale real credential.
4. **Consistency with ADR-002.** The Job remains declarative and idempotent;
   only the source of the credential values is deliberately manual.

## Consequences

- **Positive:** No local `vault` CLI required; bootstrap stays minimal; the UI
  workflow is already documented with screenshots in `docs/secrets-structure.md`.
- **Positive:** ADR-002's sync-wave pattern is untouched.
- **Negative:** The repository contains a literal `ChangeMeSecret` placeholder —
  reviewers must understand it is intentional (this ADR + `docs/secrets-structure.md`).
- **Negative:** A misconfigured fork fails at Tailscale authentication time
  rather than at seed time.

## Files

| Action | File |
|--------|------|
| Created | `docs/adrs/004-tailscale-oauth-seed-strategy.md` |
| Updated | `docs/secrets-structure.md` — manual UI entry path, link to this ADR |
| Unchanged | `platform/vault/templates/eso/vault-config-tailscale.yaml` — placeholder kept as designed |
