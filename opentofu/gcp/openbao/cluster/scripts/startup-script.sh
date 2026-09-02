#!/bin/bash
# Rendered into the instance's `metadata_startup_script` (compute.tf),
# concatenated AFTER setup-local-disks.sh -- the data disk must already be
# mounted before OpenBao is configured to store its data there.
#
# NOTHING SECRET MAY BE TEMPLATED INTO THIS FILE. GCP instance metadata is
# readable from the metadata server (http://metadata.google.internal) by
# anything running on the box -- a plain unauthenticated HTTP GET with only
# the `Metadata-Flavor: Google` header, no IAM check gates it -- and via
# `compute.instances.get`/`getSerializedPortOutput`-equivalent API calls by
# anything holding that permission. TLS material is fetched from Secret
# Manager at boot instead, under a service account grant scoped to one secret
# (see iam.tf).

set -o errexit
set -o nounset
set -o pipefail

echo "OpenBao init"

export DEBIAN_FRONTEND=noninteractive

# jq/wget/gnupg are not guaranteed present on the stock Ubuntu image; snapd is,
# on every Canonical cloud image since 16.04, and is what installs the gcloud
# CLI below. xfsprogs is installed earlier, in setup-local-disks.sh -- it has
# to exist before that script's mkfs.xfs runs, which is BEFORE this script
# (compute.tf concatenation order), so installing it here would be too late.
apt-get update -qq
apt-get install -y -qq jq wget gnupg

# Instance identity from the GCP metadata server (IMDS equivalent).
PRIVATE_IP=$(curl -fsS -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

# gcloud CLI is not preinstalled on the stock Ubuntu image. Google's apt repo
# would mean another GPG-verified add-apt-repository dance in the boot path;
# snapd is already installed and verifies its own packages, so use that --
# same pattern the AWS script uses for awscli via snap.
snap wait system seed.loaded
snap install google-cloud-cli --classic
export PATH="$PATH:/snap/bin"

# Install OpenBao
# ---------------
OPENBAO_VERSION="${openbao_version}"
OPENBAO_BINARY="openbao_$${OPENBAO_VERSION}_linux_amd64.deb"
BINARY_URL="https://github.com/openbao/openbao/releases/download/v$OPENBAO_VERSION/$OPENBAO_BINARY"
SIGNATURE_URL="$BINARY_URL.gpgsig"
GPG_KEY_URL="https://openbao.org/assets/openbao-gpg-pub-20240618.asc"

# Pinned primary key fingerprint for "OpenBao <openbao@lists.lfedge.org>".
# Without this the key is fetched fresh on every boot and trusted on sight,
# which makes the signature check prove only that the key and the binary came
# from the same place.
OPENBAO_GPG_FINGERPRINT="66D15FDD87287219C8E15478D200CD702853E6D0" # pragma: allowlist secret

wget -q "$BINARY_URL" -O "$OPENBAO_BINARY"
wget -q "$SIGNATURE_URL" -O "$OPENBAO_BINARY.gpgsig"
wget -q "$GPG_KEY_URL" -O openbao-gpg-pub.asc

## Verify the key is the one we expect before importing it
if ! gpg --show-keys --with-colons openbao-gpg-pub.asc | awk -F: '/^fpr:/{print $10}' | grep -qx "$OPENBAO_GPG_FINGERPRINT"; then
  echo "OpenBao GPG key fingerprint mismatch - expected $OPENBAO_GPG_FINGERPRINT"
  exit 1
fi
gpg --import openbao-gpg-pub.asc

## Verify the signature
if ! gpg --verify "$OPENBAO_BINARY.gpgsig" "$OPENBAO_BINARY"; then
  echo "Signature verification failed!"
  exit 1
fi
echo "Signature verified successfully!"

dpkg -i "$OPENBAO_BINARY"

rm -f "$OPENBAO_BINARY" "$OPENBAO_BINARY.gpgsig" openbao-gpg-pub.asc

# Fetch the server TLS material
# -----------------------------
# The `openbao` user and group are created by the .deb, so this has to run
# after the install.
install -d -m 0750 -o root -g openbao /opt/openbao/tls

TLS_SECRET=$(gcloud secrets versions access latest \
  --secret "${server_cert_secret_name}" --project "${project_id}")

umask 077
printf '%s' "$TLS_SECRET" | jq -r '.cert' > /opt/openbao/tls/tls.crt
printf '%s' "$TLS_SECRET" | jq -r '.key'  > /opt/openbao/tls/tls.key
printf '%s' "$TLS_SECRET" | jq -r '.ca'   > /opt/openbao/tls/ca.pem
unset TLS_SECRET

chown root:openbao /opt/openbao/tls/tls.key
chmod 0640 /opt/openbao/tls/tls.key
chmod 0644 /opt/openbao/tls/tls.crt /opt/openbao/tls/ca.pem

# Configure OpenBao
# -----------------
chown openbao:openbao /etc/openbao/openbao.hcl
chown -R openbao:openbao "${openbao_data_path}"

cat << EOF > /etc/openbao/openbao.hcl
cluster_addr = "https://$PRIVATE_IP:8201"
api_addr     = "https://${fqdn}:8200"
ui           = true

listener "tcp" {
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file   = "/opt/openbao/tls/tls.crt"
  tls_key_file    = "/opt/openbao/tls/tls.key"

  # Matches the AWS cluster. Without it /v1/sys/metrics requires a token, and
  # the VMScrapeConfig does not send one -- it authenticates the SERVER with the
  # CA and nothing else. The scrape then fails as:
  #
  #   cannot scrape target "https://bao.priv.../v1/sys/metrics?format=prometheus"
  #   ... response body: {"errors":["permission denied"]}
  #
  # which surfaces as the OpenBaoDown alert firing CRITICAL while the instance
  # is healthy and RUNNING -- the alert says "down", the cause is authorization.
  #
  # Safe because the listener is reachable only from the VPC and the tailnet:
  # there is no public route to :8200, and metrics carry no secret material.
  telemetry {
    unauthenticated_metrics_access = true
  }
}

# Also matching the AWS cluster, and needed for the same scrape to return
# anything useful: without prometheus_retention_time, OpenBao does not retain
# metrics for the Prometheus format at all, so /v1/sys/metrics answers but with
# nothing in it. disable_hostname keeps the instance name out of every metric
# name, which would otherwise change on each rebuild and break every query.
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}

# Raft, single node. `file` could neither take nor receive a snapshot, so a
# node's contents died with it; a one-node raft cluster is bootstrapped by
# `operator init` and costs nothing extra. api_addr is the FQDN so a restored
# snapshot's peer list (which raft.Restore discards anyway) never has to match.
storage "raft" {
  path    = "${openbao_data_path}"
  node_id = "$(hostname)"
}

%{ if seal_provider == "awskms" }
# STANDBY seal: the AWS lineage's multi-region key, in its replica region,
# reached with the federated role. Credentials come from the SDK's web-identity
# provider -- AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE in the systemd
# drop-in below -- so nothing is in this file.
seal "awskms" {
  region     = "${aws_seal_region}"
  kms_key_id = "${aws_seal_kms_key_id}"
}
%{ else }
seal "gcpckms" {
  project    = "${project_id}"
  region     = "${region}"
  key_ring   = "${kms_key_ring}"
  crypto_key = "${kms_crypto_key}"
}
%{ endif }
EOF

# Retry forever, instead of giving up after a few fast failures.
#
# This is the fix for the incident recorded in compute.tf: a missing IAM
# permission made openbao.service fail at seal configuration, systemd hit the
# packaged unit's start limit -- "Start request repeated too quickly" -- and
# stopped trying. The instance stayed RUNNING and served nothing, so granting
# the permission changed nothing; it had to be deleted by hand.
#
# StartLimitIntervalSec=0 disables the rate limiter entirely, and RestartSec
# spaces the attempts out so a genuinely broken config is not a hot loop. The
# failures OpenBao hits at boot are almost all transient-or-external -- a KMS
# permission, an API not yet propagated, Secret Manager unreachable -- and every
# one of them resolves without touching the node, but only if something is still
# trying.
#
# StartLimitIntervalSec belongs in [Unit]; Restart/RestartSec in [Service].
# Splitting them wrong is silently ignored.
mkdir -p /etc/systemd/system/openbao.service.d
cat << 'EOF' > /etc/systemd/system/openbao.service.d/restart.conf
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=30s
EOF

%{ if seal_provider == "awskms" }
# AWS web-identity token for the awskms seal.
# ------------------------------------------
# A Compute Engine identity token (aud = sts.amazonaws.com, sub = this service
# account's unique ID) is written where the AWS SDK's web-identity credential
# provider reads it, and refreshed every 50 minutes -- the token lives one hour.
# The seal only needs it at unseal and at key operations, so a stopped timer
# does not stop a running node; it stops the NEXT unseal. `bao status` and the
# OpenBaoSealed alert are what surface that.
install -d -m 0750 -o root -g openbao /run/openbao

cat << 'EOF' > /usr/local/bin/openbao-aws-token.sh
#!/bin/bash
set -euo pipefail
TOKEN=$(curl -fsS -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com&format=full")
umask 027
printf '%s' "$TOKEN" > /run/openbao/aws-web-identity-token.tmp
chown root:openbao /run/openbao/aws-web-identity-token.tmp
mv -f /run/openbao/aws-web-identity-token.tmp /run/openbao/aws-web-identity-token
EOF
chmod 0755 /usr/local/bin/openbao-aws-token.sh

cat << 'EOF' > /etc/systemd/system/openbao-aws-token.service
[Unit]
Description=Refresh the AWS web-identity token the OpenBao awskms seal uses

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openbao-aws-token.sh
EOF

cat << 'EOF' > /etc/systemd/system/openbao-aws-token.timer
[Unit]
Description=Refresh the OpenBao AWS web-identity token every 50 minutes

[Timer]
OnBootSec=0
OnUnitActiveSec=50min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

# The seal reads these at start. A drop-in rather than /etc/openbao/openbao.env
# so it does not depend on the packaged unit's EnvironmentFile handling.
cat << EOF > /etc/systemd/system/openbao.service.d/aws-seal.conf
[Unit]
After=openbao-aws-token.service
Requires=openbao-aws-token.service

[Service]
Environment=AWS_ROLE_ARN=${aws_seal_role_arn}
Environment=AWS_WEB_IDENTITY_TOKEN_FILE=/run/openbao/aws-web-identity-token
Environment=AWS_REGION=${aws_seal_region}
EOF

systemctl daemon-reload
systemctl enable --now openbao-aws-token.timer
%{ endif }
systemctl daemon-reload

systemctl start openbao.service
systemctl enable openbao.service
