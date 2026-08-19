name                  = "ogenki-openbao"           # Name of your Vault instance
leader_tls_servername = "bao.priv.cloud.ogenki.io" # Vault domain name that will be exposed to users
domain_name           = "priv.cloud.ogenki.io"     # Route53 private zone where to provision the DNS records
env                   = "dev"                      # Environment used to tags resources
mode                  = "dev"                      # Important: More about this setting in this documentation.
region                = "eu-west-3"                # Where all the resources will be created
# Kept on deliberately: this cluster is reprovisioned on every platform test, and SSM
# is how you get onto a node whose boot script failed. Turn it off for a long-lived
# deployment, once an identity provider is wired up and boots are boring.
enable_ssm                       = true
openbao_certificates_secret_name = "certificates/priv.cloud.ogenki.io/openbao" # The name of the AWS Secrets Manager secret containing the OpenBao certificates

# Prefer using hardened AMI
# ami_owner = "3xxxxxxxxx"                              # Account ID where the hardened AMI is
# ami_filter = {
#   "name" = ["*hardened-ubuntu-*"]
# }

prometheus_node_exporter_enabled = true

tags = { # In my case, these tags are also used to identify the supporting resources (VPC, subnets...)
  project                       = "cloud-native-ref"
  owner                         = "Smana"
  app                           = "openbao"
  "observability:node-exporter" = "true"
}
