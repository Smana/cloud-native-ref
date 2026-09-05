stack {
  name        = "Shared AWS-GCP DNS federation"
  description = "AWS IAM OIDC providers and roles letting GKE workloads manage records in the public Route53 zone, the GCP OpenBao node use the AWS seal key, and Storage Transfer mirror the snapshot bucket. Owned by neither cloud"
  id          = "b4e6a1c2-9f83-4d17-8a52-3c7e0d914f6b"

  # No `after`. The OIDC issuer URL is derived from project/location/name, not
  # read from the cluster, so this stack does not need GKE to exist -- which is
  # deliberate: an ordering edge here would make an AWS stack depend on a GCP one.

  # NOT tagged `aws`, deliberately, though every resource it creates is an AWS
  # one. On this repo `aws` marks the AWS CLUSTER LANE -- the stacks that build
  # aws-0 -- which is what makes `--no-tags=aws` a useful selection: "deploy
  # everything except the other cloud". This stack exists solely so GKE
  # workloads can write to the public Route53 zone, so excluding it from a GCP
  # deploy is exactly backwards, and it is the reason that deploy used to need
  # several commands instead of one.
  #
  # The description above already says it: owned by neither cloud.
  tags = [
    "shared",
    "dns",
  ]
}
