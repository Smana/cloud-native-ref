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
  as its `Depends`), `jq`.
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
docker run --rm --entrypoint sh ghcr.io/smana/openbao-snapshot:v0.2.0 \
  -c 'aws --version; gcloud --version | head -1; bao version; jq --version'
```

### Both architectures (what CI does)

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/smana/openbao-snapshot:v0.2.0 \
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
