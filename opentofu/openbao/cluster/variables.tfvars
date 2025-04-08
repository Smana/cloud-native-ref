name                             = "ogenki-openbao"                              # Name of your Vault instance
leader_tls_servername            = "bao.priv.cloud.ogenki.io"                    # Vault domain name that will be exposed to users
domain_name                      = "priv.cloud.ogenki.io"                        # Route53 private zone where to provision the DNS records
env                              = "dev"                                         # Environment used to tags resources
mode                             = "dev"                                         # Important: More about this setting in this documentation.
region                           = "eu-west-3"                                   # Where all the resources will be created
enable_ssm                       = true                                          # Allow to access to the EC2 instances. Enabled for provisionning, but then it should be disabled.
openbao_certificates_secret_name = "certificates/priv.cloud.ogenki.io/openbao"   # The name of the AWS Secrets Manager secret containing the OpenBao certificates
oidc_enabled                     = true                                          # Enable OIDC authentication
oidc_secret_id                   = "openbao/cloud-native-ref/oidc-client-secret" # The ID of the AWS Secrets Manager secret containing the OIDC client secret

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
