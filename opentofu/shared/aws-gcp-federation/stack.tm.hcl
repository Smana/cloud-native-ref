stack {
  name        = "Shared AWS-GCP DNS federation"
  description = "AWS IAM OIDC provider and role letting GKE workloads manage records in the public Route53 zone. Owned by neither cloud"
  id          = "b4e6a1c2-9f83-4d17-8a52-3c7e0d914f6b"

  # No `after`. The OIDC issuer URL is derived from project/location/name, not
  # read from the cluster, so this stack does not need GKE to exist -- which is
  # deliberate: an ordering edge here would make an AWS stack depend on a GCP one.

  tags = [
    "shared",
    "aws",
    "dns",
  ]
}
