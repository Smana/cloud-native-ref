---
title: Agents get GitHub tokens from a self-hosted octo-sts, scoped per repository and role, and a ruleset confines their App to agent branches
linkTitle: 0043 · GitHub credentials for agents
weight: 430
description: A run exchanges its projected ServiceAccount token at an in-cluster octo-sts for an installation token of the agents' GitHub App, valid at most one hour, for one repository, with permissions set by the run's role in a trust policy stored in that repository. A branch ruleset lets that App write only refs/heads/agent/**, so it cannot merge. PATs, the ESO GitHub generator, the OpenBao GitHub plugin and a git proxy were rejected.
lastVerified: 2026-09-26
---

**Status**: Accepted
**Date**: 2026-09-26
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP1 — Agent runtime & identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md)

---

## Context

An implementer run pushes one branch and opens one PR; reviewer, tester and triager runs must never
write (C6). `main` requires zero approving reviews (programme D4), so nothing but policy stops a
token that can push to `main` from merging. Tokens must be short-lived, scoped to the run's repository,
and never a human's.

---

## Decision Drivers

- ≤ 1 h tokens, one repository, permissions by role
- Authorisation that lives in the target repository and is reviewed like code
- No long-lived credential in the sandbox
- Works for the user-owned `Smana` account

---

## Considered Options

### Option 1: Self-hosted octo-sts with the agents' GitHub App

The run presents a token that lives until its deadline (R2), with audience `octo-sts/<owner>/<repo>/<role>`; octo-sts checks it
against `.github/chainguard/agent-<role>.sts.yaml` on the default branch and returns an installation
token with that policy's permissions.

**Pros**:
- Trust policies are files in the repository, on a gate path
- Resolves installations by account login, so a user-owned installation works
- Records issuer, subject and the token's SHA-256 on every exchange

**Cons**:
- The EKS issuer changes on every rebuild, so policies match it by pattern (OD-5). That is safe only
  because octo-sts is not publicly reachable: a ClusterIP Service whose CNP admits only `agents` pods
- One more service in `agent-system`

### Option 2: Personal access tokens

**Cons**:
- A human's credential, long-lived, not scoped per run (D3)

### Option 3: External Secrets GitHub generator, or the OpenBao GitHub plugin

**Cons**:
- The token lands in a Kubernetes Secret or needs the run to authenticate to OpenBao; permissions are
  set in cluster config, not in the repository

### Option 4: A git proxy holding the credential

**Cons**:
- A programme non-goal: the target repositories are public, and a proxy is a new component to build

---

## Decision Outcome

**Chosen option**: "Self-hosted octo-sts with the agents' GitHub App", plus a branch ruleset
`agent-branches` that confines every non-bypass actor to `refs/heads/agent/**`, with the owner, Renovate
and the factory's App on the bypass list (OD-7).

**Rationale**: Short-lived, per-repository, per-role tokens whose authorisation is reviewed in the
repository it grants.

---

## Consequences

### Positive

- A stolen implementer token can push to `agent/**` of one repository for ≤ 1 h; a reviewer's cannot
  push at all
- The App has no `workflows` permission, so no agent PR can rewrite CI

### Negative

- All runs share one App and the ruleset is `agent/**`-wide: a run can push another task's agent
  branch (R9). SP3's gate checks the head commit's `Agent-Run` trailer
- A copied octo-sts audience token verifies until `exp`, the run's deadline (R2)

### Neutral

- A repository opts in twice: its trust policies, and the App's installation

---

## Implementation Notes

`security/base/octo-sts/`, `.github/chainguard/agent-*.sts.yaml`, `.github/rulesets/agent-branches.json`
applied by `task ops:github:agent-branch-ruleset`. The App key is at `platform/agents/github-app`.

---

## References

- [octo-sts/app](https://github.com/octo-sts/app)
- [GitHub rulesets REST API](https://docs.github.com/en/rest/repos/rules)
- [Choosing permissions for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
