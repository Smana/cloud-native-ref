---
title: Human access to OpenBao is ZITADEL OIDC, authorised by project roles, with userpass kept as break-glass
linkTitle: 0034 · OpenBao OIDC
weight: 340
description: Operators log in to OpenBao through ZITADEL rather than a shared userpass credential, and their policies come from ZITADEL project roles flattened into the platform's existing `groups` claim. Google Workspace group membership is rejected as the authorisation source because nothing carries it into ZITADEL. The userpass admin survives on purpose — Stage 2 makes ZITADEL's own masterkey an OpenBao secret, so an OIDC-only login would have no way back in.
lastVerified: 2026-09-05
---

**Status**: Accepted
**Date**: 2026-09-05
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0024](0024-identity-provider-per-cloud.md) — the ZITADEL-per-cloud
topology this consumes; [ADR-0028](0028-harbor-oidc-config-overwrite-json.md) — the
declarative-client-registration pattern followed here;
[ADR-0033](0033-openbao-store-of-record-lineage.md) — the Stage 2 repoint that makes
the break-glass credential load-bearing

---

## Context

Every human-facing service on this platform authenticates through ZITADEL:
Grafana, Headlamp, the Flux UI and Harbor all take an OIDC client registered by
`scripts/zitadel-oidc-clients.sh`, and all four read the same flat `groups`
claim. OpenBao is the exception. Its only human login is
`bao login -method=userpass username=admin`, backed by a generated password
published to `openbao/cloud-native-ref/users/admin` in AWS Secrets Manager and
carrying both the `admin` and `pki-admin` policies.

That is one shared credential, with the widest reach on the platform, on the
service that holds everything else. It has no per-person attribution, no
revocation short of rotating the password, and nothing ties it to somebody
still working here.

The awkward part is what ZITADEL actually models. **ZITADEL has no groups.** It
has project roles, and it emits them as a nested object keyed by role and then
by organisation. Nothing in ZITADEL produces the flat array of strings that OIDC
consumers expect, so the platform already builds one: the `groupsFromRoles`
Action (`scripts/zitadel-actions/groups-from-roles.js`) flattens
`urn:zitadel:iam:org:project:roles` into `groups` and `roles`. Four consumers
depend on it today.

Google Workspace sits upstream of ZITADEL as the identity provider, which makes
"authorise by Google group" the intuitive ask. It does not follow. The IdP
registration in `scripts/zitadel-idp.sh` requests
`scopes: ["openid","profile","email"]`, and Google's OIDC does not emit group
memberships under any of them — reading them requires the Admin SDK Directory
API and a credential to call it with. **No Google group membership reaches
ZITADEL today, and none reaches a token.**

---

## Decision Drivers

- **One identity per person, not one password per platform.** The value of an
  IdP is that access follows the human; a shared admin password defeats it.
- **Don't invent a second grouping mechanism.** Four consumers already resolve
  authorisation from the `groups` claim. A fifth that works differently is a
  second thing to reason about during an incident.
- **A cold start must not deadlock.** Stage 2 of
  [ADR-0033](0033-openbao-store-of-record-lineage.md) repoints the platform's
  ExternalSecrets at OpenBao — including ZITADEL's own masterkey. Human access
  to OpenBao must not require ZITADEL to be healthy.
- **Least privilege on the PKI.** `pki-admin` can issue certificates for the
  whole private domain. It should be grantable to a role, not welded to the one
  login everybody shares.

---

## Considered Options

### Option 1: ZITADEL project roles, surfaced through the existing `groups` claim — **chosen**

Register an `openbao` OIDC client the same way Harbor's is registered, enable
OpenBao's `oidc` auth method against ZITADEL, and bind external groups to
policies on the value of the `groups` claim the `groupsFromRoles` Action already
emits.

**Pros**:
- Reuses a mechanism that is deployed, documented and exercised by four
  consumers. No new claim, no new Action, no new sync.
- Authorisation is granted the way every other role on the platform is granted —
  `zitadel-oidc-clients.sh --grant-admin <email>` — so it is reproducible rather
  than clicked into a console.
- Roles are already per-cluster-agnostic: the same ZITADEL project serves both
  clouds, so one grant covers an operator's access to both.

**Cons**:
- Group membership lives in ZITADEL, not in Google Workspace, so offboarding
  someone in Google does not by itself remove their OpenBao access. Their ZITADEL
  login stops working — the IdP is Google — but the role grant lingers as an
  artefact. Mitigated by the fact that losing the Google account blocks the
  login itself; the stale grant is untidy rather than exploitable.
- `ZITADEL_PROJECT_ROLES` is currently `admin backend frontend data`, a
  vocabulary shaped for application access rather than for secrets
  administration. Using `admin` for OpenBao's `admin` **and** `pki-admin`
  policies is coarser than ideal.

### Option 2: Real Google Workspace groups

Add the Admin SDK Directory API, a service account with domain-wide delegation,
and something to read group memberships and project them into ZITADEL or
directly into the token.

**Pros**:
- Authorisation would follow the company's actual source of truth for who is on
  which team, and offboarding in Google would be complete.

**Cons**:
- ZITADEL will not do this natively. It means a new credential with
  domain-wide delegation over Workspace — a very high-value secret — plus a sync
  job, its failure modes, and its staleness window.
- It would be the only authorisation path on the platform that does not read the
  `groups` claim, so OpenBao would diverge from Grafana, Headlamp, the Flux UI
  and Harbor.
- The cost lands on a reference platform with one operator. The mechanism is
  right for an organisation with real team churn; here it buys correctness
  nobody is currently getting wrong.

**Rejected** — but this is the option to revisit first if the platform ever
grows past a handful of operators. Nothing in Option 1 blocks it: it replaces
where the `groups` claim is *populated from*, not how OpenBao consumes it.

### Option 3: Keep userpass only

**Pros**: nothing to build.

**Cons**: leaves the platform's most privileged credential shared, unattributed
and rotation-only. Rejected.

### Option 4: OIDC with per-user policy bindings instead of groups

Bind policies to individual `sub` claims.

**Cons**: reintroduces per-person configuration in Terraform, which is the thing
an IdP exists to remove, and every new operator becomes a pull request. Rejected.

---

## Decision

**Human access to OpenBao is ZITADEL OIDC. Authorisation comes from ZITADEL
project roles, read from the flat `groups` claim the `groupsFromRoles` Action
emits. The `userpass` admin login stays, as break-glass.**

Keeping userpass is not hedging, and it is the part most likely to be
"cleaned up" later by someone who reads the rest of this record and misses this
paragraph. Stage 2 of [ADR-0033](0033-openbao-store-of-record-lineage.md) makes
ZITADEL's masterkey an OpenBao secret. The boot path is fine either way —
ExternalSecrets authenticates with a projected ServiceAccount token over
`jwt/<cluster>`, so no human is in it. The *recovery* path is the problem: if
ZITADEL is broken, and the secret needed to fix ZITADEL is in OpenBao, an
operator with only an OIDC login cannot reach it. The two systems would be
mutually dependent with no way in.

So the userpass credential remains, with its password in AWS Secrets Manager,
and it is documented as break-glass rather than as the normal route. Its use
should be rare enough to be worth asking about.

---

## Consequences

### Positive

- Operators authenticate as themselves. OpenBao's audit log names a person
  rather than `admin`.
- Access is granted and revoked in one place, the way the platform's other four
  OIDC consumers already work.
- The `pki-admin` policy becomes separately grantable rather than permanently
  attached to the shared login.

### Negative

- One more OIDC client to keep in step with redirect URIs, and OpenBao's
  callback URL is unusually strict — it must match the method mount path
  exactly, and the CLI and UI use different ones.
- The break-glass credential still exists, so the shared-password risk is
  reduced rather than eliminated.
- `projectRoleAssertion` must be enabled on the ZITADEL project. It defaults to
  **false**, and when it is false the roles claim is empty while every request
  still reports success — the failure is silent on both sides. This has already
  cost this platform a debugging session once.

### Neutral

- Google Workspace remains the upstream identity provider. What changes is only
  where *authorisation* is read from, and the answer is the same as for every
  other consumer.

---

## Related

- [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}) — the auth
  methods as deployed
- [ADR-0024](0024-identity-provider-per-cloud.md) — one ZITADEL per cloud
- [ADR-0033](0033-openbao-store-of-record-lineage.md) — Stage 2, and why
  break-glass survives
