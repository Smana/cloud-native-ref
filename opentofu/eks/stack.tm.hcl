stack {
  name        = "eks"
  description = "eks"
  id          = "51322224-ac05-497c-bbaf-e2a821a9b2d8"

  after = [
    "/opentofu/network"
  ]

  tags = [
    "aws",
    "eks",
    "kubernetes",
    "infrastructure"
  ]

  wants = [
    "/opentofu/openbao/cluster",
    "/opentofu/openbao/management"
  ]
}


script "deploy" {
  description = "Deploy network infrastructure"
  lets {
    provisioner = "tofu"
  }
  job {
    name = "deploy"
    description = "Tofu init and apply"
    commands = [
      [let.provisioner, "init"],
      [let.provisioner, "validate"],
      ["trivy", "config", "."],
      [let.provisioner, "apply", "-auto-approve"],
    ]
  }
}
