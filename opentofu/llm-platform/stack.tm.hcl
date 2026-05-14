stack {
  name        = "LLM Platform"
  description = "S3 Files filesystem + IAM for self-hosted LLM model weights (Phase 4b — interim until Crossplane Upbound provider-upjet-aws v2.6+ ships s3files CRDs)"
  id          = "0a3f6f50-c6e7-4f2a-9b1c-d33ad4ba3a93"

  after = [
    "/opentofu/eks/init",
  ]

  tags = [
    "aws",
    "llm-platform",
    "s3files",
    # `opt-in` lets `terramate script run --no-tags=opt-in deploy` skip
    # this stack entirely (CI/audit path). The script overrides in
    # workflows.tm.hcl additionally guard on $TM_LLM_PLATFORM_ENABLED so
    # `terramate script run deploy` from the opentofu/ root is also safe
    # by default — the script runs but no-ops with a [skip] message.
    "opt-in",
  ]
}
