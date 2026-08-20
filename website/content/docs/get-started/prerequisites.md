---
title: Prerequisites
weight: 10
description: Accounts, access, and tools needed before the first deploy.
lastVerified: 2026-08-20
---

Everything below is cloud-agnostic — the same list applies whichever cloud
lane you deploy next.

## Accounts and access

- **AWS account** with admin-level permissions (VPC, EKS, IAM, S3, Route53,
  Secrets Manager, KMS) and credentials configured locally (`~/.aws/credentials`
  or environment variables).
- **A registered domain** you can delegate to Route53 — OpenTofu creates a
  private hosted zone under it for internal service DNS.
- **GitHub account** — Flux needs a way to pull this repository: a personal
  access token or a GitHub App.
- **Tailscale account and API key** — provisions the subnet router that gives
  you private access to the cluster.

## Tools

This repository pins every CLI version it depends on in `mise.toml` — install
[mise](https://mise.jdx.dev/), then run:

```bash
mise install
```

That single command installs OpenTofu, Terramate, the Flux CLI, Helm,
Kustomize, and Trivy (the config scanner every `preview`/`deploy`/`drift
detect` script runs) at the exact versions this repository is built against.
`mise.toml` is the source of truth for those versions — check it directly
rather than trusting a number written in prose, here or anywhere else.

A few tools mise does **not** manage — install these separately:

- the AWS CLI, authenticated
- `kubectl`
- the OpenBao CLI (`bao`) — see [openbao.org](https://openbao.org/)
- `jq`
- the Tailscale client, to check `tailscale status` once Stage 1 is up

With accounts in place and tools installed, continue to
[AWS]({{< relref "/docs/get-started/aws/_index.md" >}}) — the only cloud
lane that is implemented today.
