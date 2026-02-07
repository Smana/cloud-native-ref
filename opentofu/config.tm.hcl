# Global variables that are used in all scripts
# Use your own values for these variables
globals {
  provisioner                      = "tofu"
  region                           = "eu-west-3"
  profile                          = ""
  eks_cluster_name                 = "mycluster-0"
  openbao_url                      = "https://bao.priv.cloud.ogenki.io:8200"
  root_token_secret_name           = "openbao/cloud-native-ref/tokens/root"
  root_ca_secret_name              = "certificates/priv.cloud.ogenki.io/root-ca"
  cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"
  cert_manager_approle             = "cert-manager"

  # Helm chart versions for EKS bootstrap
  cilium_version        = "1.19.0"
  flux_operator_version = "0.40.0"
  flux_instance_version = "0.40.0"

  # Flux sync configuration
  flux_sync_repository_url = "https://github.com/Smana/cloud-native-ref.git"
}
