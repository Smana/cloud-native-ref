# Shared AWS-GCP DNS federation — destroy guard.
#
# Only `destroy` is overridden here. deploy / preview / drift detect all inherit
# the global scripts at opentofu/workflows.tm.hcl unchanged, because there is
# nothing dangerous about applying this stack.
#
# WHY THE GUARD
#
# This stack is the ONLY place cert-manager and external-dns-public on gcp-0
# authenticate to Route53 -- an AWS IAM OIDC provider trusting the GKE cluster's
# issuer, plus the role it federates to (see main.tf). Destroying it does not
# fail anything immediately: already-issued certificates keep serving and
# already-published DNS records keep resolving. It breaks the NEXT thing that
# needs the role -- the next ACME renewal or the next record change -- with an
# STS token-validation error that surfaces in cert-manager's logs as a generic
# auth failure. That gap between cause and symptom is what the guard is for.
#
# This stack is deliberately NOT tagged `opt-in` (unlike the GCP stacks): the
# OIDC issuer URL is derived, not read from a live cluster (see stack.tm.hcl),
# so there is nothing to wait for and no reason to skip it by default. The
# hazard is asymmetric -- harmless to apply, silently harmful to destroy while
# gcp-0 is live -- so, same as opentofu/shared/tailscale, the guard sits on
# destroy alone.
#
# Usage:
#   terramate script run --reverse destroy                          # skipped here
#   TM_FEDERATION_DESTROY=true terramate script run destroy         # actually runs
#
# The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
# the literal `${...}` must reach bash. `${global.provisioner}` and
# `${terramate.root...}` are intentional (Terramate-evaluated).

script "destroy" {
  name        = "Shared AWS-GCP DNS Federation Destroy (guarded)"
  description = "Destroy the OIDC provider and role. Requires TM_FEDERATION_DESTROY=true: gcp-0's cert-manager and external-dns-public depend on it"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_FEDERATION_DESTROY:-}" != "true" ]; then
          echo "[skip] shared/aws-gcp-federation destroy: this stack is what lets"
          echo "       cert-manager and external-dns-public on gcp-0 manage public"
          echo "       DNS records and certificates with no static credentials."
          echo "       Destroying it breaks the next ACME renewal and the next DNS"
          echo "       record change on gcp-0 -- silently, until something needs it."
          echo "       Set TM_FEDERATION_DESTROY=true if that is genuinely what you want."
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
