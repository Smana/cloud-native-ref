script "openbao" "configure" {
  description = "Init OpenBao cluster and configure PKI"
  job {
    name        = "openbao-configure"
    description = "OpenBao configuration"
    commands = [
      # Initialize OpenBao cluster
      [
        "bash",
        "../../../scripts/openbao-config.sh",
        "init",
        "--url",
        global.openbao_url,
        "--root-token-secret-name",
        global.root_token_secret_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
        "--skip-verify",
      ],
      [
        "bash",
        "../../../scripts/openbao-config.sh",
        "pki",
        "--url",
        global.openbao_url,
        "--root-token-secret-name",
        global.root_token_secret_name,
        "--root-ca-secret-name",
        global.root_ca_secret_name,
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
