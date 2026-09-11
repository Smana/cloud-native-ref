---
title: A GCP-only platform runs its own OpenBao lineage and its own identity directory
linkTitle: 0037 · GCP-only runs its own store and directory
weight: 370
description: When GCP runs alone it uses a GCP-sealed OpenBao lineage and GCP's own ZITADEL directory, with the Stage 2 configuration from a shared module, so it needs no AWS key and no AWS data. Running GCP from the AWS lineage is rejected because it ties the test topology to AWS; keeping GCP on Secret Manager is rejected because it forks the secrets model.
lastVerified: 2026-09-11
---

**Status**: Accepted
**Date**: 2026-09-11
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0027](0027-primary-cloud-provider.md) — the relocation wording
this settles for the GCP-only case; [ADR-0033](0033-openbao-store-of-record-lineage.md) —
the lineage, and its driver "GCP-only deployments keep working with no AWS
dependency"; [ADR-0036](0036-per-app-secret-ownership-via-zitadel-groups.md) — the
mounts and personas this carries to GCP

---

## Context

AWS primary is the nominal topology. AWS + GCP runs sometimes, and GCP-only occasionally, as a test.

Stage 2 of ADR-0033 made OpenBao the store of record. Its design scoped GCP out except for the `ClusterSecretStore`, and that cluster-side parity did land. But GCP's OpenBao never got the `platform/` and `apps/` mounts, the policies or the logins. After the shared ExternalSecrets were repointed at OpenBao, 14 of them failed on gcp-0 in both GCP topologies: they authenticated through `jwt/gcp-0`, then read nothing.

A second gap was specific to GCP-only. Its snapshot bucket holds the AWS mirror, whose every object is AWS-sealed, so a GCP-sealed node had no way to start a lineage.

ADR-0027 says a GCP-only switch *relocates* singletons, carrying their data. ADR-0033's driver says GCP-only needs no AWS dependency. Carrying AWS's OpenBao data means unsealing with AWS's key, so the two cannot both hold.

## Decision Drivers

- GCP-only must work without the AWS KMS key or AWS's data. It is a test topology, and it must not depend on the one it tests.
- One secrets model on both clouds: the same mounts, policies and logins, defined once.
- No change to AWS primary, the nominal topology.

## Considered Options

### Option 1: GCP's own lineage and directory, Stage 2 from a shared module *(chosen)*

GCP's OpenBao is sealed by its own Cloud KMS key and gets the Stage 2 configuration from `opentofu/shared/modules/openbao-store-of-record`. It is seeded from GCP Secret Manager. ZITADEL restores GCP's own seed with its own master key and client secrets.

**Pros**: no AWS dependency; one definition of Stage 2; AWS untouched.
**Cons**: GCP's data diverges from AWS's between runs. A grant made on one directory does not exist on the other.

### Option 2: Run GCP from the AWS lineage

This is the `awskms` standby of the cross-cloud failover guide.

**Pros**: the secrets arrive already migrated, and there is one directory.
**Cons**: GCP-only needs the AWS key and AWS's newest snapshot, and ZITADEL must move its AWS seed, admin token and client secrets across. That is a migration, not a mode.

### Option 3: Keep GCP on Secret Manager

Point gcp-0's shared ExternalSecrets back at `gcpsm`.

**Pros**: the smallest change.
**Cons**: two secrets models, and every future shared ExternalSecret has to be patched per cloud.

## Decision Outcome

**Chosen option**: Option 1.

**Rationale**: it is the only option in which a GCP-only platform needs nothing from AWS. ADR-0027 rules out two clouds running duplicate singletons *at the same time*; a GCP-only platform with its own directory is not that. Relocating AWS's data remains available as the deliberate migration in *Migrate the identity provider*, and it is not a precondition for running GCP alone.

## Consequences

### Positive

- GCP's OpenBao defines everything the 14 OpenBao-backed consumers on gcp-0 read, so none of them fails on a missing policy or mount — validated live in a later run. AWS + GCP still needs GCP's OpenBao seeded and the AWS directory's client secrets, which this ADR leaves out of scope.
- `scripts/validate-openbao-policies.sh` fails CI when a JWT role names a policy its OpenBao does not define, which is the gap that hid this.

### Negative

- GCP's and AWS's directories and secrets are separate. Mitigation: GCP-only is a test topology, and relocating with data remains documented for when continuity matters.
- The first boot of a GCP lineage needs the operator to set `OPENBAO_NEW_LINEAGE=true` once. It is refused whenever a top-level object under the node's own seal exists, whenever any top-level snapshot's name carries no `-<seal>` segment (its seal is unknown), and when combined with `OPENBAO_SNAPSHOT_KEY`.

### Neutral

- AWS still defines Stage 2 inline until it moves onto the module. That move needs a live AWS OpenBao, so its plan can be verified.

## Implementation Notes

- Design: `docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-design.md`
- Plan: `docs/superpowers/plans/2026-09-11-openbao-stage2-gcp.md`
- Module: `opentofu/shared/modules/openbao-store-of-record`, called by `opentofu/gcp/openbao/management/store-of-record.tf`
- First boot: `OPENBAO_NEW_LINEAGE=true`, in `scripts/openbao-config.sh`

## References

- [Cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}})
- [Secrets]({{< relref "/docs/platform/security/secrets.md" >}})
- [Migrate the identity provider]({{< relref "/docs/guides/migrate-the-identity-provider.md" >}})
