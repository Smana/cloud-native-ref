---
title: Rooms are an AHP-shaped log we own, stored in CNPG, fanned out with Postgres LISTEN/NOTIFY
linkTitle: 0044 · Room session protocol
weight: 440
description: A room is one append-only log per session whose seq the broker assigns, mirroring the Agent Host Protocol's semantics without speaking it. Agents collaborate as sequential runs that record a handoff or a verdict with room tools. The log of record is a CNPG SQLInstance, and broker replicas learn of new events through Postgres LISTEN/NOTIFY on the same database. AHP on the wire, OpenHands shared conversations, ACP, A2A through agentgateway, Valkey Streams, NATS JetStream, an in-memory broker, Valkey pub/sub hints, and google/ax or Agent Substrate were rejected.
lastVerified: 2026-09-29
---

**Status**: Accepted
**Date**: 2026-09-27
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP2 — Collaboration rooms](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md)

---

## Context

Humans and agent runs must share one ordered session: watch it live, steer the running agent, hand
work to the next role, approve actions, fork it (programme D6, D7). The session is also SP3's audit
trail of record (C4), so it must outlive every pod and be impossible to rewrite. Each participant
authenticates as itself: runs with their own ServiceAccount token (C2), humans through ZITADEL.

---

## Decision Drivers

- One order for every participant, replayable after any disconnect
- Identity per event, stamped by the server, never claimed by a client
- The transcript survives the sandbox, redacted, and nothing can rewrite it
- Nothing dials into a sandbox (C4)
- Survives a spot interruption of the broker without losing an open approval

---

## Considered Options

### Option 1: An AHP-shaped log we own, sequential runs, CNPG + LISTEN/NOTIFY

The broker assigns a gapless `seq` per room. Events use the frozen C4 envelope. Runs push through a
bridge sidecar. Agents never talk to each other: a run records `room_handoff` or `room_verdict`, and
the orchestrator starts the next run with a brief built from the log. Each append also issues a
`pg_notify` in its transaction, and every broker replica holds one `LISTEN` connection that wakes its
viewers; a replica that loses it catches each room up from its last `seq`, so a notification is only
ever a wake-up, never data.

**Pros**: authorisation and identity are ours; replay is a range read; append-only is enforced by
grants and triggers, testable; fan-out rides the database that already holds the log, so no
infrastructure beyond the platform's own claims.
**Cons**: we own the protocol, and an AHP facade is later work.

### Option 2: AHP v0.9 on the wire

**Pros**: an emerging standard for multi-client agent sessions.
**Cons**: pre-1.0; leaves authentication and agent-to-agent out of scope, which are the hard part here.

### Option 3: OpenHands conversations as the room API

**Pros**: already in the sandbox.
**Cons**: no identity; the store dies with the pod; one conversation per server.

### Option 4: ACP, or A2A through agentgateway

**Cons**: ACP is 1:1 editor-to-agent. Nothing here speaks A2A, and A2A has no humans.

### Option 5: Valkey Streams, NATS JetStream, or one in-memory broker as the log

**Cons**: KVStore is cache semantics by its XRD; JetStream is new infrastructure; one replica makes a
spot interruption an outage for every open approval.

### Option 6: Valkey pub/sub hints beside the CNPG log ([design S8](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md#decisions))

A `KVStore` carries "room X reached seq N" hints between broker replicas; the log stays in CNPG.

**Pros**: the design's original choice; decouples fan-out load from the database.
**Cons**: one more dependency and one more CNP, and the KVStore's CNP admits
the whole namespace; the log is already in Postgres, which can carry the same hint with
`LISTEN/NOTIFY`. Reversible until phase 2's fan-out code lands.

### Option 7: google/ax or Agent Substrate as the session substrate

Re-checked on 2026-09-27, one day after ADR-0041 rejected them as the runtime. ax v0.3.0 deleted its
durable event log; Substrate emits actor lifecycle events only. Neither has sequencing, multi-client
replay, per-message identity or approvals. Substrate's parking and fork are ahead, but waking a
parked actor is ingress-shaped (against C4), and a memory fork freezes the parent's credentials into
the child (against C2).

---

## Decision Outcome

**Chosen option**: "Option 1".

**Rationale**: the decision drivers are identity, order and durability. Only a log we own gives all
three without delegating authorisation to a pre-1.0 protocol or a runtime we rejected. Fan-out
uses the database that already holds the log rather than adding Valkey: one dependency fewer.

---

## Consequences

### Positive

- The transcript and the end reason of every run survive the pod (UX finding H3).
- Reviewers, testers and triagers have a destination for their output.
- `UPDATE events` as the broker's role fails: history is append-only by grant and trigger (the
  schema also refuses `UPDATE` and `TRUNCATE` from its owner), not by convention.

### Negative

- The protocol is ours to maintain. An AHP facade can sit on the log at AHP 1.0.
- A rebuild recovers the log up to the last promoted seed only.
- Fan-out shares the log's database: each broker replica holds one `LISTEN` connection, and a lost
  notification is recovered by reading the log from the last `seq`, never from the notification.

### Neutral

- Next re-check of ax and Substrate: 2026-12-15, or when EKS ships 1.37 and Substrate closes #1898,
  lifts its no-spot rule (#1528) and fixes #1657.

---

## Implementation Notes

Code: `Smana/agent-platform` (OD-4). Manifests: `infrastructure/base/room-broker/`. Plan:
`docs/superpowers/plans/2026-09-27-agent-collaboration-rooms-plan.md`.

- **Seams only.** The core packages (envelope, redaction, store, wire) hold no platform constants:
  platform facts enter through config or a consumer-side interface
  ([agent-platform `AGENTS.md`](https://github.com/Smana/agent-platform/blob/main/AGENTS.md)). It keeps
  the core reusable outside this platform.
- **Spin-out deferred.** Whether agent-platform becomes a standalone project is decided at the
  [plan](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/plans/2026-09-27-agent-collaboration-rooms-plan.md)'s Phase 7 UX sign-off, not before: the choice needs the finished UX to judge.

---

## References

- [SP2 design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md)
- [Agent Host Protocol](https://microsoft.github.io/agent-host-protocol/guide/what-is-ahp.html)
- [ADR-0041](0041-agent-sandbox-gvisor-al2023.md)
