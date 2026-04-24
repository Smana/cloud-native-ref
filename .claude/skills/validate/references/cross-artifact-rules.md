# Cross-Artifact Rules

Semantic checks `/validate` applies on top of `scripts/validate-spec.sh` (which handles structural / coverage / format checks). Findings get a stable ID (`C` constitution, `D` drift, `R` duplication, `A` ambiguity) so users can address them by ID.

## Constitution (loaded via `.claude/rules/spec-constitution.md`)

### C1 — Resource without `xplane-*` prefix (CRITICAL)

In `plan.md`, any `metadata.name:` field for a Crossplane-managed resource that does not start with `xplane-`. Look at YAML blocks under `## Design`. Recommendation: rename — the prefix is load-bearing for IAM scoping.

### C2 — KCL dict mutation pattern (CRITICAL)

In plan.md fenced ` ```kcl ` blocks, patterns like `obj.spec.X = …` after the dict was already created. Recommendation: rewrite as inline conditional `obj = { spec.X = … if cond else default }`. Reference function-kcl issue #285.

### C3 — Missing CiliumNetworkPolicy (HIGH)

Plan proposes a Pod-running resource (Deployment / StatefulSet / Job) but no `CiliumNetworkPolicy` listed. Recommendation: add a default-deny policy with explicit egress + ingress.

### C4 — Missing security context (HIGH)

Deployment / Pod design without `runAsNonRoot`, `readOnlyRootFilesystem`, or `allowPrivilegeEscalation: false`. Recommendation: add the standard security context block (see constitution).

### C5 — Hardcoded credentials hint (CRITICAL)

`password:`, `secret:`, `apiKey:`, `aws_access_key`, `token:` followed by a non-`{{`-templated literal. Recommendation: External Secrets Operator + OpenBao.

### C6 — IRSA mentioned (MEDIUM)

`IRSA` or `IAM Roles for Service Accounts` in plan.md. Recommendation: use EKS Pod Identity (ADR-0002).

### C7 — Missing resource limits (MEDIUM)

Deployment / StatefulSet design block without `resources.limits` and `resources.requests`. Recommendation: add explicit CPU + memory.

## Drift

### D1 — Terminology drift between spec and plan (MEDIUM)

Nouns appearing in spec.md user stories but absent from plan.md (or vice versa). E.g., spec uses "Queue", plan uses "Topic". Recommendation: pick one term and use it consistently.

### D2 — Plan introduces requirement not in spec (HIGH)

Plan's `Resources Created` mentions a resource type that has no corresponding FR or SC in spec.md. Recommendation: either add an FR to spec.md (spec is missing scope) or remove from plan (plan is over-scoped).

## Duplication

### R1 — Duplicate FRs (MEDIUM)

Pair of FR-XXX whose normalized text (lowercase, strip stop words) is ≥ 80% similar. Recommendation: merge.

### R2 — Duplicate SCs (MEDIUM)

Same as R1 but for SC-XXX.

## Ambiguity

> Note: the bash validator already grep-detects vague adjectives. These are deeper semantic checks for Claude.

### A1 — FR uses "etc." or vague enumeration (MEDIUM)

FR text containing `etc.`, `and so on`, `among others`, `such as`. Recommendation: enumerate explicitly or split into multiple FRs.

### A2 — SC has no measurable verification path (HIGH)

SC-XXX whose text contains no metric or observable condition. Recommendation: rephrase so a human or `/verify-spec` can answer pass/fail with cluster evidence.

## Verification evidence

### V1 — SC-XXX lacks a runnable verification command (HIGH)

Every SC-XXX should be answerable with a command a reader can run (inspired by superpowers `verification-before-completion`). Check `spec.md` / `plan.md` for each SC: is there a clear command, query, or observable signal that produces pass/fail evidence?

Examples of acceptable evidence paths:
- `kubeconform -summary <manifest>` → 0 invalid
- `./scripts/validate-kcl-compositions.sh` → exit 0
- `flux get kustomization <name>` → `Ready=True`
- `kubectl get <xr>` → `Synced=True, Ready=True`
- VictoriaMetrics query `rate(<metric>[5m]) < 0.01`
- Hubble verdict flow for a specific policy

Recommendation: rephrase the SC so `/verify-spec` can answer pass/fail with cluster evidence; mention the verification command in `plan.md` under *Validation path*.

### V2 — plan.md missing "Validation path" section (MEDIUM)

`plan.md` should have a *Validation path* block listing the exact commands that prove each SC-XXX. If absent, add one (the template includes a starter block under *Implementation Notes*).

## Output discipline

- Empty result is valid. Don't invent findings.
- Each finding gets a stable ID (`C1`, `D1`, etc.) so users can address by ID.
- Show the **location** as `<file> L<line>` where possible.
- Recommendations: one sentence, actionable, specific.
- For CRITICAL findings, cite the constitution clause.

## Verdict

- **BLOCK**: any CRITICAL finding remains. Implementation must not start.
- **PASS WITH WARNINGS**: HIGH or MEDIUM remain. Document trade-offs in `clarifications.md` (new CL-N) before implementing, or fix them.
- **PASS**: LOW or none.
