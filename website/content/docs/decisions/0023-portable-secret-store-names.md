---
title: Secret store keys use a name grammar both clouds accept
linkTitle: 0023 · Portable secret names
weight: 230
description: Shared-base ExternalSecrets key on flat dash-separated names rather than AWS-style slash paths, because a GCP Secret Manager secret ID matches [A-Za-z0-9_-]+ and a slash path is not a well-formed resource name there — so an AWS-shaped key made every shared base structurally undeployable on gcp-0.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-27
**Deciders**: Platform Team

---

## Context

`clustersecretstore` is the single `ClusterSecretStore` every ExternalSecret in
the repository names. It is **AWS Secrets Manager** in `security/base`, and
`security/gcp-0/openbao` overrides it with **GCP Secret Manager**.

The two stores do not agree on what a secret may be called. AWS Secrets Manager
accepts `/` and treats a name like `harbor/admin/password` as an ordinary
string. GCP Secret Manager secret IDs match `[A-Za-z0-9_-]+`; a slash is not a
legal character, and because the ID is interpolated into the REST path, a slash
name does not even reach the API as a resource:

```console
$ gcloud secrets describe grafana-envvars-does-not-exist
ERROR: NOT_FOUND: Secret [projects/323586397743/secrets/grafana-envvars-does-not-exist] not found

$ gcloud secrets describe observability/victoria-metrics-k8s-stack/grafana-envvars
ERROR: HTTPError 404: <!DOCTYPE html> …
```

The first is a well-formed name that happens not to exist. The second is an
HTML 404 from the URL router — the name was never a resource at all.

Eighteen keys in the shared bases were AWS-shaped, so every one of them was
structurally undeployable on `gcp-0` regardless of what had been seeded. The
symptom was indirect and expensive: the ExternalSecret reported
`SecretSyncedError`, the workload waiting on the Secret sat in
`CreateContainerConfigError`, its HelmRelease never went Ready, and ten minutes
later Flux failed a health check naming only the HelmRelease. One absent
Grafana admin secret took out four Kustomizations at once —
`observability-victoria-metrics-k8s-stack` and the three that `dependsOn` it.

The constraint had already been met and worked around, one directory at a time:
`gcp-0`'s own overlays used dash names (`openbao-priv-gcp-ca-chain`,
`tailscale-k8s-operator-oauth`) while the directories it *shares* with `aws-0`
kept slash paths. That is precisely why the shared directories were the ones
that failed.

## Decision

**Shared-base secret keys use a flat, dash-separated name.** Dashes are legal
in both stores, so one name works on both clouds:

Old keys are written unquoted below on purpose: they are store keys, never
repository paths, and `scripts/verify-doc-paths.sh` reads a backticked
slash-string beginning with a top-level directory as a claim that the path
exists. That check earning a false positive here is a fair trade for the one it
exists to catch.

| Before (AWS-shaped key) | After |
|---|---|
| harbor/admin/password | `harbor-admin-password` |
| observability/victoria-metrics-k8s-stack/grafana-envvars | `observability-victoria-metrics-k8s-stack-grafana-envvars` |
| tailscale/k8s-operator/oauth-client | `tailscale-k8s-operator-oauth-client` |

The hierarchy the slashes expressed is kept as a prefix convention, so sorting a
listing still groups by component. Nothing depended on the slashes being path
separators — neither store has directories.

`aws-0`'s existing entries are migrated by `scripts/secret-store.sh
migrate-aws`, which copies old names to new ones. It never overwrites a target
and never deletes a source, so it is re-runnable and reversible.

### The exception, and why it is one

The OpenBao CA chain is **not** renamed into the shared base. Its *shape*
differs by cloud, not just its name: `aws-0` stores a JSON object and selects
the `ca` property out of it, while `gcp-0` stores raw PEM by deliberate design
(`scripts/openbao-config.sh:51`: "by design no root-CA secret exists on GCP,
only the chain"). No rename reconciles that, so `observability/gcp-0` patches
the whole `spec.data` list instead.

A naming rule fixes names. Where two clouds genuinely store different things, an
overlay is the honest expression, not a more clever variable.

## Alternatives considered

**Duplicate each affected ExternalSecret into a `gcp-0` overlay.** This is what
the repository had been doing incrementally, and it is why the problem stayed
hidden: each duplication solved one directory and left the shared ones broken.
It would have meant roughly ten more near-identical files whose only difference
was punctuation, against an explicit push to make the two clouds share
configuration rather than fork it.

**Introduce a separator variable** (`${secret_sep}`, `/` on AWS and `-` on GCP).
One variable, no duplication — but every key becomes unreadable, no key can be
grepped literally, and the rendered names still differ per cloud, so the store
contents fork anyway. It buys nothing over renaming once.

**Keep slash names and give `gcp-0` its own store abstraction.** Would require
either a second `ClusterSecretStore` name in the bases or a provider that maps
paths, and neither exists. It also leaves the trap armed for the next shared
base someone writes.

## Consequences

- One name works on both clouds; a new shared base needs no per-cloud copy.
- `aws-0`'s store must be migrated before its next deploy. The old names are
  left in place, so the migration is reversible and the two coexist until the
  old ones are removed by hand.
- Names are longer, and the longest is 63 characters
  (`observability-victoria-metrics-k8s-stack-alertmanager-slack-app`) against a
  255-character limit in both stores.
- `./scripts/secret-store.sh check --cloud aws|gcp` reports which keys a cluster
  needs and which are missing, so an unseeded secret surfaces immediately
  instead of as a ten-minute HelmRelease timeout.
- `seed` creates the three secrets the platform **generates** rather than
  obtains — the two Harbor passwords and Grafana's admin pair. It never
  overwrites, so it is safe on a store whose entries were written by hand.
  **Update (2026-08-30):** `seed_body` has since grown two more arms: a
  generated `cnpg/xplane-harbor/roles/harbor` password (#1873), and a
  `cnpg/xplane-zitadel/superuser` entry that is **derived**, not generated —
  it copies the admin password out of `zitadel-envvars` rather than rolling a
  fresh one, so CNPG and ZITADEL never disagree about the `postgres` role's
  password (#1875).
- Most of the store is still not created by code, and deliberately so. An OIDC
  client ZITADEL issued, a Slack app, a GitHub App key, a vendor token: a
  generated placeholder for any of those would produce a secret that exists,
  syncs, and fails at the point of use — strictly worse than one that is visibly
  missing and named by `check`.
- Two secrets are partially generated. `grafana-envvars` also carries
  `GF_AUTH_GENERIC_OAUTH_CLIENT_{ID,SECRET}` from a ZITADEL registration; Grafana
  boots without them, so seeding the admin pair alone is what releases the
  HelmRelease and the four Kustomizations behind it. SSO is configured
  afterwards.

## Related

- [ADR-0017](0017-multi-cloud-dns-naming.md) — per-cloud private domains, the
  other value that was hardcoded to AWS in shared bases
- [ADR-0022](0022-single-identity-provider-across-clouds.md) — the same shape of
  problem for the identity provider hostname
