stack {
  name        = "cluster"
  description = "cluster"
  id          = "29c70276-6dfc-4bc5-935e-a6c32cebfce4"
  after = [
    "/opentofu/network"
  ]
  tags = [
    "aws",
    "openbao",
    "security"
  ]
}

script "deploy" {
  description = "Run Openbao cluster deployment"
  lets {
    provisioner = "tofu"
    openbao_url = "https://bao.priv.cloud.ogenki.io:8200"
    openbao_secret_name = "openbao/cloud-native-ref/tokens/root"
    region = "eu-west-3"
    profile = ""
  }
  job {
    name = "deploy"
    description = "Tofu init and apply"
    commands = [
      [let.provisioner, "init"],
      [let.provisioner, "validate"],
      ["tfsec", "."],
      [let.provisioner, "apply", "-auto-approve"],
      [
        "bash",
        tm_abspath("init-openbao.sh"),
        "--url",
        let.openbao_url,
        "--secret-name",
        let.openbao_secret_name,
        "--region",
        let.region,
        "--profile",
        let.profile
      ]
    ]
  }
}
