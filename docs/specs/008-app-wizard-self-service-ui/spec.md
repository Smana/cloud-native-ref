# Spec: App Wizard — schema-driven self-service UI that opens GitOps PRs

**ID**: SPEC-008
**Issue**: N/A <!-- pending — create with `gh issue create --title "[SPEC] App Wizard self-service UI" --label "spec,spec:draft"` and replace this line -->
**Status**: draft
**Type**: platform
**Created**: 2026-07-14
**Last updated**: 2026-07-14

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md). This is a **phased spec** ([PHASED.md](../PHASED.md)) — see the phase map in plan.md.

---

## Summary

A small, user-friendly web UI ("App Wizard") where a developer declares an application through a progressively-disclosed form — or a plain-language description — and gets a reviewable pull request in this repo under `apps/<stack>/<app_name>/`. The form is **generated from the App XRD** (single source of truth, zero drift), the PR is opened **as the developer** (GitHub OAuth), and optional LLM assists accelerate input without ever bypassing validation. Flux remains the only actor that touches clusters; the wizard's blast radius is one Git repo.

---

## Problem

Declaring an App today requires knowing: the claim schema (~40 top-level fields after SPEC-007), the repo layout (`apps/base/<name>/` + kustomization + parent registration), the ExternalSecret conventions, and the CiliumNetworkPolicy traps. The `docs/apps-user-guide.md` lowers the reading burden but still ends in hand-written YAML and a hand-assembled PR. Consequences:

- **First-app friction**: a new developer's first deployment is a copy-paste-from-example exercise with three classic failure modes: forgetting the parent kustomization entry, pasting a secret value into Git, and mistyping a field the cluster rejects post-merge.
- **Day-2 friction**: even a tag bump means locating the right file and hand-editing YAML.
- **Review burden**: platform reviewers read raw claims instead of outcomes ("what will this actually create?").

An Internal Developer Portal (Backstage/Port) solves this generically at the cost of adopting a portal. This platform is a reference implementation — demonstrating a lightweight, schema-driven alternative end-to-end is itself the point (CL-1).

---

## User Stories

### US-1: Declare a new app without writing YAML (Priority: P1)

As an **application developer**, I want to fill a short form (image, name, stack, how it's exposed) and get a PR, so that my first deployment doesn't require learning the claim schema or repo layout.

**Acceptance Scenarios**:
1. **Given** the basic form filled with a valid image/name/stack/route, **When** I click "Open PR", **Then** a PR is created from a branch under my GitHub identity containing `apps/<stack>/<app_name>/app.yaml`, `kustomization.yaml`, and the parent kustomization registration, and the PR body describes the app.
2. **Given** an input violating a schema or CEL rule (e.g. cron without schedule), **When** I type it, **Then** the form shows the rule's message inline before submission — the same message the API server would produce.
3. **Given** an app name that already exists in the chosen stack, **When** I submit, **Then** the wizard refuses with a link to the existing app's edit view.

### US-2: Progressive disclosure — simple by default, complete when needed (Priority: P1)

As a **developer**, I want the first screen to show only essential fields, with databases/autoscaling/policies one expansion away, so that the simple case takes under a minute while every XRD capability remains reachable.

**Acceptance Scenarios**:
1. **Given** the create form, **When** it loads, **Then** at most 8 inputs are visible (name, stack, description, workload type, image, port/route or schedule) and all other XRD fields are grouped under expandable advanced sections.
2. **Given** a NEW field added to the App XRD, **When** the wizard next syncs the schema, **Then** the field appears in the advanced tier with its schema description as help text, with **no wizard code change**.

### US-3: The PR is reviewable by outcomes (Priority: P1)

As a **platform reviewer**, I want the PR to show what the claim will actually create, so that I review outcomes, not 40 lines of claim YAML.

**Acceptance Scenarios**:
1. **Given** a wizard-created PR, **When** it opens, **Then** a comment lists the rendered resources (kinds + names, e.g. Deployment/Service/HTTPRoute/PVC) produced by `crossplane render` of the claim.
2. **Given** a claim that fails render or kubeconform, **When** the developer clicks "Open PR", **Then** no PR is created and the error is shown in the wizard.

### US-4: Edit and decommission existing apps (Priority: P2)

As a **developer**, I want to load my existing app into the same form, change a field (tag bump, env var), or retire the app entirely, so that day-2 operations don't fall back to raw YAML.

**Acceptance Scenarios**:
1. **Given** an app created by the wizard, **When** I load it, edit the image tag, and submit, **Then** the PR diff touches only the changed lines (comments and unknown fields preserved).
2. **Given** an app whose `app.yaml` contains fields the form doesn't render (newer schema or hand additions), **When** I load it, **Then** those fields are shown read-only as "managed in YAML" and survive the round-trip unchanged.
3. **Given** an existing app, **When** I choose "Decommission", **Then** a removal PR is opened deleting the app directory and its parent-kustomization entry.

### US-5: Plain-language assists (Priority: P3)

As a **developer**, I want to describe my app in a sentence and get a prefilled form, and describe my app's dependencies and get suggested network policies, so that the blank-form and the hardest-field problems are both softened.

**Acceptance Scenarios**:
1. **Given** "a Python API on port 8000 with a small postgres, private access", **When** I click "Prefill", **Then** the form is populated with schema-valid values, each AI-set field visibly badged, and nothing is submitted automatically.
2. **Given** "my app calls stripe.com and the payments database", **When** I ask for policy suggestions, **Then** candidate Cilium rules (including the mandatory kube-dns L7 DNS rule) appear in the policy editor for review.
3. **Given** the LLM backend is unreachable, **When** I use the wizard, **Then** everything except the two assist buttons works normally.

### US-6: Secrets never transit the wizard (Priority: P1)

As a **security engineer**, I want the wizard to be incapable of committing a secret value, so that self-service doesn't become the new secret-leak vector.

**Acceptance Scenarios**:
1. **Given** the env/secrets section, **When** I use it, **Then** the only options are ExternalSecret references (AWS Secrets Manager paths) and non-sensitive literals — there is no "secret value" input.
2. **Given** a submitted claim containing a string matching secret heuristics (high-entropy token, `AKIA…`, PEM header), **When** I click "Open PR", **Then** the wizard refuses with an explanation pointing to the ExternalSecret flow.

---

## Requirements

### Functional

- **FR-001**: The wizard MUST generate its form from the App XRD's `openAPIV3Schema` read from the Git repo (not the cluster): field types, enums, defaults, min/max, patterns, and descriptions all derive from the schema.
- **FR-002**: The XRD's CEL `x-kubernetes-validations` MUST be evaluated client-side (or server-side with inline feedback) before submission, surfacing the same messages the API server would.
- **FR-003**: A hand-maintained `ui-hints.yaml` MUST control only presentation: tier (basic/advanced/expert), grouping, ordering, labels, examples. Unknown-to-hints fields default to the advanced tier — never hidden.
- **FR-004**: The wizard MUST authenticate developers via GitHub OAuth and create branch, commits, and PR **with the user's token**; the wizard holds no long-lived Git credentials and no cluster credentials.
- **FR-005**: A create PR MUST contain `apps/<stack>/<app_name>/app.yaml`, `apps/<stack>/<app_name>/kustomization.yaml`, and the parent kustomization registration; a decommission PR MUST remove all three.
- **FR-006**: Stacks MUST come from a platform-owned registry file (`apps/stacks.yaml`: name, description, namespace, owning team) rendered as a dropdown; the wizard MUST NOT create stacks.
- **FR-007**: Before opening any PR the backend MUST run: schema validation, CEL evaluation, `crossplane render`, and kubeconform; any failure blocks the PR with the error surfaced in the UI.
- **FR-008**: After opening a PR the wizard MUST post a comment listing the rendered resources (kind, name, one-line role) from `crossplane render`.
- **FR-009**: Edit mode MUST use a structure-preserving YAML round-trip (comments and unknown fields intact) and show un-renderable fields as read-only "managed in YAML".
- **FR-010**: The wizard MUST NOT accept secret values: no secret-value inputs, plus server-side entropy/pattern scanning that refuses PRs containing candidate secrets.
- **FR-011**: LLM assists (describe-to-prefill; network-policy suggester) MUST produce output constrained by the XRD-derived JSON schema, badge AI-set fields, never auto-submit, and degrade gracefully when the LLM endpoint is down. The policy suggester prompt MUST encode the known Cilium traps (kube-dns L7 rule required for toFQDNs; matchPattern single-segment globs).
- **FR-012**: A live YAML pane MUST always show the claim being generated; an "eject to YAML" affordance lets the user leave the form without losing work.
- **FR-013**: The wizard MUST be deployed on the platform as an App claim (`type: web`, private Tailscale route), with CiliumNetworkPolicy, ExternalSecrets for its OAuth app credentials, and restricted-PSS compliance — the same rules it helps others follow.
- **FR-014**: Git operations MUST go through a provider-agnostic interface (single GitHub implementation in v1) so the GitHub coupling is a seam, not an architecture.

### Non-Goals

- Not a portal: no service catalog, no docs hub, no scorecard.
- No cluster access: no live status, no kubectl-style views (link out to Headlamp/Grafana instead).
- No apply path other than Flux; the wizard cannot deploy anything directly.
- No conversational/chat-first UX (CL-4).
- No stack lifecycle management (creating stacks stays a hand-written, platform-reviewed PR).
- No multi-repo / multi-cluster targeting in v1.
- No preview-environment triggering in v1 (composition supports it; wizard integration deferred).

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with evidence.

- **SC-001**: A user with only a GitHub account and an image reference produces a mergeable PR (all repo CI checks green) from the basic form in under 5 minutes, without editing YAML by hand.
- **SC-002**: Adding a scalar test field to the App XRD and re-syncing the wizard makes the field appear in the advanced tier with its description — with zero changes to wizard source code (only the XRD file).
- **SC-003**: Every CEL rule on the App XRD, when violated in the form, produces its message in the UI before submission; submitting each violation via the API directly is rejected with the same message (sampled: cron-without-schedule, route-on-worker, RWO-persistence+autoscaling).
- **SC-004**: A wizard PR for an app with route + persistence + database carries an automated comment listing exactly the resource kinds `crossplane render` produces for that claim.
- **SC-005**: Round-trip fidelity: loading `apps/base/openwebui/app.yaml` (hand-written, commented) into edit mode and submitting a single tag change yields a PR diff touching only the tag line.
- **SC-006**: Secret guardrail: submitting a claim with an `env` value matching an AWS access key pattern is refused server-side with a message referencing the ExternalSecret flow; no branch or PR is created.
- **SC-007**: LLM prefill given the US-5 sentence yields a claim that passes schema+CEL validation without manual correction in ≥8/10 attempts (evaluated against a fixed prompt set); with the LLM endpoint stopped, form submission still works end-to-end.
- **SC-008**: The wizard itself runs on the cluster as an App claim: `kubectl get app app-wizard` shows `Synced=True, Ready=True`, reachable via its private Tailscale hostname, Polaris score ≥ 85 on its rendered resources.

---

## Open questions

- CL-1 — Build a custom lightweight UI (vs Backstage / GitHub Issue Forms / Headlamp plugin)
- CL-2 — Form generated from XRD + ui-hints overlay (vs hand-crafted)
- CL-3 — PRs authored with the user's GitHub identity via OAuth
- CL-4 — LLM scope v1: describe-to-prefill + network-policy suggester, optional layer
- CL-5 — Day-2 in scope: create + edit + decommission
- CL-6 — Stack = registry entry (namespace + owning team), platform-owned dropdown
- [ ] [NEEDS CLARIFICATION: Frontend stack — React+shadcn vs Preact/htmx-style minimal? Affects bundle/maintenance, not behavior. Decide at plan time.]
- [ ] [NEEDS CLARIFICATION: Where does `crossplane render` run in the backend — embedded function runtime, sidecar container with docker-less runner, or pre-rendered via CI on a draft branch? Security/latency trade-off.]
- [ ] [NEEDS CLARIFICATION: GitHub OAuth app registration — org-level app or personal? Determines who can log in.]

---

## References

- Plan: [plan.md](plan.md) — design, phase map, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Related spec: [SPEC-007 App workload types](../007-app-composition-workload-types/spec.md) — the schema this wizard renders
- User guide the wizard complements: [docs/apps-user-guide.md](../../apps-user-guide.md)
