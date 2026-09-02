# syntax=docker/dockerfile:1
# The syntax directive above enables heredoc COPY (used below to embed the
# AWS CLI signing key as a literal file, rather than fetching it).

# Base: debian:bookworm-slim, not an Alpine variant. AWS CLI v2 ships no musl
# build, so `pip install awscli` (Alpine's only path) silently installs v1
# instead, and `gcloud` needs a real CPython — glibc + apt gets both, on both
# architectures this image is built for.
FROM debian:bookworm-slim

# The image's own version. `.github/workflows/build-container-images.yml` reads
# `ARG OPENBAO_SNAPSHOT_VERSION=` (the directory name upper-cased + _VERSION) and
# tags the image with it, so the CronJob can pin a real version instead of
# `latest`. Bump it whenever openbao-snapshot.sh changes behaviour.
ARG OPENBAO_SNAPSHOT_VERSION=v0.2.0

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
# Expected fingerprint of the AWS CLI signing key below. NOT a secret: it is a
# PUBLIC key's fingerprint, published by AWS at the URL cited above the key
# block, and its whole purpose is to be compared against in the open. Nothing
# here is weakened by it being readable.
#
# It trips two scanners anyway, because 40 hex characters is also the shape of
# an AWS secret access key, so it needs both suppressions:
#   - detect-secrets (pre-commit)  -> `pragma: allowlist secret`
#   - Checkov CKV_SECRET_2 (CI)    -> `checkov:skip`
# Suppressing a scanner is normally the wrong move; here the finding is a
# false positive on a value whose exposure is the point, and removing the
# fingerprint to satisfy the scanner would delete the check that makes the
# signature verification meaningful.
# pragma: allowlist secret
#checkov:skip=CKV_SECRET_2:Public GPG key fingerprint for the AWS CLI signing key, not an AWS access key
ARG AWS_CLI_KEY_FINGERPRINT=FB5DB77FD5C118B80511ADA8A6310ACC4672475C
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
# binary-arm64 both list google-cloud-cli in the Packages index. apt already
# verifies package signatures against the key scoped with signed-by=, so no
# separate integrity step is needed here (unlike aws/bao below).
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

# AWS CLI's own PGP public key, pasted verbatim from AWS's official docs:
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
# ("Optional: Verifying the integrity of your downloaded zip file" -> Linux).
# Embedded as a literal rather than fetched: a key pulled from the same
# channel as the artifact it's meant to vouch for adds ceremony, not trust.
# Key ID A6310ACC4672475C / User ID "AWS CLI Team <aws-cli@amazon.com>".
COPY <<'AWS_CLI_PUBLIC_KEY' /tmp/aws-cli-public-key.asc
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBF2Cr7UBEADJZHcgusOJl7ENSyumXh85z0TRV0xJorM2B/JL0kHOyigQluUG
ZMLhENaG0bYatdrKP+3H91lvK050pXwnO/R7fB/FSTouki4ciIx5OuLlnJZIxSzx
PqGl0mkxImLNbGWoi6Lto0LYxqHN2iQtzlwTVmq9733zd3XfcXrZ3+LblHAgEt5G
TfNxEKJ8soPLyWmwDH6HWCnjZ/aIQRBTIQ05uVeEoYxSh6wOai7ss/KveoSNBbYz
gbdzoqI2Y8cgH2nbfgp3DSasaLZEdCSsIsK1u05CinE7k2qZ7KgKAUIcT/cR/grk
C6VwsnDU0OUCideXcQ8WeHutqvgZH1JgKDbznoIzeQHJD238GEu+eKhRHcz8/jeG
94zkcgJOz3KbZGYMiTh277Fvj9zzvZsbMBCedV1BTg3TqgvdX4bdkhf5cH+7NtWO
lrFj6UwAsGukBTAOxC0l/dnSmZhJ7Z1KmEWilro/gOrjtOxqRQutlIqG22TaqoPG
fYVN+en3Zwbt97kcgZDwqbuykNt64oZWc4XKCa3mprEGC3IbJTBFqglXmZ7l9ywG
EEUJYOlb2XrSuPWml39beWdKM8kzr1OjnlOm6+lpTRCBfo0wa9F8YZRhHPAkwKkX
XDeOGpWRj4ohOx0d2GWkyV5xyN14p2tQOCdOODmz80yUTgRpPVQUtOEhXQARAQAB
tCFBV1MgQ0xJIFRlYW0gPGF3cy1jbGlAYW1hem9uLmNvbT6JAlQEEwEIAD4CGwMF
CwkIBwIGFQoJCAsCBBYCAwECHgECF4AWIQT7Xbd/1cEYuAURraimMQrMRnJHXAUC
akV0ygUJDqP4lQAKCRCmMQrMRnJHXFHjD/9eyZLYcKuQOlLvtqSDtUBiEZf6ZZjM
i3ygYH8rJNtuToUH+HvSpe819urJCquXhDrlK6N+aqW0hCLtNABJG/vsafIgvIYJ
hSGgpgtNnQyMV1jViRWqPjbouw8OkYKBThUfT1i2Y+wn58ifs6ODBCmTexWtXspA
Si+Gt49xDOW0APmbOPnI+a4HJW6tVEo6MWS0WjzpiBayR3d1A4pt4YrPfSdDgpLo
h2SLQqlRqvvVZJaWBjhkErNFpfsBA06sDcPEOb0G8LBUbR4WOcdvhe5LubJbZuxC
AG9kNPCVeQP1ixwjgjXKysaxeQ6rv0VzIQgRp6tLVLWhy6AKDNvLjFSsmXZ1Wl08
Y/RlOHXlzLuQMRE6sR1wOdRxc9TsrNWTGiBK65cvSWOy03JeBkQQ8pesqltiyxI9
U21kkgiXtTSKNGfKK8pO27D81YANhRqPK7iTp6kuFiY2WtOg90KTMNlIT+Ff85Y2
b1rHj6Z0SrCkJujhWk3IBPic/wJgz01LEc/OAdUPlby90RJZcIBhSlWhT7mXnXIO
c0HWlNQrns2s3CTyYwZSiSlYe9ApeLwhjDo8NhbFuCAy61l6O5UsR4AfZxx/rGKv
2wFb1/RN/P4gNe6vmxZAPjR0AQcwD3tc2McimOLr/22kmPz8IH3I0X7WoSFr0Biz
E91G7bb0hOb/cA==
=knv7
-----END PGP PUBLIC KEY BLOCK-----
AWS_CLI_PUBLIC_KEY

# AWS CLI v2, official installer, GPG-verified before it's ever unzipped or
# run. Only x86_64/aarch64 zips exist -- map from buildx's TARGETARCH, which
# is the only architecture-conditional step this Dockerfile needs since apt
# and the gcloud repo already resolve natively.
#
# This binary carries APPROLE_ROLE_ID/APPROLE_SECRET_ID on every run and, on
# restore, the secret that reconstructs an OpenBao root token -- TLS-only
# integrity is thin for that blast radius, so this step doesn't just import
# the key, it checks the imported key's fingerprint against the one pinned
# below (from the same AWS doc page as the key block) before trusting any
# signature made with it.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) AWS_ARCH=x86_64 ;; \
      arm64) AWS_ARCH=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH} for aws-cli" >&2; exit 1 ;; \
    esac; \
    AWS_ZIP="awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip"; \
    curl -fsSL "https://awscli.amazonaws.com/${AWS_ZIP}" -o "/tmp/${AWS_ZIP}"; \
    curl -fsSL "https://awscli.amazonaws.com/${AWS_ZIP}.sig" -o "/tmp/${AWS_ZIP}.sig"; \
    export GNUPGHOME; GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --import /tmp/aws-cli-public-key.asc; \
    ACTUAL_FPR="$(gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" { print $10; exit }')"; \
    if [ "${ACTUAL_FPR}" != "${AWS_CLI_KEY_FINGERPRINT}" ]; then \
      echo "AWS CLI signing key fingerprint mismatch: got ${ACTUAL_FPR}, expected ${AWS_CLI_KEY_FINGERPRINT}" >&2; \
      exit 1; \
    fi; \
    gpg --batch --verify "/tmp/${AWS_ZIP}.sig" "/tmp/${AWS_ZIP}"; \
    unzip -q "/tmp/${AWS_ZIP}" -d /tmp; \
    /tmp/aws/install; \
    rm -rf "/tmp/${AWS_ZIP}" "/tmp/${AWS_ZIP}.sig" /tmp/aws /tmp/aws-cli-public-key.asc "${GNUPGHOME}"

# bao (OpenBao CLI), checksum-verified against the release's own published
# checksums.txt before extraction -- same reasoning as the AWS CLI above:
# this binary runs with the OpenBao AppRole credentials. GitHub release asset
# naming already uses amd64/arm64, same vocabulary as TARGETARCH -- no
# translation needed. `set -eux` means sha256sum -c's non-zero exit on a
# mismatch fails the build; nothing here swallows that.
RUN set -eux; \
    BAO_TARBALL="openbao_${BAO_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSL "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/${BAO_TARBALL}" -o "/tmp/${BAO_TARBALL}"; \
    curl -fsSL "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/checksums.txt" -o /tmp/bao-checksums.txt; \
    grep -E "  ${BAO_TARBALL}$" /tmp/bao-checksums.txt > /tmp/bao.sha256sum; \
    (cd /tmp && sha256sum -c bao.sha256sum); \
    tar -xzf "/tmp/${BAO_TARBALL}" -C /usr/local/bin bao; \
    chmod +x /usr/local/bin/bao; \
    rm -f "/tmp/${BAO_TARBALL}" /tmp/bao-checksums.txt /tmp/bao.sha256sum

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
