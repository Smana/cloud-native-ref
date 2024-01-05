locals {
  name = format("%s-%s-%s", var.region, var.env, var.name)
  tags = {
    "VaultInstance" = local.name
  }
}
