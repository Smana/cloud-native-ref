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
