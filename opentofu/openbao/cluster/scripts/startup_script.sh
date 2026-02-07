#!/bin/bash

echo "OpenBao init"

export DEBIAN_FRONTEND=noninteractive

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)


# Install OpenBao
# ---------------
## Set URLs for the binary, signature, and GPG key
OPENBAO_VERSION="${openbao_version}"
eval OPENBAO_BINARY="openbao_$OPENBAO_VERSION""_linux_amd64.deb"
BINARY_URL="https://github.com/openbao/openbao/releases/download/v$OPENBAO_VERSION/$OPENBAO_BINARY"
SIGNATURE_URL="https://github.com/openbao/openbao/releases/download/v$OPENBAO_VERSION/$OPENBAO_BINARY.gpgsig"
GPG_KEY_URL="https://openbao.org/assets/openbao-gpg-pub-20240618.asc"

## Download the binary, signature, and GPG key
wget -q "$BINARY_URL" -O $OPENBAO_BINARY
wget -q "$SIGNATURE_URL" -O $OPENBAO_BINARY.gpgsig
wget -q "$GPG_KEY_URL" -O openbao-gpg-pub.asc

## Import the OpenBao public key
gpg --import openbao-gpg-pub.asc

## Verify the signature
gpg --verify $OPENBAO_BINARY.gpgsig $OPENBAO_BINARY
if [ $? -ne 0 ]; then
  echo "Signature verification failed!"
  exit 1
else
  echo "Signature verified successfully!"
fi

## Install the binary
dpkg -i $OPENBAO_BINARY

## Clean up
rm $OPENBAO_BINARY $OPENBAO_BINARY.gpgsig openbao-gpg-pub.asc

# Configure OpenBao
# -----------------
chown openbao:openbao /etc/openbao/openbao.hcl
chown -R openbao:openbao ${openbao_data_path}
chown root:openbao /opt/openbao/tls/tls.key

cat << EOF > /etc/openbao/openbao.hcl
cluster_addr  = "https://$PRIVATE_IP:8201"
api_addr      = "https://$PRIVATE_IP:8200"
ui            = true

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


%{ if dev_mode }
storage "file" {
  path = "${openbao_data_path}"
}
%{ else }
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
%{ endif }

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

# Download and install the Prometheus node exporter
# --------------------------------------------------
NODE_EXPORTER_VERSION=1.8.2
wget -O /tmp/node_exporter.tar.gz https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
tar -xzf /tmp/node_exporter.tar.gz -C /tmp
mv /tmp/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter /usr/local/bin/node_exporter

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
