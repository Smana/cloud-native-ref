---
title: An OpenTelemetry Collector is the agent trace gate
linkTitle: 0051 · OTel Collector as the agent trace gate
weight: 510
description: Agent runs send spans to an OpenTelemetry Collector outside the sandbox. It stamps the run id from the sending pod's label and keeps only an allowlist of metadata attributes before VictoriaTraces, because the OpenHands SDK records prompts and tool output and cannot be configured not to.
lastVerified: 2026-09-27
---

**Status**: Accepted
**Date**: 2026-09-27
**Deciders**: Smana (Platform Owner)
**Related Spec**: `docs/superpowers/specs/2026-09-27-agent-observability-design.md`

---

## Context

The owner decided that agent traces carry metadata only: timing, model, token counts, tool names,
status and errors. The OpenHands SDK's Laminar instrumentation (lmnr 0.7.60) records prompts,
completions and tool input and output as span attributes, and lmnr hardcodes content tracing on. A
compromised run can also POST any span it likes. SPEC-006 (CL-1) declined a collector for the AI
gateway's traces, so this reverses that stance for agent traces.

---

## Decision Drivers

- The control must sit outside the sandbox.
- The run id must come from something a run cannot forge.
- Envoy Gateway 1.9 exports OTLP/gRPC only, and VictoriaTraces ingests OTLP/HTTP.
- As few new moving parts as the control allows.

---

## Considered Options

### Option 1: OpenTelemetry Collector (k8s distribution) in `observability`

**Pros**:
- `redaction` is an allowlist that fails closed, over resource, span and event attributes;
- `k8s_attributes` stamps the run id from the connection's pod;
- it takes both OTLP/HTTP and OTLP/gRPC.

**Cons**: one more Deployment and chart to keep current.

### Option 2: Filter in the harness, export to VictoriaTraces directly

**Pros**: no new component.

**Cons**:
- it is not a control, since a compromised run skips it;
- the SDK offers no switch, so the filter would monkeypatch lmnr internals;
- Envoy's gRPC spans would still need a receiver.

### Option 3: Vector's OTLP source (ADR-0030's log shipper)

**Pros**: already deployed.

**Cons**:
- trace support is its least exercised path;
- no pod-by-connection attribution;
- the log pipeline would carry a security control.

---

## Decision Outcome

**Chosen option**: "OpenTelemetry Collector".

**Rationale**: it is the only option where the attribute allowlist and the run id are both enforced
by something the sandbox cannot reach.

---

## Consequences

### Positive

- VictoriaTraces holds only allowlisted metadata for agent runs, whatever the SDK records.
- Envoy's and the harness's spans share one pipeline host.

### Negative

- A new metadata attribute is invisible until someone adds it to the allowlist.
- Content still crosses the pod network to the collector (WireGuard on aws-0) before it is dropped.
  gcp-0 has no WireGuard (ADR-0005): the same content crosses its pod network unencrypted by Cilium
  until the collector drops it.
- A handful of allowlisted keys are still free text a run controls — `lmnr.span.path`,
  `gen_ai.response.id`, `lmnr.association.properties.metadata.tool_call_id` and `error.type` — and
  keep up to 256 characters of it (`transform/cap`'s `truncate_all`). This is the accepted residual
  (AK5): the keys themselves are metadata (a span path, a response id, a tool-call id, an error
  type), never prompt or completion text, but their values are not further constrained.
- Envoy's own default span tags (`http.url` with its query string, `user_agent`, and the rest of
  Envoy's built-in tracer tags) cannot be turned off from the `EnvoyProxy` CRD on EG 1.9.2 —
  `spec.telemetry.tracing.tags` only adds tags, it never removes the tracer's defaults. `agent-router`'s
  spans are therefore capped at 256 characters by `traces/router` (`memory_limiter, transform/cap,
  batch`) rather than allowlisted like the sandboxes' `traces/agents` pipeline is, because this
  collector pipeline cannot know Envoy's tag names in advance.
- Envoy Gateway 1.9.2 does not enforce the `ReferenceGrant` a cross-namespace tracing `backendRef`
  normally requires (AK2a). The grant is created anyway, for the day EG catches up to its own CRD
  doc, but the actual control today is the collector's own CNP ingress rule, not the grant.

### Neutral

- The collector runs only under the opt-in `agent-platform` umbrella.
- agent-router always samples: `telemetry.tracing.samplingRate` is 100, so a compromised run cannot
  reduce its own visibility by triggering rarer code paths (AK9).

---

## Implementation Notes

`observability/base/agent-platform/agent-traces-collector.yaml`. The run CNP, composed by the
`AgentRun` composition in crossplane-configuration, admits `POST /v1/traces` on :4318 only. Proved
by `scripts/ci/tests/test-agent-traces-filter.sh` and runbook 08.

Clearing span links needs the ALPHA feature gate `ottl.set.allowNil` (v0.158+, off by default,
enabled via `command.extraArgs`). Without it, `set(span.links, nil)` is a silent no-op — OTTL
still runs the statement, but nothing changes — and `set(span.links, [])` is rejected outright,
because the links setter's type check does not accept an empty slice literal in place of `nil` (AK7).

---

## References

- `docs/superpowers/plans/2026-09-27-agent-observability-plan.md` (rulings O1–O6)
- [ADR-0030]({{< relref "/docs/decisions/0030-vector-as-log-shipper.md" >}})
- [ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}})
