stack {
  name        = "network"
  description = "network"
  id          = "3564c93f-543f-47c9-9a84-a1d4b5ed7461"

  tags = [
    "aws",
    "network",
    "infrastructure"
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
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [let.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars",
      { sync_deployment = true }],
    ]
  }
}
