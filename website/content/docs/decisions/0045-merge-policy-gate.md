---
title: "ADR-0045: palantir/policy-bot, required through a repository ruleset, decides which agent PRs merge"
linkTitle: "0045 Merge policy gate"
weight: 45
description: Agent PRs in a live low-risk class auto-merge only when policy-bot, reading .policy.yml from main, posts success from its own App; everything else needs a maintainer, and gate paths are unmergeable.
lastVerified: 2026-09-27
---

**Status**: Accepted
**Date**: 2026-09-27
**Deciders**: Smana
**Related Spec**: [SP3 dark factory §5](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-dark-factory-design.md#5-merge-policy-gate-d4)

---

## Context

`main` requires 0 approving reviews (a solo maintainer cannot approve his own PRs), so nothing in
GitHub stops an agent PR from merging once CI is green. D4 lets policy-defined low-risk classes
merge on their own and requires a human for the rest. That boundary must be enforced at merge time,
by code the agents cannot change, and must fail towards more review.

---

## Decision Drivers

- Merge authority read from `main`, never from the PR under evaluation
- Path, size, author, contributor and branch predicates; "no rule matched" must block
- Review invalidation on push and forged statuses already handled
- A cluster torn down routinely must not block every merge

---

## Considered Options

### Option 1: policy-bot, its status required by a ruleset with policy-bot's App as expected source

**Pros**:
- Reads the policy from the target branch; every predicate the classes need; `error` when all rules skip
- The expected source makes the status unforgeable by `statuses: write`; a ruleset bypass keeps
  the owner and Renovate working when policy-bot is down

**Cons**:
- A public webhook; the check is absent while the cluster is down

### Option 2: Required reviews, or rulesets with CODEOWNERS alone

**Pros**:
- Native

**Cons**:
- A solo maintainer cannot approve his own PRs; no size, author or contributor predicates; no
  fail-closed "unmatched"

### Option 3: A custom Actions check, Prow/tide, Mergify or Kodiak

**Pros**:
- Anything we write; rich SaaS rules; label-driven automation

**Cons**:
- Re-implements invalidation and forgery handling; a whole Prow; SaaS-first (D2); Kodiak has no
  path predicates and its label auto-approve is the labels-as-trust trap

---

## Decision Outcome

**Chosen option**: "Option 1"

**Rationale**: policy-bot is the only maintained OSS engine that evaluates the policy from the
target branch with every predicate the classes need, and a ruleset with an expected source makes
its status the unforgeable input GitHub's native auto-merge waits for.

---

## Consequences

### Positive

- An agent PR touching a gate path shows `error` and cannot merge, even with an approval
- Every control fails towards more human review

### Negative

- policy-bot holds `statuses: write` and is the most sensitive component: its own namespace,
  store and default-deny policy, a digest-pinned image, HMAC webhooks
- While the cluster is down, agent PRs wait; the owner and Renovate bypass
- Arming and reverts need a second App, `ogenki-agent-merger`, the only App that bypasses the
  `agent-merge` ruleset on `main` and the revert branches; its key, held by the factory alone, is
  the one that can merge. The factory's own App stays comment-and-label only

### Neutral

- Classes are promoted from shadow to live only by a human-authored PR, on evidence

---

## Implementation Notes

`tooling/base/policy-bot/` (namespace `merge-gate`), `.policy.yml`, `.github/rulesets/agent-merge-gate.json`
applied by `scripts/ops/github/agent-merge-gate-ruleset.sh`, `.github/rulesets/agent-merge.json` applied by
`scripts/ops/github/agent-merge-ruleset.sh`, `scripts/ci/check-policy-gate-coverage.sh`.

---

## References

- [palantir/policy-bot](https://github.com/palantir/policy-bot)
- [SP3 research, merge gate](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-dark-factory-research.md#merge-gate)
- [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
