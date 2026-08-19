script "deploy" {
  description = "Init OpenBao cluster and configure PKI"
  job {
    name        = "openbao-configure"
    description = "OpenBao configuration"
    commands = [
      # Initialize OpenBao cluster. Stores the root token and the recovery keys
      # in two separate AWS Secrets Manager entries.
      #
      # --skip-verify is still needed here: this runs against a freshly booted
      # cluster before anything has vouched for its certificate, and the
      # request carries no secret in either direction.
      [
        "bash",
        "../../../scripts/openbao-config.sh",
        "init",
        "--url",
        global.openbao_url,
        "--root-token-secret-name",
        global.root_token_secret_name,
        "--recovery-keys-secret-name",
        global.recovery_keys_secret_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
        "--skip-verify",
      ],
      # Materialise the CA chain for the Vault provider. Has to be a script
      # step rather than a local_file resource: provider configuration is
      # evaluated before any resource exists, so the file must already be on
      # disk when `tofu init` runs.
      [
        "bash",
        "../../../scripts/openbao-config.sh",
        "ca",
        "--root-ca-secret-name",
        global.root_ca_secret_name,
        "--ca-output-file",
        ".tls/ca.pem",
        "--region",
        global.region,
        "--profile",
        global.profile,
      ],
      # Module management: Configure OpenBao (SecretsEngine, Approles, PKI, etc.)
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "plan", "-out=out.tfplan", "-lock=false", "-var-file=variables.tfvars"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars",
        {
          sync_deployment = true
          tofu_plan_file  = "out.tfplan"
        }
      ],
    ]
  }
}
