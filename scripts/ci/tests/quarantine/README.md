# Quarantine

Suites that do not pass, kept here so they are impossible to mistake for coverage. `run.sh` globs
`test-*.sh` non-recursively, so nothing here runs.

## `test-flux-schema.sh`

**Why it is here:** it asserts against hardcoded bundle filenames that the render's naming scheme
has outgrown. It expects `.bundle/chart-observability-loggen.yaml`; the render produces
`chart-observability-base-loggen-observability-loggen.yaml` and
`chart-observability-aws-0-observability-loggen.yaml` — the scheme gained overlay and cluster
segments. The chartRef assertions are stale in the same way.

**What it is NOT:** it is not evidence of a gap in `validate-manifests.sh`. All six chartRef
HelmReleases it names are present in the rendered bundle — karpenter, envoy-gateway,
envoy-ai-gateway, atlas-operator, vllm-semantic-router, flux-operator. That was checked directly
before quarantining it.

**How it got here:** nothing ever ran it. Three mentions in `ci.yaml` and all three are comments.
`ci.yaml:406` called it a suite that "does not pass in a bare environment", which read as *needs
tooling* — it does not pass with the tooling either.

**To revive it:** match the bundle files by glob rather than by exact name, and assert a non-zero
match count so the repair cannot make the guard vacuous. Then move it back up one directory.
