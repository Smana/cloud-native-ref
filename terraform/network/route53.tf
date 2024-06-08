module "zones" {
  source  = "terraform-aws-modules/route53/aws//modules/zones"
  version = "~> 3.0"

  zones = {
    "priv.cloud.ogenki.io" = {
      comment = "Internal zone for private DNS hosts"
      vpc = [
        {
          vpc_id = module.vpc.vpc_id
        }
      ]
      tags = {
        env = var.env
      }
    }
  }
}
