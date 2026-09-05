---
title: Per-cloud OpenTofu state — GCP state in GCS, AWS state in S3
linkTitle: 0018 · Per-cloud state
weight: 180
description: GCP stacks keep their state in a GCS bucket in a dedicated project rather than sharing the AWS S3 bucket, so that running or destroying GCP needs GCP credentials only and an AWS outage cannot block a GCP teardown.
lastVerified: 2026-09-02
---

**Status**: Accepted
**Date**: 2026-08-25
**Deciders**: Platform Team
**Supersedes**: the single-bucket rationale recorded in `opentofu/gcp/network/backend.tf` (2026-08-23)
**Related Design**: GCP Support — Dual-Cloud Platform Design, in the repository at
`docs/superpowers/specs/2026-08-18-gcp-support-design.md` (design docs are not published to
this site, so this is a repo path rather than a link)

---

## Context

When GCP support was first bootstrapped, its OpenTofu state went into a GCS bucket named
`ogenki-435905-tfstate`. That bucket sat **inside project `ogenki-435905`** — the very
project whose resources it tracked. Deleting or suspending that project would have taken the
state describing it along with it, leaving no supported way to clean up what remained.

The fix applied at the time was to move GCP state into the existing AWS S3 bucket
(`demo-smana-remote-backend`), alongside every other stack's state, with two reasons
recorded:

1. State belongs outside the blast radius of what it manages.
2. One bucket is one hand-created bootstrap prerequisite instead of two. Neither bucket is
   IaC-managed — the usual chicken-and-egg — so each extra one is another undocumented step
   before a fresh clone can plan.

Reason 1 is correct and remains correct. **But it argued against the wrong thing.** The
hazard was a state bucket living in the workload project, not GCS as a backend. Moving to S3
fixed the self-reference by introducing a different coupling, and that coupling was recorded
at the time as an accepted cost: *"running the GCP stacks now requires AWS credentials as
well as GCP ones, and an S3 outage blocks GCP applies."*

Two things since then made that cost worth re-examining:

- **The platform's stated principle hardened.** The GCP OpenBao design rejected sharing AWS's
  OpenBao specifically because it would make GCP certificate issuance depend on AWS. The same
  objection applies to every GCP stack depending on AWS for its state, and with more force:
  it is not one workstream's coupling, it is the foundation of all of them.
- **State began holding a live credential.** `opentofu/gcp/openbao/management` wrote
  cert-manager's AppRole `secret_id` into its state, which its own `secrets.tf` named as the
  one place this design put a live credential in state. Under a shared bucket, an AWS-side
  compromise yields a working GCP credential. (That specific credential is gone since
  [ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}})
  replaced AppRole with JWT auth; the driver is recorded as it stood. An OpenBao management
  state still holds sensitive material — the AWS one carries the generated operator
  password — so the conclusion is unchanged.)

## Decision Drivers

- **Cloud independence.** Each cloud should be operable — including destroyable — with only
  its own credentials.
- **Teardown must survive a partner-cloud outage.** Teardown is the operation most needed
  when something is already wrong.
- **Blast radius of secrets held in state.**
- **Bootstrap simplicity.** Every non-IaC prerequisite is a step a fresh clone must be told
  about.
- **Migration cost**, which is not constant over time — see *Timing* below.

## Considered Options

### Option 1: Keep one shared S3 bucket

Status quo. Simplest bootstrap: one bucket, one lifecycle policy, one place to look. Costs
the AWS credential requirement, the availability coupling, and the shared blast radius on
secrets in state.

### Option 2: GCS bucket inside the workload project

Rejected on the original grounds, which were right: the state would live inside the project
it describes.

### Option 3: GCS bucket in a dedicated project (chosen)

Project `ogenki-tfstate` holds one bucket and nothing else. GCP stacks need GCP credentials
only; the self-reference loop is genuinely closed rather than relocated.

## Decision Outcome

**Chosen option**: Option 3.

| Stacks | Backend | Location |
|---|---|---|
| `opentofu/gcp/**` | `gcs` | `gs://ogenki-cloud-native-ref-tfstate`, project `ogenki-tfstate`, `europe-west4` |
| `opentofu/aws/**` | `s3` | `demo-smana-remote-backend`, `eu-west-3` |
| `opentofu/shared/**` | `s3` | `demo-smana-remote-backend`, `eu-west-3` |

`opentofu/shared/*` deliberately stays in S3. The tailnet belongs to neither cloud, and that
is the one case the original single-bucket rationale gets exactly right: a resource owned by
neither cloud should not be filed under either.

**This was safe to do because no GCP stack reads AWS state and no AWS stack reads GCP
state.** Every `terraform_remote_state` in the GCP tree is GCP → GCP: `gke/init` and
`openbao/cluster` read `gcp/network`, and `gke/configure` reads `gke/init`. Splitting the
backends therefore severed no data flow.

### Timing

The migration was performed while **every GCP state file contained `resources: 0`** — the
platform had just been torn down after verifying workstream 11. Migrating state is normally
the risky half of a change like this; in that window there was nothing to lose track of, so
the new backends were initialised clean rather than copied. Verified before acting:

```
network:            resources=0 serial=35
gke/init:           resources=0 serial=29
gke/configure:      resources=0 serial=17
openbao/cluster:    resources=0 serial=17
openbao/management: resources=0 serial=3
```

That window is a property of this platform's build-validate-destroy lifecycle, not luck — but
it does close. Deferring the change until GCP state described live infrastructure would have
made it strictly more expensive.

## Consequences

### Positive

- GCP `plan`, `apply` and `destroy` need GCP credentials only.
- An S3 outage or a suspended AWS account no longer blocks a GCP teardown.
- `openbao/management`'s state, which holds sensitive material (a live AppRole `secret_id`
  when this was written; the generated operator password today), is no longer readable
  from an AWS-side compromise.
- The backend now matches the repository's own `opentofu/{aws,gcp,shared}` partition.
- GCS locks natively, so the `use_lockfile` flag the S3 backend needs has no analogue to
  carry — one less thing to get wrong.

### Negative

- **Two hand-created bootstrap prerequisites instead of one**, neither IaC-managed. This is
  the real cost and it does not disappear. It is documented in
  `opentofu/gcp/network/backend.tf` alongside the commands, in the same way the Cloud KMS key
  ring is documented in `opentofu/gcp/openbao/cluster/kms.tf`.
- A second billing-linked GCP project to keep track of, though it holds one small bucket and
  costs effectively nothing.
- The old GCP state objects remain in S3 under `cloud-native-ref/gcp/`. They contain no
  resources and are left in place rather than deleted, but they are now misleading: anything
  pointing at those keys would silently read empty state. They should be removed once this
  change has settled.

### Neutral

- No change for AWS. No change for `opentofu/shared/*`.
- Terramate orchestration is unaffected — the backend is per-stack configuration it does not
  read.

## Implementation Notes

The bucket is a bootstrap prerequisite, created by hand:

```bash
gcloud projects create ogenki-tfstate --organization=<org-id>
gcloud billing projects link ogenki-tfstate --billing-account=<account-id>
gcloud services enable storage.googleapis.com --project=ogenki-tfstate
gcloud storage buckets create gs://ogenki-cloud-native-ref-tfstate \
  --project=ogenki-tfstate --location=europe-west4 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://ogenki-cloud-native-ref-tfstate --versioning
```

Versioning is the recovery path for a truncated or corrupted state file, and is the one
setting that is painful to add after the fact.

## References

- `opentofu/gcp/network/backend.tf` — the full rationale, restated at the point of use
- [ADR-0007 · Cloud abstraction boundaries]({{< relref "0007-cloud-abstraction-boundaries.md" >}})
- [ADR-0017 · Multi-cloud DNS naming]({{< relref "0017-multi-cloud-dns-naming.md" >}})
