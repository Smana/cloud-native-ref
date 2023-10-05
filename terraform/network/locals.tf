locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = {
    environment = var.env
  }
}
