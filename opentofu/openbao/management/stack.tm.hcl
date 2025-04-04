stack {
  name        = "management"
  description = "management"
  id          = "17b0065c-171c-4bd0-90d9-17793673ff17"
  after = [
    "/opentofu/openbao/cluster"
  ]
  tags = [
    "aws",
    "openbao",
    "security"
  ]
}

# script "init_openbao" {
#   description = "Openbao initial configuration"
#   lets {
#     openbao_url = "https://bao.priv.cloud.ogenki.io:8200"
#     openbao_secret_name = "openbao/cloud-native-ref/tokens/root"
#     region = "eu-west-3"
#     profile = ""
#   }
# job {
#     description = "Init the root token"
#     commands = [
#       [
#         "bash",
#         tm_abspath("init-openbao.sh"),
#         "--url",
#         let.openbao_url,
#         "--secret-name",
#         let.openbao_secret_name,
#         "--region",
#         let.region,
#         "--profile",
#         let.profile
#       ]
#     ]
#   }
# }

script "deploy" {
  description = "Configure Openbao cluster"
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
