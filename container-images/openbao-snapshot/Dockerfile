# Base: debian:bookworm-slim, not an Alpine variant. AWS CLI v2 ships no musl
# build, so `pip install awscli` (Alpine's only path) silently installs v1
# instead, and `gcloud` needs a real CPython — glibc + apt gets both, on both
# architectures this image is built for.
FROM debian:bookworm-slim

# renovate: datasource=github-releases depName=openbao/openbao
ARG BAO_VERSION=2.6.2
# Google's apt repo publishes google-cloud-cli for both amd64 and arm64;
# pinning the exact version keeps the image reproducible.
#
# Deliberately left unannotated for Renovate: this is an apt package version
# from Google's own repo, not a GitHub release, and Renovate has no datasource
# for it. Bump by hand -- do not add a `# renovate:` comment here, it would
# silently match nothing (exactly the bug this file's other two ARGs had until
# Task 10).
ARG GCLOUD_VERSION=582.0.0-0
# renovate: datasource=github-releases depName=aws/aws-cli
ARG AWSCLI_VERSION=2.36.31
# Set by buildx for each platform in the build matrix (linux/amd64, linux/arm64).
ARG TARGETARCH

# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      jq \
      unzip; \
    rm -rf /var/lib/apt/lists/*

# gcloud CLI, via Google's official apt repo (python3 comes in as its Depends).
# Repo publishes real per-arch packages -- verified: binary-amd64 and
# binary-arm64 both list google-cloud-cli in the Packages index.
RUN set -eux; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "google-cloud-cli=${GCLOUD_VERSION}"; \
    rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/google-cloud-sdk.list; \
    gcloud config set core/disable_usage_reporting true; \
    gcloud config set component_manager/disable_update_check true

# AWS CLI v2, official installer. Only x86_64/aarch64 zips exist -- map from
# buildx's TARGETARCH, which is the only architecture-conditional step this
# Dockerfile needs since apt and the gcloud repo already resolve natively.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) AWS_ARCH=x86_64 ;; \
      arm64) AWS_ARCH=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH} for aws-cli" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# bao (OpenBao CLI). GitHub release asset naming already uses amd64/arm64,
# same vocabulary as TARGETARCH -- no translation needed.
RUN set -eux; \
    curl -fsSL "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/openbao_${BAO_VERSION}_linux_${TARGETARCH}.tar.gz" -o /tmp/bao.tar.gz; \
    tar -xzf /tmp/bao.tar.gz -C /usr/local/bin bao; \
    chmod +x /usr/local/bin/bao; \
    rm -f /tmp/bao.tar.gz

# The CronJob sets HOME=/snapshot (a writable emptyDir) and runs with
# readOnlyRootFilesystem: true, so gcloud's config dir (under $HOME by
# default) and any AWS CLI scratch files land there instead of on the RO root.
# The image still needs a HOME at build/install time -- /root is fine since
# nothing here is written after this point.
RUN groupadd --gid 1001 snapshot \
    && useradd --uid 1000 --gid 1001 --no-create-home --shell /usr/sbin/nologin snapshot

COPY openbao-snapshot.sh /usr/local/bin/openbao-snapshot.sh
RUN chmod +x /usr/local/bin/openbao-snapshot.sh

USER 1000:1001

# No ENTRYPOINT. The CronJob sets `command: [sh, -c, "openbao-snapshot.sh ..."]`,
# which in Kubernetes always replaces ENTRYPOINT regardless of what the image
# declares -- so a fixed ENTRYPOINT here would only ever be exercised by a
# plain `docker run <image>` with no args, and would silently swallow any other
# command passed to `docker run <image> <cmd> ...` (Docker appends such args to
# ENTRYPOINT rather than replacing it). Leaving it unset means `docker run
# <image> sh -c '...'` behaves exactly like the pod: the given command runs
# directly, with /usr/local/bin already on PATH for the bare `openbao-snapshot.sh`
# the CronJob calls.
CMD ["/usr/local/bin/openbao-snapshot.sh"]
