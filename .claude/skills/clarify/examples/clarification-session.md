# Example Clarification Session

Illustrative walkthrough of resolving two `[NEEDS CLARIFICATION]` markers in a Valkey caching composition spec.

## Input spec (excerpt)

```markdown
## Clarifications

- [NEEDS CLARIFICATION: What should be the default eviction policy for cache?]
- [NEEDS CLARIFICATION: Should high availability be mandatory or optional?]
```

## Skill presents Q1

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Q1: What should be the default eviction policy for cache?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Context: Eviction policy determines what happens when cache
  memory is full. Common policies: LRU (Least Recently Used),
  LFU (Least Frequently Used), TTL-based, noeviction.

  | Option | Answer            | Implications                                  |
  |--------|-------------------|-----------------------------------------------|
  | A      | allkeys-lru       | Predictable, general-purpose; community default |
  | B      | volatile-lru      | Evicts only TTL-keys; safer for persistent data |
  | C      | noeviction        | OOM instead of evict; app must handle errors  |
  | D      | Custom            | Specify your own policy                       |

  Recommendation: A — matches Valkey/Redis community default,
  operationally familiar, satisfies SC-002 "evictions deterministic".

Your choice (A/B/C/D or custom): _
```

## User responds: `A`

## Skill updates spec

**Before** (line 163):

```markdown
- [NEEDS CLARIFICATION: What should be the default eviction policy for cache?]
```

**After**:

```markdown
- [CLARIFIED: A (allkeys-lru) — Valkey/Redis community default, predictable, satisfies SC-002]
```

## Skill presents Q2

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Q2: Should high availability be mandatory or optional?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Context: HA adds complexity (replicas, failover, PDB) and
  cost (2x+ memory). Many dev environments do not need HA.

  | Option | Answer           | Implications                                    |
  |--------|------------------|-------------------------------------------------|
  | A      | Optional (default: false) | Progressive complexity; opt-in for prod    |
  | B      | Mandatory        | One pattern; safer; higher baseline cost        |
  | C      | Mandatory in prod namespaces | Policy-enforced via Kyverno            |

  Recommendation: A — matches existing `App` composition's
  progressive-complexity pattern; HA is an explicit opt-in.

Your choice: _
```

## User responds: `A`

## Final spec state

```markdown
## Clarifications

- [CLARIFIED: A (allkeys-lru) — Valkey/Redis community default, predictable, satisfies SC-002]
- [CLARIFIED: A (Optional, default: false) — progressive complexity, matches App composition pattern]
```

## Completion message

```
All clarifications resolved in docs/specs/001-valkey/spec.md

Summary of decisions:
  1. Eviction policy: allkeys-lru
  2. High availability: optional, opt-in via ha: true

Next steps:
  - Complete the 4-persona review checklist
  - Run /validate to verify completeness
  - Begin implementation
```
