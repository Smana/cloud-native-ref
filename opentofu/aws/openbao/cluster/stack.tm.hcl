stack {
  name        = "OpenBao cluster"
  description = "OpenBao cluster"
  id          = "29c70276-6dfc-4bc5-935e-a6c32cebfce4"
  after = [
    "/opentofu/aws/network",
    "/opentofu/aws/openbao/lineage",
  ]
  tags = [
    "aws",
    "openbao",
    "openbao-cluster",
    "security"
  ]
}
