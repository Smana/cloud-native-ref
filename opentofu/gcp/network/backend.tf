# GCP state lives in GCS, in a project that holds nothing else.
#
# It used to live in the AWS S3 bucket alongside every other stack's state. The
# reason recorded then was sound but argued against the wrong thing: the GCS
# bucket it replaced sat INSIDE ogenki-435905 -- the very project whose resources
# it tracked -- so deleting or suspending that project would have taken the state
# describing it along with it. That is an argument against a state bucket in the
# workload project, not against GCS. Project `ogenki-tfstate` holds the bucket
# and nothing else, which closes the loop properly.
#
# What the move buys, in order of weight:
#
#   1. GCP stacks need GCP credentials ONLY. Under S3, every `tofu plan` here
#      also required AWS credentials -- the same shape of cross-cloud coupling
#      this platform rejected elsewhere on principle.
#   2. Teardown survives an AWS outage. An S3 outage, or a suspended AWS
#      account, previously blocked GCP `destroy` as well as `apply` -- and
#      teardown is the operation most needed when something is already wrong.
#   3. Secrets in state stop crossing clouds. opentofu/gcp/openbao/management's
#      vault provider reads OpenBao's live root token out of Secret Manager and
#      that value flows into its state; with shared state, an AWS-side
#      compromise handed over a working GCP credential. (This used to name
#      cert-manager's AppRole secret_id -- that backend is gone, cert-manager
#      authenticates with a cluster JWT now, and the root token is a strictly
#      worse thing to leak.)
#
# The accepted cost is a SECOND hand-created bootstrap prerequisite. Neither
# bucket is IaC-managed (the usual chicken-and-egg), so this is one more
# undocumented step before a fresh clone can plan -- documented here and in
# ADR-0018 rather than left implicit, exactly like the Cloud KMS key ring in
# opentofu/gcp/openbao/cluster/kms.tf.
#
#   gcloud projects create ogenki-tfstate --organization=<org-id>
#   gcloud billing projects link ogenki-tfstate --billing-account=<account-id>
#   gcloud services enable storage.googleapis.com --project=ogenki-tfstate
#   gcloud storage buckets create gs://ogenki-cloud-native-ref-tfstate \
#     --project=ogenki-tfstate --location=europe-west4 \
#     --uniform-bucket-level-access --public-access-prevention
#   gcloud storage buckets update gs://ogenki-cloud-native-ref-tfstate --versioning
#
# opentofu/shared/* deliberately STAYS in S3: the tailnet belongs to neither
# cloud, which is the one case the original single-bucket rationale gets right.
#
# No `use_lockfile` here -- unlike the S3 backend, GCS locks natively and has
# always done so.
terraform {
  backend "gcs" {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/network"
  }
}
