# Nothing here any more. cert-manager's and the snapshot job's AppRole
# credentials, which this file wrote to Secret Manager, are replaced by the JWT
# method (see auth.tf). The bucket name the snapshot job needs is a per-cluster
# Flux variable (openbao_snapshot_bucket in opentofu/gcp/gke/configure).
