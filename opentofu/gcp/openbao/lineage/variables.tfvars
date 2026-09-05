project_id = "ogenki-435905"

# From `tofu output openbao_snapshot_mirror_role_arn` in
# opentofu/shared/aws-gcp-federation, so that stack must be applied first. With
# this present the Storage Transfer job is created and can assume the role to
# read the AWS snapshot bucket; left empty, the job is not created at all and
# nothing reaches the GCS side of the lineage.
aws_mirror_role_arn = "arn:aws:iam::396740644681:role/openbao-snapshot-mirror"
