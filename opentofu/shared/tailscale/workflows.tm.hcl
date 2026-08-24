# Shared Tailscale — destroy guard.
#
# Only `destroy` is overridden here. deploy / preview / drift detect all inherit
# the global scripts at opentofu/workflows.tm.hcl unchanged, because there is
# nothing dangerous about applying this stack.
#
# WHY THE GUARD
#
# Everything this stack owns is TAILNET-WIDE, not cloud-scoped: the ACL, the DNS
# nameservers and the DNS search paths are one object per tailnet, shared by both
# clouds. Destroying it therefore removes tailnet access control for AWS *and*
# GCP at once -- including the autoApprovers that authorise every subnet router's
# routes, and the search paths that make priv.aws / priv.gcp resolve at all.
#
# The stack is deliberately NOT tagged `opt-in`. That tag means "skipped unless
# asked for", which is wrong here -- both network stacks declare `after` on this
# one and it must always deploy. The hazard is asymmetric: harmless to apply,
# tailnet-wide to destroy. So the guard sits on destroy alone.
#
# Without it, `terramate script run --reverse destroy` from opentofu/ tears this
# down as just another stack in the sweep. Someone tearing down ONE cloud loses
# tailnet access for the other, and the failure looks like a routing problem
# rather than a policy one -- routes stay advertised but unapproved.
#
# Usage:
#   terramate script run --reverse destroy                       # skipped here
#   TM_TAILNET_DESTROY=true terramate script run destroy         # actually runs
#
# The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
# the literal `${...}` must reach bash. `${global.provisioner}` and
# `${terramate.root...}` are intentional (Terramate-evaluated).

script "destroy" {
  name        = "Shared Tailscale Destroy (guarded)"
  description = "Destroy the tailnet-wide singletons. Requires TM_TAILNET_DESTROY=true: this affects BOTH clouds"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_TAILNET_DESTROY:-}" != "true" ]; then
          echo "[skip] shared/tailscale destroy: this stack owns the tailnet-wide ACL,"
          echo "       DNS nameservers and search paths, shared by BOTH clouds."
          echo "       Destroying it removes tailnet access control for AWS and GCP."
          echo "       Set TM_TAILNET_DESTROY=true if that is genuinely what you want."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        # `destroy` is a standalone entrypoint: unlike `deploy` it can be the first
        # tofu command run in a stack, so it has to init itself.
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
