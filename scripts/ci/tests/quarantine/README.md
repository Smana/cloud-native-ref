# Quarantine

Suites that do not pass, kept here so they are impossible to mistake for coverage. Nothing here
runs: `run.sh` discovers `test-*.sh` only at the top level of `tests/` (it looks one level down
only for `test-*.py`), and every suite here is `.sh`.

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

**How it got here:** nothing ever ran it. The old `ci.yaml` mentioned it three times, all in
comments, one calling it a suite that "does not pass in a bare environment", which read as *needs
tooling* — it does not pass with the tooling either.

**To revive it:** match the bundle files by glob rather than by exact name, and assert a non-zero
match count so the repair cannot make the guard vacuous. Then move it up to `tests/` and correct its
`REPO_ROOT` depth from `/../../../..` to `/../../..`.
