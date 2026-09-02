# The seal key is lineage state, not cluster state. It used to be created here
# (kms.tf) and destroyed with the stack, which made every snapshot from the
# previous lineage unreadable by the next cluster. opentofu/aws/openbao/lineage
# owns it now; this stack only looks it up.
data "aws_kms_alias" "seal" {
  name = "alias/openbao-seal"
}
