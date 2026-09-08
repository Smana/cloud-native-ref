#!/bin/bash
# Rendered into EC2 user-data, concatenated after setup-local-disks.sh.
#
# NOTHING SECRET MAY BE TEMPLATED INTO THIS FILE. user-data is readable from
# IMDS by anything on the box, and via ec2:DescribeLaunchTemplateVersions by
# anything holding that permission. TLS material is fetched from Secrets
# Manager at boot instead, under an instance-role policy scoped to one ARN.

set -o errexit
set -o nounset
set -o pipefail

echo "OpenBao init"

export DEBIAN_FRONTEND=noninteractive

IMDS_TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

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
# Ubuntu dropped the `awscli` deb in noble, and the official v2 installer would
# mean hand-rolling another GPG-verified download into the boot path. snapd is
# already installed and verifies its own packages, so use that. `snap wait`
# guards the well-known cloud-init seeding race.
# Baking an AMI removes this step entirely - see cluster/README.md.
snap wait system seed.loaded
snap install aws-cli --classic
AWS=/snap/bin/aws

# The `openbao` user and group are created by the .deb, so this has to run
# after the install.
install -d -m 0750 -o root -g openbao /opt/openbao/tls

TLS_SECRET=$("$AWS" secretsmanager get-secret-value \
  --region "${region}" \
  --secret-id "${openbao_certificates_secret_id}" \
  --query SecretString --output text)

umask 077
printf '%s' "$TLS_SECRET" | jq -r '.cert' > /opt/openbao/tls/tls.crt
printf '%s' "$TLS_SECRET" | jq -r '.key' > /opt/openbao/tls/tls.key
printf '%s' "$TLS_SECRET" | jq -r '.ca' > /opt/openbao/tls/ca.pem
unset TLS_SECRET

chown root:openbao /opt/openbao/tls/tls.key
chmod 0640 /opt/openbao/tls/tls.key
chmod 0644 /opt/openbao/tls/tls.crt /opt/openbao/tls/ca.pem

# Configure OpenBao
# -----------------
chown openbao:openbao /etc/openbao/openbao.hcl
chown -R openbao:openbao ${openbao_data_path}

# NO BACKTICKS BELOW, in the HCL or in its comments. This heredoc is
# deliberately UNQUOTED (<< EOF, not << 'EOF') because $PRIVATE_IP and
# $INSTANCE_ID have to expand. Bash therefore also performs command
# substitution inside it -- comments included, where nobody expects it. A
# backtick pair used as inline-code quoting EXECUTES what it encloses and is
# replaced by the output: the deployed openbao.hcl silently loses those words,
# and the boot runs whatever they named. set -e does not catch it, because the
# substitution is an argument to cat rather than a command of its own. Quote
# literals with "double quotes", as the comments below do, or leave them bare.
# Escaping each backtick with a backslash renders correctly too, but a
# half-escaped pair fails quietly -- an even count deletes words, an odd count
# breaks the whole script -- so the rule here is none, not escaped.

cat << EOF > /etc/openbao/openbao.hcl
cluster_addr  = "https://$PRIVATE_IP:8201"
api_addr      = "https://$PRIVATE_IP:8200"
ui            = true

# Required with Integrated Storage, which is OpenBao's only production-quality
# backend. With mlock enabled OpenBao locks the whole Bolt database into
# physical memory and the OOM killer takes the process once it outgrows RAM.
# https://openbao.org/docs/rfcs/mlock-removal/
disable_mlock = true

listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file      = "/opt/openbao/tls/tls.crt"
  tls_key_file       = "/opt/openbao/tls/tls.key"
  tls_client_ca_file = "/opt/openbao/tls/ca.pem"
  telemetry {
    unauthenticated_metrics_access = true
  }
}

telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}

# Raft in BOTH modes. "dev" used to run the "file" backend, which can neither
# take nor receive a snapshot -- so a dev node's contents died with it. A
# single-node raft cluster costs nothing extra: operator init bootstraps it,
# and retry_join finds only itself. In "ha" the same stanza joins five nodes.
storage "raft" {
  path = "${openbao_data_path}"
  node_id = "$INSTANCE_ID"
  retry_join {
    auto_join               = "provider=aws region=${region} tag_key=OpenBaoInstance tag_value=${openbao_instance}"
    auto_join_scheme        = "https"
    auto_join_port          = 8200
    leader_tls_servername   = "${leader_tls_servername}"
    leader_client_cert_file = "/opt/openbao/tls/tls.crt"
    leader_client_key_file  = "/opt/openbao/tls/tls.key"
    leader_ca_cert_file     = "/opt/openbao/tls/ca.pem"
  }
}

seal "awskms" {
  region     = "${region}"
  kms_key_id = "${kms_unseal_key_id}"
}
EOF

systemctl start openbao.service
systemctl enable openbao.service

# Install Prometheus node exporter
# --------------------------------
if ${prom_exporter_enabled}; then
useradd --system --no-create-home --shell /usr/sbin/nologin prometheus

# renovate: datasource=github-releases depName=prometheus/node_exporter
NODE_EXPORTER_VERSION=1.12.1
wget -q -O /tmp/node_exporter.tar.gz "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz"
tar -xzf /tmp/node_exporter.tar.gz -C /tmp
mv "/tmp/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter" /usr/local/bin/node_exporter

cat << EOF > /etc/systemd/system/node-exporter.service
[Unit]
Description=Prometheus exporter for server metrics

[Service]
Restart=always
User=prometheus
ExecStart=/usr/local/bin/node_exporter
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutStopSec=20s
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start node-exporter
systemctl enable node-exporter
fi
