---
title: Agents get GitHub tokens from a self-hosted octo-sts, scoped per repository and role, and a ruleset confines their App to agent branches
linkTitle: 0043 · GitHub credentials for agents
weight: 430
description: A run exchanges its projected ServiceAccount token at an in-cluster octo-sts, reached only through agent-router's JWT check pinned to this cluster's issuer, for an installation token of the agents' GitHub App, valid at most one hour, for one repository, with permissions set by the run's role in a trust policy stored in that repository. A branch ruleset lets that App write only refs/heads/agent/**, so it cannot merge. PATs, the ESO GitHub generator, the OpenBao GitHub plugin and a git proxy were rejected.
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

The run presents a token that lives until its deadline (R2), with audience `octo-sts/<owner>/<repo>/<role>`,
to agent-router's `sts` listener ([ADR-0042]({{< relref "/docs/decisions/0042-agent-router-identity-gateway.md" >}})).
The listener verifies it against this cluster's exact issuer and JWKS and routes `/sts/exchange` to
octo-sts. octo-sts checks it against `.github/chainguard/agent-<role>.sts.yaml` on the default branch
and returns an installation token with that policy's permissions.

**Pros**:
- Trust policies are files in the repository, on a gate path
- Resolves installations by account login, so a user-owned installation works
- Every exchange is recorded outside the sandbox. agent-router's `sts` access log holds the verified
  `sub` and time, and octo-sts logs the requested repository and trust policy. What the token then
  does is in GitHub's own record: the repository's activity and each PR's timeline, where every push,
  PR and comment is attributed to the App's bot, never to a human

**Cons**:
- The trust policies' issuer has two alternatives. gcp-0's GKE issuer is fixed by project, location
  and cluster name, so it is matched exactly. aws-0's EKS issuer changes on every rebuild, so it is
  matched by pattern (OD-5). That pattern alone accepts a token minted in any eu-west-3 EKS cluster, an attacker's included, with a ServiceAccount
  named like a run's. A prompt-injected sandbox that could reach octo-sts could present one. So
  octo-sts admits ingress only from agent-router's data plane, whose `sts` listener pins this cluster's
  issuer (Flux-substituted) and JWKS. The pattern is safe only behind that check (owner decision,
  2026-09-26)
- One more service in `agent-system`, and GitHub tokens depend on agent-router being up

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
`agent-branches` that confines every non-bypass actor to `refs/heads/agent/**`. The bypass list is
every human role that can push (admin, maintain, write), Renovate and the factory's App (OD-7). A
GitHub App is bypassed only when named, never through a role, so the agents' App is the one confined
actor, and collaborators and App Wizard pushes made with a user's token are not.

**Rationale**: Short-lived, per-repository, per-role tokens whose authorisation is reviewed in the
repository it grants.

---

## Consequences

### Positive

- A stolen implementer token can push to `agent/**` of one repository for ≤ 1 h; a reviewer's cannot
  push at all
- The App has no `workflows` permission, so no agent PR can change a workflow file. PR CI still runs
  repository scripts the agent can edit, without secrets, and `render-diff`'s `GITHUB_TOKEN` can write
  PR comments and labels

### Negative

- All runs share one App and the ruleset is `agent/**`-wide: a run can push another task's agent
  branch (R9). SP3's gate checks the head commit's `Agent-Run` trailer
- A copied octo-sts audience token verifies until `exp`, the run's deadline (R2)
- No record ties an installation token to a run. octo-sts 0.10.0 logs no subject or token hash: they
  are in its exchange event, which needs `METRICS=true` and a CloudEvents sink (`EVENT_INGRESS_URI`),
  and neither is set. A push is traced to its run by time against the `sts` access log and by the
  commit's `Agent-Run` trailer
- `contents: write` also lets the implementer create tags and releases and send `repository_dispatch`,
  which a branch ruleset does not cover. No workflow triggers on any of them today; one that does
  needs a tag ruleset first
- The App's private key is the strongest credential here: it mints implementer-level tokens for every
  installed repository without octo-sts's per-role scoping, and only the ruleset still bounds its
  pushes to `agent/**`. `openbao-platform` lets any namespace with ExternalSecret rights read it
  (design T14, fix deferred as O1)
- Dependabot is off on this repository (no `dependabot.yml`, security updates disabled, checked
  2026-09-26). Enabling it means adding its App to the bypass list, or its branches are refused
- The trust policies' EKS alternative is a pattern (any EKS cluster in eu-west-3, because aws-0's
  issuer ID changes on every rebuild); the GKE alternative is gcp-0's exact issuer. That is safe only behind this self-hosted octo-sts, whose only caller,
  agent-router's `sts` listener, has already verified the token against this cluster's issuer.
  Chainguard's hosted octo-sts App (`octo-sts`, app id 801323) reads the same
  `.github/chainguard/*.sts.yaml` files with no such check: installed on a repository that
  carries these policies, it would mint that repository's tokens for anyone with an eu-west-3
  EKS cluster. Confirm it is absent (github.com/settings/installations) before a repository opts in
- The ruleset's `update` rule covers `main` too, since that is what stops the App merging its own
  PR, so every human merge to `main` is a bypass that GitHub asks for explicitly: the "bypass
  rules" checkbox, or `gh pr merge --admin`. A plain merge is refused (seen on #2113). Branch
  protection still applies (`enforce_admins`), so the bypass waives only this ruleset. GitHub
  auto-merge is untested against it. Renovate is on the bypass list for the same reason

### Neutral

- A repository opts in three times, in this order: the ruleset, its trust policies, the App's
  installation. The ruleset comes first because `main` needs no approval, so until it exists nothing
  stops the implementer from merging its own green PR

---

## Implementation Notes

`security/base/octo-sts/` (its only route in is `httproute.yaml`, on agent-router's `sts` listener),
`.github/chainguard/agent-*.sts.yaml`, `.github/rulesets/agent-branches.json` applied by
`task ops:github:agent-branch-ruleset`. The App key is at `platform/agents/github-app`. octo-sts reads
it once at startup, so a rotated key needs `kubectl rollout restart deploy/octo-sts -n agent-system`.

---

## References

- [octo-sts/app](https://github.com/octo-sts/app)
- [GitHub rulesets REST API](https://docs.github.com/en/rest/repos/rules)
- [Choosing permissions for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
