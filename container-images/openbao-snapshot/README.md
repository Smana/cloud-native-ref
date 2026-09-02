# openbao-snapshot

Container image wrapping `openbao-snapshot.sh` — the script that backs up an OpenBao raft
snapshot to object storage (`save`) or restores one (`restore`). Consumed by the
`openbao-snapshot` CronJob at
[`security/base/openbao-snapshot/snapshot-cronjob.yaml`](../../security/base/openbao-snapshot/snapshot-cronjob.yaml).

## Overview

- **Base image**: `debian:bookworm-slim` — not Alpine. AWS CLI v2 ships no musl build (Alpine's
  only install path either fails outright or silently falls back to `pip install awscli`, which
  is v1 with different behaviour), and `gcloud` needs a real CPython. glibc + apt gets both CLIs,
  on both architectures.
- **Binaries installed**: `bao` (OpenBao CLI, downloaded from GitHub releases), `aws` (AWS CLI v2,
  official installer), `gcloud` (Google Cloud CLI, via Google's apt repo — `python3` comes along
  as its `Depends`), `jq`, `curl`. The script's `check_required_bin` requires `bao`, `jq` and
  `curl` on every run — `curl` because the seal type is read from `/v1/sys/seal-status` (see
  below), and `bao status` cannot stand in for it: that command exits 2 whenever the node is
  sealed, which is exactly its state on the restore path.
- **Platforms**: `linux/amd64` and `linux/arm64`, both built by
  [`.github/workflows/build-container-images.yml`](../../.github/workflows/build-container-images.yml).
- **User**: non-root, uid 1000 / gid 1001, matching the CronJob's `securityContext`.
- **Entrypoint**: `/usr/local/bin/openbao-snapshot.sh` (also on `PATH` as a bare command, since
  the CronJob invokes it via `sh -c "openbao-snapshot.sh save ..."`, overriding this image's
  `ENTRYPOINT`).

## CLOUD selects the cloud

The script picks `aws` or `gcloud`/object-storage-cli calls based on the `CLOUD` environment
variable (`aws` or `gcp`, defaults to `aws`). Both CLIs ship in every image — the variable is set
by the CronJob's environment, not by building a different image per cloud.

## Object naming — the seal is in the name

Objects are written as:

```
<UTC timestamp>-<seal>.snap        e.g. 2026-09-02T041500Z-awskms.snap
```

A Raft snapshot can only be restored **under the seal that encrypted it**, and the platform
exploits that deliberately: a GCP standby unseals with the *AWS* KMS key so it can restore AWS
snapshots ([ADR-0032](../../website/content/docs/decisions/0032-openbao-store-of-record-lineage.md)).
The consequence is that after a failover the GCP bucket holds a mix — mirrored objects are
AWS-sealed by construction, and the standby's own are AWS-sealed too, because it ran with
`seal_provider = "awskms"`. Before the seal was in the name, nothing distinguished them and a
later `gcpckms` node would select an AWS-sealed object, restore it, and stay sealed with no
useful error.

| Property | Why |
|---|---|
| A trailing **segment**, not a key prefix | A prefix (`awskms/<ts>.snap`) makes an object vanish from the candidate set — both selection paths list non-recursively and strip through the last `/`. That is exactly right for "move this aside" and exactly wrong for normal operation. |
| Timestamp **first**, fixed width | `sort \| tail -n1` stays chronological even in a bucket holding two seals. |
| Seal read from the **node**, not from config | `seal_provider` in a tfvars file can disagree with the process that is running. `GET /v1/sys/seal-status` reports `.type` — the barrier seal type — and is **unauthenticated**: it sits on OpenBao's bare HTTP mux next to `/v1/sys/init` and `/v1/sys/health`, so both `save` (holding a JWT token) and `restore` (running against a node that is up but not yet initialised) can ask it. |

`.type` is only trustworthy from **OpenBao 2.4.0** onward: before
[openbao/openbao#1638](https://github.com/openbao/openbao/pull/1638) it was hardcoded `shamir`
for every configuration ([#1633](https://github.com/openbao/openbao/issues/1633)). Both clusters
pin 2.6.2 (`openbao_version`). The script does not simply trust the field — a node reporting a
`shamir` barrier *and* `recovery_seal: true` is refused outright, because a real Shamir barrier
has no recovery seal, so that pair is the fingerprint of a pre-2.4.0 server. Labelling every
object `-shamir` on both clouds would hide the mixed-seal hazard again.

### `restore` refuses a mismatch, before anything destructive

`restore` selects the **newest** object and compares its seal segment with the node's own seal.
On a mismatch it refuses — before the download, before `operator init`, before
`snapshot restore -force` — and prints both seals plus a count of what the bucket holds. The
gate is duplicated in [`scripts/openbao-config.sh`](../../scripts/openbao-config.sh)
(`rehydrate`), on purpose: that script has to decide **before** its own `bao operator init`, and
this one only runs after it.

Set `OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true` to restore the newest object the node's seal
*can* unwrap instead. That discards every write after it, so it is not the default — it exists
for a failback, where the foreign-sealed objects are not coming back. If no object carries the
node's seal, the run still refuses rather than falling through to a plain init, which would
overwrite the lineage's stored root token and recovery keys.

### Objects with no seal segment are never selected

Anything written before this scheme — a flat `<timestamp>.snap` — carries no seal, and nothing a
selector can read establishes which one wrapped it. The policy is **strict refusal**, not a
silent skip:

- Accepting one reintroduces the whole hazard: on the GCP bucket its seal could be either.
- Silently skipping one could restore an older snapshot while a newer sits there — silent data
  loss, on the disaster-recovery path.

The remediation is one command, and it is reversible. Determine the seal from the failover
timeline (the failover's start time bounds which objects are AWS-sealed), then retag:

```bash
# GCS
gcloud storage mv "gs://<bucket>/2026-09-02T041500Z.snap" \
                  "gs://<bucket>/2026-09-02T041500Z-awskms.snap"
# S3
aws s3 mv "s3://<bucket>/2026-09-02T041500Z.snap" \
          "s3://<bucket>/2026-09-02T041500Z-awskms.snap"
```

If you would rather it were simply gone, delete it — this lineage's first deploy starts from an
empty bucket, so in practice there are no legacy objects to deal with.

## Script location

The script's canonical home is [`openbao-snapshot.sh`](./openbao-snapshot.sh), inside this
directory, because the CI workflow builds each image with the image directory as its Docker
build context (`container-images/<name>`) and only triggers on changes under
`container-images/**`. A file living under `scripts/` would be outside that context and outside
that trigger — the image would either fail to build (`COPY` can't reach outside the context) or,
worse, go silently stale (an edit that never triggers a rebuild).

[`scripts/openbao-snapshot.sh`](../../scripts/openbao-snapshot.sh) is kept as a relative symlink
to this file, so the documented operator command
(`./scripts/openbao-snapshot.sh restore -a "${VAULT_ADDR}"`, see
[`website/content/docs/platform/security/openbao.md`](../../website/content/docs/platform/security/openbao.md)
and [`website/content/docs/reference/commands.md`](../../website/content/docs/reference/commands.md))
keeps working. There is one source of truth; Docker never sees the symlink, since the real file
sits inside the build context.

## Building

### Local (single platform)

```bash
cd container-images/openbao-snapshot
./build.sh
docker run --rm --entrypoint sh ghcr.io/smana/openbao-snapshot:v0.3.0 \
  -c 'aws --version; gcloud --version | head -1; bao version; jq --version'
```

### Both architectures (what CI does)

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/smana/openbao-snapshot:v0.3.0 \
  container-images/openbao-snapshot
```

Building `linux/arm64` on an amd64 dev machine needs QEMU emulation registered
(`docker run --privileged --rm tonistiigi/binfmt --install all`) and a buildx builder that lists
`linux/arm64` among its platforms (`docker buildx inspect`).

## Updating pinned versions

`BAO_VERSION`, `GCLOUD_VERSION` and `AWSCLI_VERSION` are `ARG`s at the top of the `Dockerfile`.
Bump them there; `BAO_VERSION` should track
[`opentofu/aws/openbao/cluster/variables.tf`'s `openbao_version`](../../opentofu/aws/openbao/cluster/variables.tf)
so the snapshot CLI matches the server it talks to.

The image's **own** version is `ARG OPENBAO_SNAPSHOT_VERSION` in the same `Dockerfile`, and that
`ARG` is the only place it is written down. CI derives the published tag from it, and `build.sh`
reads it out of the `Dockerfile` rather than keeping a copy — a second literal drifts, and did.
Bump the `ARG` and both paths follow; the tags quoted above then need updating by hand, because
prose cannot read an `ARG`.

## Security

- Non-root (uid 1000 / gid 1001), no privilege escalation, all capabilities dropped, read-only
  root filesystem — enforced by the CronJob's `securityContext`, matched by the image's own
  `USER 1000:1001`.
- `HOME=/snapshot` (set by the CronJob, a writable `emptyDir`) is where `gcloud`'s config dir and
  any CLI scratch files land, since the root filesystem is read-only.
- No credentials are baked into the image. AWS and GCP credentials come from EKS/GKE workload
  identity; OpenBao credentials are a projected ServiceAccount token (audience `openbao`) mounted
  by the CronJob and exchanged at the per-cluster `jwt/<cluster>` mount. There is no stored
  OpenBao secret to rotate — the AppRole id/secret that used to arrive via `envFrom` from an
  `openbao-snapshot` Secret is gone.
