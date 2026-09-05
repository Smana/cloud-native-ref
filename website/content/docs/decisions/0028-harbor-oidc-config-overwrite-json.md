---
title: Harbor's OIDC config is set declaratively via CONFIG_OVERWRITE_JSON, not a post-install script
linkTitle: 0028 · Harbor OIDC CONFIG_OVERWRITE_JSON
weight: 280
description: Harbor was the only OIDC consumer needing a bespoke imperative script, because auth_mode and the OIDC settings live in its database rather than its chart. Harbor's own CONFIG_OVERWRITE_JSON env var writes that database declaratively at every core startup — at the cost of locking Harbor's entire system-configuration surface read-only in the UI.
lastVerified: 2026-08-29
---

**Status**: Accepted
**Date**: 2026-08-29
**Deciders**: Platform Team

---

## Context

Five consumers log into this platform through the same ZITADEL broker
(see [Authentication]({{< relref "/docs/platform/security/authentication.md" >}})).
Four of them are uniform: `zitadel-oidc-clients.sh` registers an OIDC client and
writes its `{client_id, client_secret, endpoint}` to the cloud secret store, an
`ExternalSecret` syncs it into the cluster, and the app consumes it as env vars
or Helm values. Nothing in git is imperative.

Harbor did not fit that shape. `auth_mode`, the OIDC endpoint, the client and
the scopes are not chart configuration — Harbor writes them into its own
Postgres database at runtime, through its `/api/v2.0/configurations` API, and
nothing in `tooling/base/harbor/` could express them. `harbor-oidc.sh`
existed to close that gap: read the client from the store, authenticate to
Harbor as `admin`, and `PUT` the fields by hand. It worked, and it was
idempotent — but it was a second script, with its own test file
(`test-harbor-oidc-convergence.sh`), its own admin-password handling, and its
own drift-reporting logic that the other four consumers never needed. The gap
it existed to paper over had already bitten once: `gcp-0` came up on
2026-08-28 with `auth_mode: db_auth` and no SSO button because the equivalent
had been set by hand in the `aws-0` UI, which is exactly the failure mode a
script-in-git was supposed to prevent, and very nearly didn't.

The question this ADR answers: does Harbor support setting `auth_mode` and the
OIDC fields declaratively, so the bespoke script can be dropped entirely?

**It does.** Verified directly against three independent sources, not
inferred from the docs alone:

- **Docs** — `goharbor.io/docs/2.14.0/install-config/configure-system-settings-cli`
  documents `CONFIG_OVERWRITE_JSON`, an env var on the `harbor-core` container,
  present since Harbor 2.3.0. Its configuration-items table lists every field
  the script was setting: `auth_mode`, `oidc_name`, `oidc_endpoint`,
  `oidc_client_id`, `oidc_client_secret`, `oidc_scope`, `oidc_groups_claim`,
  `oidc_user_claim`, `oidc_auto_onboard`, `oidc_verify_cert` — all ten,
  verbatim.
- **Chart source** — `goharbor/harbor-helm` at `v1.18.3` (the version pinned in
  `tooling/base/harbor/helmrelease-harbor.yaml`, `appVersion: 2.14.3`) carries
  `core.configureUserSettings` in `values.yaml`, a raw JSON string.
  `templates/core/core-secret.yaml` base64-encodes it into the chart's own
  `<release>-core` Secret as `CONFIG_OVERWRITE_JSON`; `templates/core/core-dpl.yaml`
  loads that Secret via `envFrom` into the core container, and carries a
  `checksum/secret` pod annotation that forces a rolling restart whenever the
  Secret's content changes — which is what makes a Helm-value change actually
  take effect, since Harbor only reads the env var at process start.
- **Harbor core source** — `goharbor/harbor` at `v2.14.3`. `src/core/main.go`
  calls `configCtl.Ctl.OverwriteConfig(ctx)` on every startup.
  `src/controller/config/controller.go`'s `OverwriteConfig` unmarshals the env
  var, writes the fields to the database through the same `UpdateUserConfigs`
  path the REST API uses, and then sets a package-level `readOnlyForAll = true`.

That last fact is the trade-off this ADR has to accept, not a footnote: `readOnlyForAll`
is checked inside `UpdateUserConfigs` for *any* config write, not just the
overwritten keys. Once `CONFIG_OVERWRITE_JSON` is set, Harbor's entire
system-configuration surface — project quotas, robot-token expiry, proxy-cache
settings, self-registration, everything under `/api/v2.0/configurations` — is
locked read-only in both the UI and the API, until someone edits the Helm value
and restarts `harbor-core`. Not scoped to auth. Not a soft warning; `UpdateUserConfigs`
returns `Forbidden` for every field.

---

## Decision Drivers

- **Uniformity.** A technology-shaped exception for one of five identical
  consumers is a maintenance liability disguised as a Harbor quirk — the
  2026-08-28 incident above is what a silent exception costs.
- **GitOps as the source of truth.** The platform constitution already commits
  to Flux as "the single source of truth for cluster state"; an admin editing
  Harbor's auth settings by hand in the UI is exactly the failure mode that
  principle exists to close off.
- **No hardcoded credentials, and no credential wider than it needs to be.** The
  client secret must not be committed to git or land in a more broadly-readable
  place (a `HelmRelease`'s `.spec.values`) than it does today (a `Secret`).
- **Maintenance burden.** A bespoke script means a bespoke test file, a bespoke
  admin-password code path, and a bespoke convergence check — three things the
  other four consumers do not carry.

---

## Considered Options

### Option 1: Keep `harbor-oidc.sh` (status quo)

**Pros**:
- Already written, already idempotent, already covers the full field set.
- No new Helm/ExternalSecret plumbing to get right.
- System settings stay editable via the Harbor UI/API for anything, always.

**Cons**:
- The one consumer of five that needs a second script, its own test file, and
  its own admin-password handling — the asymmetry this ADR exists to remove.
- Nothing enforces it gets run. The 2026-08-28 incident happened because the
  equivalent state was set by hand once and never captured in git; a script
  that has to be remembered and re-run is one missed step away from repeating
  that, on every new cluster or migration.
- Reimplements, by hand, a per-field convergence check that Flux's own
  reconciliation loop gives every other consumer for free.

### Option 2: `CONFIG_OVERWRITE_JSON` via `HelmRelease.spec.valuesFrom` + `ExternalSecret` (chosen)

Harbor's `core.configureUserSettings` Helm value is composed from a `Secret`
using `valuesFrom` with `literal: true` (Flux's documented mechanism for
injecting an arbitrary JSON blob into a Helm value without it passing through
`--set` parsing), and that `Secret` is populated by an `ExternalSecret` reading
the same `harbor-oidc` store key the old script read.

**Pros**:
- Harbor now follows the exact same shape as Grafana, Headlamp and the Flux
  UI: register client → `ExternalSecret` → declarative consumption.
- Self-heals. A rotated client secret or a changed endpoint (e.g. during the
  identity-provider migration procedure) converges within the `ExternalSecret`
  refresh interval and the next `HelmRelease` reconcile, with no script to
  remember to re-run.
- The client secret never lands in the `HelmRelease` CR's `.spec.values` —
  `valuesFrom` composes it from a `Secret` at render time.
- Deletes `harbor-oidc.sh` and its dedicated test file outright.

**Cons**:
- `readOnlyForAll` locks Harbor's entire system-configuration surface, not
  just auth — see Context. This is the cost of the whole option, not an edge
  case of it.
- Convergence after a rotation is eventually consistent (bounded by a 20-minute
  `ExternalSecret` refresh and a 10-minute `HelmRelease` interval) rather than
  applied on demand by re-running a script.

### Option 3: Same JSON blob, but as a plain (non-`valuesFrom`) Helm value

Set `core.configureUserSettings` directly in the `HelmRelease`'s `values:`
block, sourced by Flux `postBuild.substituteFrom` with a `Secret` source rather
than `valuesFrom`. (At the time this was written the repository had one such
case, `cert_manager_approle_id`; it has since gone — see
[ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}})
— so nothing uses a Secret-sourced substitution today. The reasoning below is
unaffected: it is about what the mechanism does, not about how many callers
it has.)

**Pros**:
- One fewer manifest — no separate `ExternalSecret` needed if `substituteFrom`
  already had access to the right `Secret`.

**Cons**:
- `postBuild.substituteFrom` bakes the substituted value into the `HelmRelease`
  object's `.spec.values` in the clear. That object is a regular Flux CR,
  typically readable by a broader audience than a core `v1.Secret` — this
  would put the OIDC client secret in a **more** exposed place than it is
  today, which the platform constitution's "no hardcoded credentials" driver
  rules out directly. Flux's own `valuesFrom` mechanism exists precisely to
  avoid this.

---

## Decision Outcome

**Chosen option**: "Option 2 — `CONFIG_OVERWRITE_JSON` via `valuesFrom` + `ExternalSecret`".

**Rationale**: It is the only option that both closes the uniformity gap and
keeps the client secret exactly as exposed as it is today (a `Secret`, nothing
wider). The `readOnlyForAll` cost is real and is accepted deliberately: this
platform already treats Flux/git as the single source of truth for cluster
state, so an admin needing to hand-edit Harbor's system settings outside that
model was already a process violation, not a feature being taken away. The
trade-off is also reversible — clearing `core.configureUserSettings` and
restarting `harbor-core` hands control back to the UI — so adopting it now
does not foreclose reverting later if it proves painful in practice.

---

## Consequences

### Positive

- Harbor behaves identically to Grafana, Headlamp and the Flux UI: register
  client → `ExternalSecret` → declarative consumption. The asymmetry that
  prompted this ADR is gone.
- `harbor-oidc.sh` and `test-harbor-oidc-convergence.sh` are
  deleted — one less script class to keep passing the repo's argv-leak guard
  and shellcheck.
- No script reads Harbor's admin password out of the cluster anymore.
- [Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}) drops a
  manual step; a fresh cluster's Harbor now converges on its own once the
  OIDC client is registered.

### Negative

- Harbor's entire system-configuration surface — not just auth — is
  permanently read-only in the UI and API from the first successful
  `CONFIG_OVERWRITE_JSON` boot onward. Any future change to quotas,
  robot-token expiry, proxy-cache settings, etc. requires a Helm-value edit
  and a `harbor-core` restart, not a UI click. No mitigation is applied beyond
  documenting it here and in
  [Authentication]({{< relref "/docs/platform/security/authentication.md" >}}) —
  it is accepted as the correct trade-off for a GitOps-first platform.
- Convergence after a client-secret rotation or a cloud migration is
  eventually consistent rather than on-demand. Mitigation:
  `flux reconcile helmrelease harbor -n tooling --with-source` forces it
  immediately; documented in
  [Migrate the identity provider]({{< relref "/docs/guides/migrate-the-identity-provider.md" >}}).

### Neutral

- Harbor's auth configuration still physically lives in its own Postgres
  database at runtime — that is Harbor's own architecture and this ADR does
  not change it. What changes is *how* that database row gets written:
  declaratively, by Harbor itself at every core startup, instead of
  imperatively by a script calling the REST API.

---

## Implementation Notes

- `tooling/base/harbor/externalsecret-oidc.yaml` — extracts the `harbor-oidc`
  store key and templates one `config-overwrite-json` key (ESO
  `engineVersion: v2`) reproducing the exact ten-field payload
  `harbor-oidc.sh` used to `PUT`. `client_id`/`client_secret`/`endpoint` are
  interpolated through Sprig's `toJson` rather than manual quoting, so a value
  containing a `"` or `\` cannot break the generated JSON.
- `tooling/base/harbor/helmrelease-harbor.yaml` — adds
  `spec.valuesFrom: [{kind: Secret, name: harbor-oidc-config, valuesKey:
  config-overwrite-json, targetPath: core.configureUserSettings, literal:
  true}]`. `literal: true` is required: without it the JSON blob is
  reinterpreted through Helm's `--set` syntax (commas, colons and quotes) instead
  of taken as-is.
- No `dependsOn` was added between Harbor's `Kustomization` and the one
  producing its `ExternalSecret`'s source data. `HelmRelease` reconciliation is
  periodic (`interval: 10m0s` here) and re-evaluates `valuesFrom` content on
  each pass, so a temporarily-missing or stale secret self-heals on the next
  cycle the same way the old two-script ordering did — it does not need to be
  correct on the very first reconcile.

---

## References

- [goharbor.io — Configure System Settings via the CLI (2.14.0)](https://goharbor.io/docs/2.14.0/install-config/configure-system-settings-cli/) — `CONFIG_OVERWRITE_JSON` and the full configuration-items table
- [goharbor/harbor-helm `v1.18.3`](https://github.com/goharbor/harbor-helm/tree/v1.18.3) — `values.yaml` (`core.configureUserSettings`), `templates/core/core-secret.yaml`, `templates/core/core-dpl.yaml`
- [goharbor/harbor `v2.14.3`](https://github.com/goharbor/harbor/tree/v2.14.3) — `src/core/main.go`, `src/controller/config/controller.go` (`OverwriteConfig`, `readOnlyForAll`)
- Flux `HelmRelease.spec.valuesFrom[].literal` — the documented mechanism for injecting a JSON blob without `--set` reinterpretation
- [ADR-0020](0020-harbor-gcs-workload-identity.md) — the other Harbor-specific decision on this platform, same "no credential wider than it needs to be" driver applied to object storage instead of auth
- [Authentication]({{< relref "/docs/platform/security/authentication.md" >}}) · [Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}})
