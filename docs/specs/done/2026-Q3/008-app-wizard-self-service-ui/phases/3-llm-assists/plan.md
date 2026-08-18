# Phase 3: LLM assists — prefill and policy suggester

**Parent**: [SPEC-008 plan](../../plan.md) · **Depends on**: 1-create-flow · **Acceptance**: SC-007

## Phase design

Two bounded, optional assists (CL-4): describe-to-prefill (structured output constrained by the XRD-derived JSON schema; AI-badged fields; never auto-submits) and network-policy suggester (prompt encodes the Cilium traps from `.claude/rules/cilium-network-policies.md`: kube-dns L7 rule for toFQDNs, matchPattern single-segment globs). Backend routes to the platform AI Gateway when the LLM stack is enabled, Claude API as fallback; both behind one `assist` interface. UI degrades gracefully when the endpoint is down (FR-011).

## Tasks

- [ ] **T301**: `assist` backend interface + AI Gateway / Claude API implementations; ExternalSecret for the API key.
- [ ] **T302**: Describe-to-prefill: prompt + JSON-schema-constrained decoding; AI-badge UX; never-auto-submit guard.
- [ ] **T303**: Policy suggester: dependency-description → candidate Cilium rules incl. mandatory DNS L7 rule; renders into the policy editor for review.
- [ ] **T304**: Prompt eval harness: fixed prompt set, ≥8/10 schema+CEL-valid prefills (SC-007); degraded-mode E2E (endpoint stopped → form still works).
