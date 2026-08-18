# Disabled workflow templates

GitHub Actions only executes files under `.github/workflows/`. Anything here is inert.

These two workflows are kept as **templates**, not pipeline stages — their bodies are fully
commented out and were never enabled:

| File | What it would do |
|------|------------------|
| `terramate-preview.yaml` | `terramate script run preview` — OpenTofu plan preview on PRs |
| `terramate-drift-detection.yaml` | `terramate script run drift detect` — scheduled drift detection |

They lived in `.github/workflows/` until 2026-08-18. A workflow file whose every line is a
comment has no valid `name`, `on` or `jobs` key, so GitHub queued it on each push, failed to
parse it, and recorded a failed run — permanent red on every branch, for two workflows that do
nothing. Moving them here stops that without discarding the reference material.

To re-enable one: move it back into `.github/workflows/`, uncomment it, and supply the secrets
it expects (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `TAILSCALE_AUTH_KEY`,
`TAILSCALE_API_KEY`).
