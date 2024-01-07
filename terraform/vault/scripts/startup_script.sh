#!/bin/bash

echo "Vault init"

export DEBIAN_FRONTEND=noninteractive

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

# Vault
chown vault:vault /etc/vault.d/vault.hcl
chown -R vault:vault ${vault_data_path}
chown root:vault /opt/vault/tls/tls.key

cat << EOF > /etc/vault.d/vault.hcl
ui = true

cluster_addr  = "https://$PRIVATE_IP:8201"
api_addr      = "https://$PRIVATE_IP:8200"
disable_mlock = true

listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file      = "/opt/vault/tls/tls.crt"
  tls_key_file       = "/opt/vault/tls/tls.key"
  tls_client_ca_file = "/opt/vault/tls/ca.pem"
  telemetry {
    unauthenticated_metrics_access = true
  }
}


%{ if dev_mode }
storage "file" {
  path = "${vault_data_path}"
}
%{ else }
storage "raft" {
  path = "${vault_data_path}"
  node_id = "$INSTANCE_ID"
  retry_join {
    auto_join               = "provider=aws region=${region} tag_key=VaultInstance tag_value=${vault_instance}"
    auto_join_scheme        = "https"
    auto_join_port          = 8200
    leader_tls_servername   = "${leader_tls_servername}"
    leader_client_cert_file = "/opt/vault/tls/tls.crt"
    leader_client_key_file  = "/opt/vault/tls/tls.key"
    leader_ca_cert_file     = "/opt/vault/tls/ca.pem"
  }
}
%{ endif }

seal "awskms" {
  region     = "${region}"
  kms_key_id = "${kms_unseal_key_id}"
}

EOF

systemctl start vault.service
systemctl enable vault.service

# Install Prometheus node exporter
# --------------------------------
if ${prom_exporter_enabled}; then
useradd --system --no-create-home --shell /usr/sbin/nologin prometheus

NODE_EXPORTER_VERSION=1.7.0
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
ExecReload=/bin/kill -HUP $MAINPID
TimeoutStopSec=20s
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start node-exporter
systemctl enable node-exporter
fi