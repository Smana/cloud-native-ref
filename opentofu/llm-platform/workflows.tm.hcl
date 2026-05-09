# LLM Platform — opt-in Terramate scripts.
#
# Why override the global scripts (opentofu/workflows.tm.hcl)?
#   The LLM platform is unique to the wip/self-hosted-llm-platform-draft
#   branch and provisions AWS resources (S3 Files filesystem, mount
#   targets, IAM) that aren't part of the default platform. We want
#   `terramate script run deploy` from the opentofu/ root to remain a
#   safe one-shot for the standard cluster — i.e. this stack must
#   default to a no-op.
#
# How does the gate work?
#   Each script is overridden with a single guarded bash command.
#   - $TM_LLM_PLATFORM_ENABLED unset or != "true" → echo [skip] + exit 0
#     (treated as success so sibling stacks are not affected).
#   - $TM_LLM_PLATFORM_ENABLED == "true"          → run the same plan/
#     apply/destroy sequence the global scripts would have run.
#
#   The double-`$$` escape is required to keep Terramate from
#   interpolating the `${VAR:-default}` syntax — the literal `${...}`
#   needs to reach bash. The `${global.provisioner}` interpolations are
#   intentional (Terramate-evaluated → "tofu").
#
# Usage:
#   # default (skipped):
#   terramate script run deploy
#
#   # opt-in for a single invocation:
#   TM_LLM_PLATFORM_ENABLED=true terramate script run deploy
#
#   # target only this stack:
#   TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/llm-platform script run deploy
#
#   # CI: skip entirely via tag (no env var needed):
#   terramate script run --no-tags=opt-in deploy
#
# Trade-off: the override loses Terramate Cloud sync metadata
# (sync_preview, sync_deployment) because those are command-level
# annotations that don't compose with a single bash heredoc. Acceptable
# for an opt-in/branch-local stack; the standard stacks keep cloud sync
# via the global workflows.

script "deploy" {
  name        = "LLM Platform Deployment (opt-in)"
  description = "Deploy LLM platform (S3 Files + IAM); gated by TM_LLM_PLATFORM_ENABLED=true"

  job {
    name        = "guarded-deploy"
    description = "Run init/validate/plan/apply iff TM_LLM_PLATFORM_ENABLED=true"
    commands = [
      ["bash", "-c", <<-SCRIPT
        if [ "$${TM_LLM_PLATFORM_ENABLED:-false}" != "true" ]; then
          echo "[skip] opentofu/llm-platform: opt-in by setting TM_LLM_PLATFORM_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} plan -out=out.tfplan -lock=false -var-file=variables.tfvars
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars
      SCRIPT
      ],
    ]
  }
}

script "preview" {
  name        = "LLM Platform Preview (opt-in)"
  description = "Preview LLM platform changes; gated by TM_LLM_PLATFORM_ENABLED=true"

  job {
    name        = "guarded-preview"
    description = "Run validate/plan iff TM_LLM_PLATFORM_ENABLED=true"
    commands = [
      ["bash", "-c", <<-SCRIPT
        if [ "$${TM_LLM_PLATFORM_ENABLED:-false}" != "true" ]; then
          echo "[skip] opentofu/llm-platform: opt-in by setting TM_LLM_PLATFORM_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} plan -out=out.tfplan -detailed-exitcode -lock=false -var-file=variables.tfvars
      SCRIPT
      ],
    ]
  }
}

script "drift" "detect" {
  name        = "LLM Platform Drift Check (opt-in)"
  description = "Detect drift; gated by TM_LLM_PLATFORM_ENABLED=true"

  job {
    name        = "guarded-drift-detect"
    description = "Run plan -detailed-exitcode iff TM_LLM_PLATFORM_ENABLED=true"
    commands = [
      ["bash", "-c", <<-SCRIPT
        if [ "$${TM_LLM_PLATFORM_ENABLED:-false}" != "true" ]; then
          echo "[skip] opentofu/llm-platform: opt-in by setting TM_LLM_PLATFORM_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} plan -out=out.tfplan -detailed-exitcode -lock=false -var-file=variables.tfvars
      SCRIPT
      ],
    ]
  }
}

script "destroy" {
  name        = "LLM Platform Destroy (opt-in)"
  description = "Destroy LLM platform; gated by TM_LLM_PLATFORM_ENABLED=true"

  job {
    name        = "guarded-destroy"
    description = "Run destroy iff TM_LLM_PLATFORM_ENABLED=true"
    # The opt-in gate runs FIRST so opt-out invocations don't even
    # invoke the y/n prompt — otherwise users get prompted to destroy
    # a stack that's about to no-op, which is just confusing. Inside
    # the gate we still call terramate-destroy-confirm.sh (cached for
    # 10 min so a `--reverse destroy` across N stacks asks once).
    commands = [
      ["bash", "-c", <<-SCRIPT
        if [ "$${TM_LLM_PLATFORM_ENABLED:-false}" != "true" ]; then
          echo "[skip] opentofu/llm-platform: opt-in by setting TM_LLM_PLATFORM_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      SCRIPT
      ],
    ]
  }
}
