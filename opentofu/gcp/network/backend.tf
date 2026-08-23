# State lives in S3, not GCS, even though this stack manages GCP resources.
#
# One bucket for the whole platform, in the home cloud. Two reasons, the first
# being the one that matters:
#
#   1. The GCS bucket it replaced (ogenki-435905-tfstate) sat INSIDE project
#      ogenki-435905 -- the very project whose resources it tracked. Deleting or
#      suspending that project would have taken the state describing it along
#      with it. State belongs outside the blast radius of what it manages.
#   2. One bucket is one hand-created bootstrap prerequisite instead of two.
#      Neither bucket is IaC-managed (the usual chicken-and-egg), so each extra
#      one is another undocumented step before a fresh clone can plan.
#
# opentofu/shared/tailscale set this precedent already: its state is here for
# the same reason, because the tailnet belongs to neither cloud.
#
# The accepted cost: running the GCP stacks now requires AWS credentials as well
# as GCP ones, and an S3 outage blocks GCP applies. A real coupling, taken
# deliberately for a single-owner platform.
#
# NOTE the hardcoded region. It is the S3 BUCKET's region and has nothing to do
# with var.region, which in these stacks is a GCP region (europe-west4).
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/gcp/network/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true # native S3 locking (.tflock object, no DynamoDB)
  }
}
