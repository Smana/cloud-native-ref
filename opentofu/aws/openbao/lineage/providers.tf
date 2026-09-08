provider "aws" {
  region = var.region
}

# The replica region for the multi-region seal key. A regional KMS outage in
# eu-west-3 must not take the seal with it, or the GCP standby could never
# unwrap the snapshot it restores -- see the design's "Cross-cloud fallback".
provider "aws" {
  alias  = "replica"
  region = var.replica_region
}
