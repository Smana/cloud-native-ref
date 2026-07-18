# Clarifications Log — Migrate SQLInstance backups to the Barman Cloud CNPG-I plugin

**Spec**: [SPEC-010](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

## CL-1 — 2026-07-18 — Migrate to the plugin, or stay on in-tree Barman Cloud?

**Asked by**: Spec author
**Context**: In-tree `barmanObjectStore` is deprecated (CNPG 1.26) and removed in operator **1.31.0**. The cluster runs operator 1.30.0 today, so backups still work — the question is whether to migrate proactively or defer until forced.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Migrate to the Barman Cloud CNPG-I plugin now | Unblocks the 1.31.0 bump; migration is documented as seamless/zero-data-loss; done on our schedule | New plugin install (greenfield); two render sites to change |
| B | Stay on in-tree until forced | No work now | Blocks any operator bump past 1.30.x; forced migration under time pressure later |

**Decision**: A — migrate to the plugin now.
**Rationale**: In-tree removal in 1.31.0 is a hard upstream deadline; the CNPG project documents the plugin migration as seamless. Doing it proactively (while the cluster is not live, per this session's context) removes the operator-upgrade blocker with zero migration risk. Matches the constitution's "prefer the sanctioned upstream mechanism".
**Decided by**: Recency-assessment session, 2026-07-18 (user-approved as a Tier-1 adoption).
**References**: <https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/>; SPEC-010 spec.md Problem.

---

<!-- Remaining open questions (plugin delivery mechanism, exact ScheduledBackup plugin API,
     inheritFromIAMRole support, plugin securityContext/CNP) are tracked in spec.md
     "Open questions" and will be appended here as CL-2..CL-N once resolved via /clarify. -->

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/) — ADR-0002 (EKS Pod Identity over IRSA) governs the credential model
