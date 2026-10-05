---
title: AWS is the primary cloud again; the IdP and the platform run on aws-0
linkTitle: 0055 · AWS primary again
weight: 550
description: The SP3 live validation runs on aws-0, the platform's original home. With ADR-0052's GCP placement in force, every factory run on aws-0 would have needed cross-cloud authentication against gcp-0's directory. The owner flipped primary_cloud back to aws on 2026-10-04; aws-0 hosts ZITADEL again and gcp-0's instance suspends.
lastVerified: 2026-10-05
---

**Status**: Accepted (owner, 2026-10-04; validated on `integration/agent-factory`, commit `5d688376`)
**Date**: 2026-10-04
**Deciders**: Smana (Platform Owner)
**Reverses**: [ADR-0052]({{< relref "/docs/decisions/0052-gcp-primary-platform.md" >}})'s placement — GCP as
primary cloud and gcp-0 as ZITADEL host. ADR-0052's GCP-parity infrastructure (fresh-on-build directory,
workforce identity, GKE lane) stands and stays deployable for parity.
**Restores**: [ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}})'s placement (AWS
primary) and its "relocation carries the directory's data" rule that ADR-0052 had superseded in part.

## Context

ADR-0052 moved the primary cloud to GCP on 2026-09-29 to halve cost while the agent programme ran on
`gcp-0`. That experiment served its purpose: the gcp run proved parity. The next validation — SP3, the
factory's end-to-end issue→task→run→PR→close walkthrough — was scheduled for `aws-0`, the platform's
original home, where the restored OpenBao lineage and the promoted database seed live.

With the IdP on `gcp-0` and the programme on `aws-0`, every run would have crossed the cloud boundary to
authenticate: consumers on `aws-0` reading a `gcp-0`-hosted ZITADEL, tokens issued by a directory the run's
cluster does not control, and one more network path between the test and whatever it is meant to measure.

## Decision

`primary_cloud = "aws"` in `opentofu/config.tm.hcl`; `aws-0` hosts ZITADEL (`spec.suspend: false` in
`clusters/aws-0/security/zitadel.yaml`), `gcp-0` suspends its instance (`suspend: true`). The `aws-0`
restored directory replaces `gcp-0`'s fresh one. Consequences in configuration:

- An unset `TM_CLOUD` means `aws` again, and `terramate script run deploy` runs the AWS lane silently.
- The exit-3 guard in `scripts/provision/tm-provisioner.sh` (refusing an unset `TM_CLOUD` while the
  primary is not `aws`) is inert — kept in place for the next placement flip.
- Placement is still the ADR-0027 single switch: `deploy_identity_provider` derives from
  `primary_cloud`, and `./scripts/ci/validate-idp-topology.sh` verifies the suspend flags agree.

Implemented in commit `5d688376` on `integration/agent-factory` (2026-10-04).

## Considered Options

### Option 1: Stay GCP-hosted while validating on aws-0

Rejected. Every factory run on `aws-0` needs SSO against the one directory, so the IdP on `gcp-0` puts a
cross-cloud dependency — tailnet path, token exchange, and a second cluster that must stay up — into every
run of the thing being validated. A failure would be ambiguous between the factory and the boundary.

### Option 2: Run SP3 on gcp-0 as well

Rejected. The parity run already happened; the open question is the factory end-to-end on the AWS lane with
the restored lineage and seed, which `gcp-0` (fresh directory every build) cannot exercise.

### Option 3: AWS primary again — chosen

`aws-0` hosts both the platform and the IdP for the validation window; `gcp-0` remains deployable for
parity with its directory suspended, ready for a later flip.

## Consequences

### Positive

- The SP3 validation exercises one cluster end to end; auth failures belong to that cluster alone.
- The restored `aws-0` OpenBao lineage and promoted ZITADEL seed are used as the source they are.
- Placement changes stay one switch, verified in CI.

### Negative

- `gcp-0`'s fresh directory — built for the parity run, with its re-grants — goes unused while suspended.
  A future flip re-creates it from scratch (ADR-0052's fresh-on-build model is unchanged).
- Two flips in a week make `primary_cloud` the most load-bearing line in `config.tm.hcl`. The topology
  verifier exists precisely so the flags cannot silently disagree with it.

## References

- Commit `5d688376` — `feat(platform): aws-0 is primary again — it hosts the IdP, gcp-0 suspends its`
- [ADR-0052]({{< relref "/docs/decisions/0052-gcp-primary-platform.md" >}}) — the placement this reverses
- [ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}}) — placement as one switch
- [Migrate the identity provider]({{< relref "/docs/guides/migrate-the-identity-provider.md" >}}) — the
  procedure a flip with data follows
