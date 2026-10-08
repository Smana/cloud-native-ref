---
title: Humans reach rooms through a web UI the broker serves, behind oauth2-proxy
linkTitle: 0049 · Room client and human auth
weight: 490
description: The room web UI is served by the broker itself and reached on the tailnet through oauth2-proxy, which holds the ZITADEL session in an HttpOnly, SameSite=Strict cookie and forwards the ID and JWT access tokens; the broker re-validates both. roomctl, a CLI with its own native ZITADEL client (not yet built), will read, chat, queue and fork but never steer or approve. A Headlamp plugin, a CLI only, an AHP facade and a browser PKCE app were rejected.
lastVerified: 2026-09-30
---

**Status**: Accepted
**Date**: 2026-09-27
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP2 — Collaboration rooms](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md)

---

## Context

Developers must watch runs, queue work, take the driver token and approve actions (UX reviews,
2026-09-27: "developers cannot access anything"). The page renders LLM output, so a token readable by
the page is a token an injected transcript can steal (T10). Approvals must work from a phone.

---

## Decision Drivers

- No token the page's script can read
- Every semantic of the room (driver, approval cards, queue, fork) in one client with no install
- No approving or steering from a place a local agent can drive (§8)
- Reuse a pattern the platform already runs

---

## Considered Options

### Option 1: A web UI served by the broker, behind oauth2-proxy

**Pros**: the session is an HttpOnly, `SameSite=Strict` cookie; oauth2-proxy is already the
platform's pattern (Headlamp on gcp-0); a phone works; one deploy.
**Cons**: a small UI to own.

### Option 2: A Headlamp plugin

**Cons**: Headlamp is for cluster operators; developers are GitOps-only and hold no Kubernetes
binding; its auth model is Kubernetes RBAC, not room roles.

### Option 3: A CLI only

**Cons**: no phone approvals, no blog screenshots, and a CLI is exactly where a local agent can act.

### Option 4: An AHP facade for existing clients

**Cons**: AHP is pre-1.0 and no client this team uses speaks it.

### Option 5: A browser app with a public PKCE client

**Cons**: the access token lives in the page, next to rendered LLM output.

---

## Decision Outcome

**Chosen option**: "Option 1", with `roomctl` for read, chat, queue and fork (SP2 phase 6, not yet built).

---

## Consequences

### Positive

- Developers in `agents-member` watch every room; the page never holds a token.
- The broker re-validates both tokens, so a bypass of oauth2-proxy still authenticates nobody.

### Negative

- `rooms-proxy` is the platform's first ZITADEL client issuing JWT access tokens. `agent-system`
  reads only OpenBao's `agents` mount, which `external-secrets` cannot read. The OIDC sync writes
  the secret to the cloud secret store like every client, and its existing OpenBao mirror copies
  it to `agents`, so OpenBao keeps one writer. Only a hosting sync run with `--mirror-openbao`
  produces that copy. Only gcp-0's hosting sync passes it; aws-0's would need the flag added if
  AWS hosts again. No ExternalSecret reads
  the cloud copy, so on GCP nothing is ever granted access to it.

### Neutral

- WebSockets cross the Tailscale Gateway with `timeouts.request: 0s` and a 30 s ping.
- The ID token must carry the `rooms-proxy` client as `azp`; ZITADEL's JWT access tokens carry
  `client_id` instead. Both need the project id and an allowlisted client in `aud`. ZITADEL adds
  the project id to `aud` only when oauth2-proxy requests the project audience scope. The broker
  reads the project id and client ids from files at use, because gcp-0 mints a fresh ZITADEL, and
  fresh ids, on every build.

---

## Implementation Notes

`infrastructure/base/room-broker/` (oauth2-proxy, route), `scripts/provision/zitadel-oidc-clients.sh`
(`rooms-proxy`, `agents-admin`, `agents-member`, `--grant`). A fresh ZITADEL holds no grants, so
`--grant agents-admin=<email>` is re-run after each build, once that user has logged in.

| Part | State |
|---|---|
| Web UI: watch, post and queue, steer, interrupt, hand to a role | Built (SP2 phases 2–4) |
| Approval cards | SP2 phase 5, not on the integration branch yet |
| `roomctl` and fork | SP2 phase 6, not started |
| oauth2-proxy bearer tokens for `roomctl` | Off (`skip-jwt-bearer-tokens: "false"`) until phase 6 |

---

## References

- [SP2 design §3, §8](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md)
- [ADR-0044](0044-room-session-protocol.md)
