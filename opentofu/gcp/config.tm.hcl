# GCP-wide Terramate globals.
#
# `gcp_gate` is the opt-in guard, defined once and interpolated into every GCP
# script override as `${global.gcp_gate}`.
#
# It exists because each Terramate job is its own bash process, so the check
# cannot be hoisted to the script or stack level -- it has to appear in every
# job. Written out by hand that is fifteen near-identical copies across three
# files, which is how four scripts came to be MISSING one: `init`,
# `drift detect`, `drift reconcile` and `opentofu render` had no override at all
# and ran ungated on GCP.
#
# `drift reconcile` is the one that made this urgent: the global version runs
# `tofu apply -auto-approve`, so an ungated drift reconcile from opentofu/ would
# BUILD GCP infrastructure without anyone opting in.
#
# The `$${...}` escape is load-bearing: Terramate resolves it to `${...}` when it
# evaluates this global, so the literal `${TM_GCP_ENABLED:-}` is what reaches
# bash. Writing `${...}` here instead would have Terramate try to resolve
# TM_GCP_ENABLED as a Terramate value and fail at parse time.
#
# The message is deliberately generic. A per-script message would mean this
# could not be shared -- and a shared gate that is always present beats a
# bespoke message on the gates someone remembered to write.
globals {
  gcp_gate = <<-EOT
    if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
      echo "[skip] GCP stack: set TM_GCP_ENABLED=true to run this against GCP."
      exit 0
    fi
  EOT
}
