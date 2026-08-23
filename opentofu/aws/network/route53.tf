module "zones" {
  source  = "terraform-aws-modules/route53/aws"
  version = "~> 6.0"

  name    = "priv.cloud.ogenki.io"
  comment = "Internal zone for private DNS hosts"

  vpc = {
    one = {
      vpc_id = module.vpc.vpc_id
    }
  }

  tags = {
    env = var.env
  }
}
