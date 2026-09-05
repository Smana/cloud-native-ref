project_id = "ogenki-435905"
# aws_mirror_role_arn is set in Task 16, after the federation stack has created
# the role. Until then the transfer job is not created.

# Set in Task 16 Step 2, from `tofu output openbao_snapshot_mirror_role_arn` in
# opentofu/shared/aws-gcp-federation. With this present the Storage Transfer job
# is created and can assume the role to read the AWS snapshot bucket.
aws_mirror_role_arn = "arn:aws:iam::396740644681:role/openbao-snapshot-mirror"
