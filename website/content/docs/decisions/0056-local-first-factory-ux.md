---
title: The factory is driven from the developer's local agent, and a room is as visible as its repo
linkTitle: 0056 · Local-first factory UX
weight: 560
description: Local agents reach the factory through an open-format Agent Skill and roomctl rather than a local MCP server; the room's top layer is a deterministic summary plus the agents' one-line progress notes rather than LLM narration; and a room is readable if and only if its repo is readable on GitHub, rather than by ZITADEL groups or by every agents-member.
lastVerified: 2026-10-08
---

**Status**: Accepted
**Date**: 2026-10-08
**Deciders**: Smana (Platform Owner)
**Related Spec**: [Agent factory: local-first developer UX](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-08-agent-factory-local-first-ux-design.md)

---

## Context

Developers live in a local coding agent or IDE and will not open a browser room to hand off a side
task. The room shows raw events, and one broker serves every repo, where any `agents-member` reads
every room. A room holds the issue, code the agent read, diffs and tool output, so with a second team
or a private repo it becomes a way to read a repo around GitHub's own permissions. Three choices had
credible alternatives; the rest of the [design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-08-agent-factory-local-first-ux-design.md)
did not.

---

## Decision Drivers

- One artefact every local agent reads, with no new server or auth path
- Each call visible in the developer's own transcript
- A "where are we" view that is exact, cheap and cannot hallucinate
- One source of truth for who may read a room, where developers' access already lives

---

## Considered Options

### D2: how a local agent talks to the factory

| Option | Verdict |
|---|---|
| **Agent Skill (`.agents/skills`) + `roomctl`** | Chosen: one open format, one binary, the procedure (draft, file, never label) lives in the skill |
| A local MCP server (`roomctl mcp`) | Deferred, not in v1: a second server and auth path to run; calls hidden behind a tool boundary; revisit only if a target agent cannot run a shell |
| No local integration, browser room only (status quo) | Rejected: developers will not leave their agent or IDE for a browser to hand off or follow a side task |

### D3: the room's top layer

| Option | Verdict |
|---|---|
| **Deterministic fold of the room log, plus agents' progress notes** | Chosen: exact, cheap, testable; the notes carry the *why* without a second model |
| An LLM narrating the room | Rejected: costs tokens, lags the run, and summarises untrusted agent text |
| Raw event stream only (status quo) | Rejected: too much noise, no "where are we" view, unclear what the developer can do |

### D7: who may read a room

| Option | Verdict |
|---|---|
| **Follow GitHub: readable if and only if the repo is readable; admins bypass** | Chosen: a room is derived from its repo, so it inherits the repo's permission; no second system to drift |
| Per-repo groups mirrored in ZITADEL | Rejected: a second permission system to keep in step with GitHub |
| Every `agents-member` reads all rooms (today) | Rejected: a room leaks a private repo to anyone in the group |
| Identity source: a `github_login` token claim (ZITADEL Action over user metadata) | Rejected: no Action can read IdP links at token time, and user metadata is writable by machine users for themselves and by `user.write` holders, so the claim is forgeable |
| **Identity source: the user's GitHub IdP link, read by the broker** | Chosen: a link can be added only by authenticating at GitHub, or by an admin; the numeric id survives renames. This holds from ZITADEL v4.17.3 and v4.18.0: older releases let a user add an unverified link to their own account through the API |

---

## Decision Outcome

**Chosen**: the skill plus `roomctl` (D2), the deterministic summary plus notes (D3), and
GitHub-backed room visibility (D7).

```mermaid
flowchart LR
  T["token: sub"] --> B{"broker: read room R (repo X)"}
  B -->|agents-admin| OK["allowed"]
  B -->|cache hit < 5 min| C{"can read X?"}
  B -->|cache miss| L["ZITADEL link -> GitHub id -> login"] --> G["GitHub: permission of login on X"] --> C
  L -->|ZITADEL / GitHub unreachable: fail closed| D
  G -->|unreachable: fail closed| D
  C -->|yes| S["standing rules: watch / steer / approve"]
  C -->|no| D["404: no such room"]
```

D7 in one line: GitHub is a link-only IdP in ZITADEL. On a cache miss the broker lists the caller's
IdP links (`ListIDPLinks`, read-only `ORG_OWNER_VIEWER` machine user), takes the GitHub link's numeric
id, resolves it to the current login (`GET /user/{id}`), and asks GitHub with the factory App's
installation token whether that login can read the room's repo. Each answer is cached for at most
5 minutes, and non-admins fail closed when ZITADEL or GitHub cannot be reached. GitHub read access
lets you see a room; it never grants steering or approving, which stay with the existing standings.
Details: [spec, "Rooms across repos"](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-08-agent-factory-local-first-ux-design.md).

---

## Consequences

### Positive

- One skill file, no server to run locally. `.agents/skills` is the open-standard location most agents read; Claude Code reads only `.claude/skills`, which this repo symlinks to it (`roomctl skill install` writes `.agents/skills`, so elsewhere the symlink is yours to add).
- The summary is a versioned contract (`summary/v1`) tested with golden fixtures.
- A room is never more visible than its repo; revocation lags by at most the TTL (5 minutes), plus one 30 s ping for a socket that is already open.

### Negative

| Cost | Mitigation |
|---|---|
| Users must link their GitHub account to their ZITADEL user once (GitHub is link-only: no sign-up and no auto-creation through it); without a link non-admins see no rooms | `roomctl rooms` explains how to link it |
| Linked users can also sign in with GitHub and receive their project roles (EKS RBAC, Grafana, Harbor, Headlamp), because ZITADEL needs the IdP on the login policy for linking. Accepted risk | Offboarding must deactivate the ZITADEL user, not only the Google account |
| The broker holds an org-wide read-only ZITADEL credential (`ORG_OWNER_VIEWER` machine user) | Used only for `ListIDPLinks`. Not harmless if leaked: its PAT can mint more credentials for its own user, so revoking means deleting all of its PATs and keys, or deactivating the user |
| Reads depend on the GitHub API, and on ZITADEL on a cache miss | 5-minute cache; fail closed for non-admins past it |
| The WebSocket answers 404 `no such room` instead of 403 `not_permitted` for a known room the caller may not read | Intended: a 403 would confirm the room exists |
| Progress notes are untrusted text, and the developer's own local agent is now a reader | Returned under `notes.untrusted: true`, the skill treats them as data, the web page escapes them |
| The "never apply a label" rule in the skill is advice, not a control | The enforceable gate is server-side: only a maintainer's label starts work |

### Neutral

- Rooms created before this change carry the CRD default `spec.repository`, `Smana/cloud-native-ref`, which the API server applies. Anyone who can read that public repo can read them until the factory backfills the real repository.
- An MCP server stays a later option, not a rejected one.

---

## References

- [Spec: local-first developer UX](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-08-agent-factory-local-first-ux-design.md)
- [ADR-0049]({{< relref "/docs/decisions/0049-room-client-and-human-auth.md" >}}): `roomctl` never approves or steers
- [ADR-0044]({{< relref "/docs/decisions/0044-room-session-protocol.md" >}}): the room log the summary folds
