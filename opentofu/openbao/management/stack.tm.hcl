stack {
  name        = "OpenBao management"
  description = "Configure the OpenBao cluster"
  id          = "17b0065c-171c-4bd0-90d9-17793673ff17"

  after = [
    "/opentofu/openbao/cluster"
  ]

  tags = [
    "aws",
    "openbao",
    "openbao-management",
    "security"
  ]
}
