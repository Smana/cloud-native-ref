# Analyze Rules

Cross-artifact consistency checks. Each rule has a category, severity, and a detection method. Findings are emitted with a stable ID prefix (`A` = ambiguity/coverage, `C` = constitution, `D` = drift, `Q` = open question, `R` = duplication).

## Coverage

### A1 — FR with no matching task (HIGH)

**Detect**: every `**FR-NNN**` in `spec.md` should appear in at least one `tasks.md` task line (either by ID reference or semantic match).

**Heuristic**: simple text grep first (`grep "FR-001" tasks.md`), then semantic check (does any task description plausibly implement the FR?). If the FR text mentions a verb like "create / generate / configure / expose / restrict", at least one task should mention the same verb on the same noun.

**Recommendation**: add a task `T0NN: <verb> <noun> per FR-NNN`.

### A2 — SC with no verification path (HIGH)

**Detect**: every `**SC-NNN**` in `spec.md` should map to a verification method that `/verify-spec` could execute. Look for keywords (latency, metric, log, kubectl, condition).

**Recommendation**: rephrase the SC so a human or `/verify-spec` can answer pass/fail.

## Ambiguity

### A3 — Vague adjectives in SC (MEDIUM)

**Detect**: SC-NNN containing any of: `fast`, `scalable`, `secure`, `robust`, `flexible`, `user-friendly`, `simple`, `efficient`, `reliable`, `seamless`, `intuitive` without a measurable threshold (number + unit) on the same line.

**Recommendation**: replace with a concrete metric. Examples:
- "fast" → "p95 latency < 100 ms"
- "scalable" → "sustains 10k req/s"
- "reliable" → "SLO 99.9% monthly"

### A4 — FR uses "etc." or vague enumeration (MEDIUM)

**Detect**: FR text containing `etc.`, `and so on`, `among others`, `such as`.

**Recommendation**: enumerate the cases explicitly, or split into multiple FRs.

## Constitution (loaded via the platform-constitution reference-skill)

### C1 — Resource without `xplane-*` prefix (CRITICAL)

**Detect**: in `plan.md`, any `metadata.name:` or `name:` field for a Crossplane-managed resource that does not start with `xplane-`. Look at YAML blocks under `## Design`.

**Recommendation**: rename `<name>` → `xplane-<name>`. The prefix is load-bearing for IAM scoping.

### C2 — KCL dict mutation pattern in plan (CRITICAL)

**Detect**: in plan.md fenced ` ```kcl ` blocks (or pseudo-code), patterns like `obj.spec.X = …` or `obj["spec"]["X"] = …` after the dict was already created.

**Recommendation**: rewrite as inline conditional: `obj = { spec.X = … if cond else default }`. Reference function-kcl issue #285.

### C3 — Missing CiliumNetworkPolicy (HIGH)

**Detect**: plan.md proposes a Pod-running resource (Deployment / StatefulSet / Job in Resources Created table) but no `CiliumNetworkPolicy` listed.

**Recommendation**: add a default-deny `CiliumNetworkPolicy` with explicit egress + ingress rules.

### C4 — Missing security context (HIGH)

**Detect**: plan.md mentions a Deployment / Pod but no `runAsNonRoot`, `readOnlyRootFilesystem`, or `allowPrivilegeEscalation: false` in the design YAML.

**Recommendation**: add the standard security context block (see constitution).

### C5 — Hardcoded credentials hint (CRITICAL)

**Detect**: any of `password:`, `secret:`, `apiKey:`, `aws_access_key`, `token:` followed by a non-`{{`-templated literal in plan.md or example YAML.

**Recommendation**: replace with External Secrets Operator backed by OpenBao.

### C6 — IRSA mentioned (MEDIUM)

**Detect**: `IRSA` or `IAM Roles for Service Accounts` in plan.md.

**Recommendation**: use EKS Pod Identity (ADR-0002). The `EPI` composition is the canonical pattern.

### C7 — Missing resource limits (MEDIUM)

**Detect**: a Deployment / StatefulSet design block without `resources.limits` and `resources.requests`.

**Recommendation**: add explicit CPU + memory requests and limits.

## Drift

### D1 — Terminology drift between spec and plan (MEDIUM)

**Detect**: nouns appearing in spec.md user stories but absent from plan.md (or vice versa). Examples: spec uses "Queue", plan uses "Topic".

**Recommendation**: pick one term and use it consistently across both files. Rename in the file with fewer occurrences.

### D2 — Plan introduces requirement not in spec (HIGH)

**Detect**: plan.md `Resources Created` mentions a resource type that has no corresponding FR or SC in spec.md.

**Recommendation**: either add an FR to spec.md (the spec is missing scope) or remove from the plan (the plan is over-scoped).

## Duplication

### R1 — Duplicate FRs (MEDIUM)

**Detect**: any pair of FR-XXX whose normalized text (lowercase, strip stop words) is ≥ 80% similar.

**Recommendation**: merge into one FR.

### R2 — Duplicate SCs (MEDIUM)

**Detect**: as R1 but for SC-XXX.

**Recommendation**: merge.

## Open questions

### Q1 — Unresolved [NEEDS CLARIFICATION] in spec.md or plan.md (HIGH)

**Detect**: any `[NEEDS CLARIFICATION:` marker in spec.md or plan.md.

**Recommendation**: run `/clarify`.

### Q2 — Stale CL-N reference (LOW)

**Detect**: `spec.md` or `plan.md` references `CL-N` where N does not appear as a `## CL-N` heading in `clarifications.md`.

**Recommendation**: either add the missing CL entry or remove the dangling reference.

### Q3 — Clarifications.md entry not referenced (LOW)

**Detect**: `## CL-N` entry in clarifications.md whose ID is never referenced from spec.md, plan.md, or tasks.md.

**Recommendation**: link it from the artifact whose decision it records, so the connection is explicit.

## Output discipline

- Empty result is valid. Do not invent findings.
- Each finding gets a stable ID (`A1`, `C1`, etc.) so users can address them by ID.
- Show the **location** as `<file> L<line>` where possible.
- Recommendations should be one sentence, actionable, and specific.
- For CRITICAL findings, include the constitution clause cited.
