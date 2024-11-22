locals {
  name = format("%s-%s-%s", var.region, var.env, var.name)
  tags = {
    "OpenBaoInstance" = local.name
  }
}
