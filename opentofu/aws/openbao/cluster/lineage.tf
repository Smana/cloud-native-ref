# The seal key is lineage state, not cluster state. It used to be created here
# (kms.tf) and destroyed with the stack, which made every snapshot from the
# previous lineage unreadable by the next cluster. opentofu/aws/openbao/lineage
# owns it now; this stack only looks it up.
#
# A data source rather than a remote-state read, deliberately: this stack then
# needs no read access to the lineage stack's state, and survives that state
# moving. The cost is that `tofu plan` here FAILS until the lineage stack has
# been applied, with a not-found error naming the alias but not the stack that
# owns it -- the `after` edge in stack.tm.hcl only orders a full
# `terramate script run`. If you are running tofu directly and see that error,
# apply opentofu/aws/openbao/lineage first.
data "aws_kms_alias" "seal" {
  name = var.seal_key_alias
}
