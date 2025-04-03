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

script "init_openbao" {
  description = "Openbao initial configuration"
  job {
    description = "Init the root token"
    commands = [
      "echo test"
    ]
  }
}
