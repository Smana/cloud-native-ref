# LLM Frontier Backends and Token Budgets (SP4 slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the gateway controllers into a CPU-only, always-on `ai-gateway` umbrella and put
frontier models (Z.ai GLM, Anthropic on Bedrock EU) behind both gateways, with per-identity token
budgets counting in shadow mode.

**Architecture:**
- **PR 1** creates the Flux umbrella `ai-gateway` and moves `envoy-gateway`, `envoy-ai-gateway` and
  `vllm-semantic-router` into it with their names unchanged. It then adds, on the existing `ai-gateway`
  Gateway:
  - namespace `llm-gateway`, holding the platform Z.ai backend and `tier-frontier`;
  - Envoy Gateway's global rate limit, stored in a Valkey `KVStore`;
  - the early strip of client identity headers;
  - the budgets B3–B5, in shadow.
- **PR 2** lands after SP1 phase 3. It adds:
  - the agent tiers on SP1's `agent-router`: `agent-models` (public → Z.ai) and
    `agent-models-internal` (→ Bedrock EU);
  - B1–B2, in shadow;
  - keyless Bedrock through EKS Pod Identity on both data planes;
  - the `claude-*` names;
  - an `oidc` listener on `ai-gateway`.
- A new render gate asserts the cross-object invariants that no schema can express.

**Tech Stack:** Flux 2.9 (`kustomize.toolkit.fluxcd.io/v1`), Envoy Gateway 1.9.1, Agent Router
(Envoy AI Gateway) 1.1.0 (`aigateway.envoyproxy.io/v1beta1`, its storage version), Gateway API
1.6.2, Crossplane `KVStore`/`EPI` claims (crossplane-configuration v0.7.1), External Secrets over
OpenBao, Cilium `CiliumNetworkPolicy`, VictoriaMetrics `VMRule`, Python 3 + PyYAML for the gate.

**Spec:** [`docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md`](../specs/2026-09-23-llm-complexity-routing-design.md)
(SP4) and its [research](../specs/2026-09-23-llm-complexity-routing-research.md). They sit under the
programme [`2026-09-23-agent-factory-design.md`](../specs/2026-09-23-agent-factory-design.md): contracts
C1–C7 are binding, and owner decisions OD-1…OD-17 are accepted at their recommended defaults. This
plan covers the spec's implementation-outline **PRs 1 and 2 only**.

## Global Constraints

- **Umbrella.** Flux `Kustomization` `ai-gateway` in `flux-system`, file `clusters/aws-0/ai-gateway.yaml`,
  `path: ./clusters/aws-0-ai-gateway`, **`suspend: true` by default** (OD-3, amended 2026-09-26; it
  was "never suspended"). Every live step resumes it first:
  `flux resume kustomization ai-gateway -n flux-system`. Code and text below that still say
  "always-on" or "never suspended" predate the amendment. The files on the branch are authoritative.
  - The moved children keep their names: `envoy-gateway`, `envoy-ai-gateway`, `vllm-semantic-router`.
  - New children: `llm-gateway` (PR 1) and `ai-gateway-security-epi` (PR 2).
- **The Gateway keeps its identity.** GatewayClass `envoy-ai-gateway`, and the human/system Gateway
  `ai-gateway` in `envoy-ai-gateway-system`, both stay: the InferenceService composition's `parentRef`
  names them. Its frontier routes and backends live in the new namespace `llm-gateway`.
- **Identity headers** are removed by a `ClientTrafficPolicy` before authentication on every Gateway
  of class `envoy-ai-gateway`: `x-ar-agent`, `x-ar-human`, `x-ai-gateway-client-id`, `agent-session-id`
  (C5). The reason is that Envoy's `claim_to_headers` appends rather than replaces.
- **Every budget rule** is a `rateLimit.global` rule with:
  - `shared: true`, because the default gives each route its own bucket (C5);
  - `shadowMode: true`, because OD-10 asks for one week in shadow and enforcement is PR 7;
  - `cost.request` = `{from: Number, number: 0}`;
  - `cost.response` = `{from: Metadata, metadata: {namespace: io.envoy.ai_gateway, key: llm_total_token}}`.
- **Budget rules need route costs.** Every `AIGatewayRoute` that a budget must count declares
  `llmRequestCosts: [{metadataKey: llm_total_token, type: TotalToken}]`. Without it the metadata never
  exists, and the rule charges nothing.
- **One Gateway-level `BackendTrafficPolicy` per Gateway.** Envoy Gateway marks a second one on the
  same target `Conflicted`. B3–B5 are therefore three rules in one policy, and B1–B2 two rules in another.
- **Budget defaults** (OD-10, design §6):

  | Rule | Gateway | Selector | Limit |
  |---|---|---|---|
  | B1 | `agent-router` | `x-ar-agent` Distinct | 5 000 000/Day |
  | B2 | `agent-router` | none | 40 000 000/Day |
  | B3 | `ai-gateway` | `x-ar-human` Distinct | 10 000 000/Day |
  | B4 | `ai-gateway` | `x-ai-gateway-client-id` Distinct | 5 000 000/Day |
  | B5 | `ai-gateway` | `x-ai-eg-model` RegularExpression `^(tier-frontier\|claude-.*)$` | 20 000 000/Day |
- **Model map** (design §5). Every rule has exactly one backendRef at `weight: 100` and no `priority`.

  | Name | `agent-router` `public` → Z.ai | `agent-router` `internal` → Bedrock EU |
  |---|---|---|
  | `tier-light` | `glm-5.3-flash` (API ID UNVERIFIED) | `eu.anthropic.claude-haiku-4-5-20251001-v1:0` |
  | `tier-standard` | `glm-5.3-flashx` (API ID UNVERIFIED) | `eu.anthropic.claude-sonnet-5` |
  | `tier-frontier` | `glm-5.2` | `eu.anthropic.claude-opus-5-5` |
  | `agent-default` | `glm-5.2` | `eu.anthropic.claude-opus-5-5` |

  On `ai-gateway`: `tier-frontier` → `glm-5.2`. The names `claude-opus-5-5`, `claude-sonnet-5` and
  `claude-haiku-4-5` map to the same EU profiles.
- **Keys.**

  | Key | Where it lives | How it gets there |
  |---|---|---|
  | Platform Z.ai key | OpenBao `platform/llm/zai`, property `api_key` | `openbao-platform` into namespace `llm-gateway` only |
  | Agents' Z.ai key | `platform/agents/zai` | SP1's `agents-secrets` store only, never `openbao-platform` (C1) |
  | Bedrock | none: EKS Pod Identity, never IRSA (ADR-0002) | EPIs below |

  The two EPIs are `xplane-ai-gateway-bedrock` and `xplane-agent-router-bedrock`. Each binds the
  data-plane ServiceAccount of the same name in `envoy-gateway-system`, which Envoy Gateway creates
  from `EnvoyProxy.spec.provider.kubernetes.envoyServiceAccount.name`. Each grants
  `bedrock:InvokeModel*` on the `eu.anthropic.*` profiles and their EU destination models, and nothing
  else.
- **Provider egress.** Provider FQDNs are allowed on data-plane pods only: `api.z.ai` and
  `bedrock-runtime.eu-west-3.amazonaws.com`, both on 443. Never `world:443`.
- **gcp-0 behaves exactly as today.**
  - Anything AWS-specific goes into `infrastructure/aws-0/*` overlays or into new directories that
    only aws-0 applies.
  - `clusters/gcp-0-llm-platform/` keeps pointing at unchanged bases.
  - Base edits are cloud-neutral and inert there: header strips, metrics attributes, namespace,
    `allowedRoutes`, CNP narrowing, Z.ai egress, and allow rules toward a rate-limit pod that gcp-0
    never runs.
- **Constitution.**
  - Crossplane claims are prefixed `xplane-`.
  - Every new pod set gets a default-deny CNP: Valkey through the composition, the rate-limit pod here.
  - No hardcoded credentials.
  - Requests and limits on the rate-limit Deployment.
- **Style.** Comments carry *why*, never *how*. Repository metadata is English. Commits are conventional,
  with **no `Co-Authored-By` trailer** and no generated-with line.
- **Evidence.** Cite the output of a fresh run for every "done":
  - `./scripts/ci/validate-manifests.sh` → exit 0, with `Invalid: 0, Skipped: 0` in the report;
  - `task check` → exit 0;
  - `./scripts/ci/validate-links.sh` → exit 0.

  Never run two `validate-manifests.sh` in one checkout at once: they race on `.bundle/`.
- **Mutating commands.** Nothing mutates a cluster, a cloud account, OpenBao or GitHub unless its step
  is tagged **[LIVE]** or **[OWNER]**.
  - **[LIVE]** steps run on aws-0 deployed from the branch, from the branch's own worktree (the
    deploy applies the disk, not `main`), with spot/cheapest defaults and `llm-platform` left
    suspended: `cd opentofu && TF_VAR_flux_git_ref='refs/heads/<branch>' terramate script run deploy`.
  - **[OWNER]** steps need the owner's credentials or approval.

## PR boundaries

| PR | Branch | Cut from | Tasks | Needs merged first |
|---|---|---|---|---|
| 1 | `feat/ai-gateway-frontier` | a fresh `EnterWorktree` off `origin/main` | 0–8, plus the SP4 design, research and this plan | nothing |
| 2 | `feat/agent-frontier-tiers` | a fresh `EnterWorktree` off `origin/main` | 9–15 | PR 1 **and** SP1 phase 3 (`agent-router`, `agents-secrets`, the seeded `agent-models`) |

## Success criteria in this slice

| SC | What slice 1 proves | Task | What is deferred, and to where |
|---|---|---|---|
| SC-1 | With `llm-platform` suspended and zero GPU nodes, `tier-frontier` on `ai-gateway` is answered by GLM-5.2 | 8 [LIVE] | The sandbox half (`agent-default` from a run) is SP1 phases 3/6. "No provider key outside `llm-gateway`, `agent-system`, `envoy-gateway-system`" is PR 6: RunLore holds `GLM_API_KEY` until then |
| SC-2 | A forged `x-ai-gateway-client-id` is charged to the real API-key client (PR 1). A forged `x-ar-agent` is charged to the caller's own `sub` (PR 2) | 8, 15 [LIVE] | — |
| SC-3 | The budget 429 carries `x-envoy-ratelimited: true`, which closes R5 | 8 [LIVE] | The shadow week starts at PR 2's merge (Task 15 records the date). A 429 on the next request after crossing B1 needs enforcement: PR 7 |
| SC-11 | An `…internal` token gets 401 on `public`, and on `internal` it reaches Bedrock and never `api.z.ai` | 15 [LIVE] | — |
| SC-4, SC-6 | — | — | PR 4 (SR 0.3.0, HA, complexity) |
| SC-5 | — | — | PR 3 (`gateway.aliases`) |
| SC-7 | — | — | PR 5 (`complexity-classifier`) |
| SC-8, SC-9 | — | — | PR 7 (dashboard, promptfoo arms, verdict) |
| SC-10 | — | — | PR 6 (RunLore behind `ai-gateway`) |

Risks the slice also closes: R5 in Task 8, R7 (the Bedrock IAM shape) and R8 (Claude Code → GLM
translation) in Task 15.

## Owner actions and live steps

| Tag | Step | Task |
|---|---|---|
| ~~[OWNER] O1~~ | **Superseded 2026-09-26.** The `llm-gateway` ExternalSecret reads `platform/runlore/credentials#GLM_API_KEY` directly, and PR 6 moves the key to `platform/llm/zai` | — |
| ~~[OWNER] O2~~ | **Superseded 2026-09-26.** An ESO `Password` generator (`CreatedOnce`) creates the Valkey password in-cluster | — |
| [OWNER] O3 | Confirm that `llm-platform` is suspended on every running aws-0 before merging PR 1 | 0, 8 |
| [OWNER] O4 | Enable Bedrock model access in eu-west-3 for the three EU profiles. This is the Marketplace subscription on first invocation, done from an admin identity | 15 |
| [OWNER] O5 | Create a throwaway ZITADEL machine user that issues JWT access tokens, for the `oidc` listener test, and delete it afterwards | 15 |
| [LIVE] L1 | PR 1 end to end on a branch-deployed aws-0 | 8 |
| [LIVE] L2 | PR 2 end to end, with `agent-platform` resumed on the branch cluster. Its deploy also applies the new `zitadel_project_id` key (OpenTofu `eks/configure`) | 15 |

## File structure

```
clusters/aws-0/ai-gateway.yaml                      NEW  umbrella, never suspended, deletionPolicy Orphan
clusters/aws-0/llm-platform.yaml                    MOD  dependsOn ai-gateway (C1); teardown comment
clusters/aws-0-ai-gateway/
  kustomization.yaml                                NEW  the children list
  README.md                                         NEW  children, ownership invariant, teardown
  infrastructure-envoy-gateway.yaml                 MOVED from aws-0-llm-platform; path → aws-0 overlay (T5)
  infrastructure-envoy-ai-gateway.yaml              MOVED; path → aws-0 overlay (T10)
  infrastructure-vllm-semantic-router.yaml          MOVED, unchanged
  infrastructure-llm-gateway.yaml                   NEW (T4); path → aws-0 overlay (T11)
  security-ai-gateway-epi.yaml                      NEW (T10)
clusters/aws-0-llm-platform/{kustomization.yaml,README.md}   MOD  8 → 5 children
clusters/aws-0-agent-platform/infrastructure-agent-model-routing.yaml  NEW (T12), in SP1's umbrella
namespaces/base/{llm-gateway.yaml,kustomization.yaml}        NEW/MOD
infrastructure/base/envoy-gateway/network-policy.yaml        MOD  data plane narrowed to ai-gateway; Z.ai and rate-limit egress; controller :18001
infrastructure/aws-0/envoy-gateway/                          NEW  rate limit: HelmRelease patch, KVStore, ExternalSecret, CNP, VMPodScrape
infrastructure/base/envoy-ai-gateway/{clienttrafficpolicy,helmrelease,gateway,security-policy}.yaml  MOD
infrastructure/aws-0/envoy-ai-gateway/                       NEW (T10/T14)  Bedrock SA, oidc listener, additive CNP, llm-oidc route
infrastructure/base/llm-gateway/                             NEW  Z.ai backend, tier-frontier, B3–B5, prices, B5 alert
infrastructure/aws-0/llm-gateway/                            NEW (T11)  Bedrock backend, claude-* route
infrastructure/base/agent-model-routing/                     NEW (T13)  B1–B2, run-token series, budget alerts
infrastructure/aws-0/agent-model-routing/                    NEW (T12)  agent-models-internal, Bedrock backend
infrastructure/base/agent-router/network-policy-data-plane.yaml  MOD (T12/T13)  SP1's CNP agent-router-data-plane (I10); Bedrock, Pod Identity, rate-limit egress
infrastructure/base/agent-router/aigatewayroute-agent-models.yaml  MOD (T12)  SP1's file (I3); tiers — SP4 owns its content
infrastructure/base/agent-router/envoyproxy.yaml             MOD (T12)  SP1's file (I2); envoyServiceAccount
clusters/aws-0-agent-platform/infrastructure-agent-router.yaml  MOD (T12)  SP1's file (I1); dependsOn the Bedrock EPIs
security/base/epis-ai-gateway/                               NEW (T10)  the two Bedrock EPIs
opentofu/aws/eks/configure/{variables.tf,variables.tfvars,kubernetes.tf}  MOD (T14)  zitadel_project_id
scripts/ci/flux-schema/assert-ai-gateway.py                  NEW (T1, T9)  the render gate
scripts/ci/tests/flux-schema/test-assert-ai-gateway.py       NEW (T1, T9)
scripts/ci/validate-manifests.sh, scripts/AGENTS.md          MOD (T3)  wire the gate
scripts/ci/flux-schema/render-bundle.py                      MOD (T14)  zitadel_project_id fixture
website/content/docs/decisions/{0046-…,0050-…,_index.md}     NEW/MOD (T7)
website/content/docs/platform/ai-platform/{_index,gateway-and-routing,coding-clients}.md  MOD
website/content/docs/platform/gitops/repository-structure.md, clusters/AGENTS.md          MOD
```

The SP1 paths come from SP1's plan (`2026-09-25-agent-runtime-identity-plan.md`) and are listed with *Interfaces with SP1*.

---

## PR 1 — `ai-gateway` umbrella, platform Z.ai backend, rate limit, B3–B5 in shadow

### Task 0: Worktree, the design documents, and the move precondition

**Files:**
- Bring onto the branch: `docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md`,
  `docs/superpowers/specs/2026-09-23-llm-complexity-routing-research.md`, and
  `docs/superpowers/plans/2026-09-25-llm-frontier-backends-plan.md`.

**Interfaces:** Produces branch `feat/ai-gateway-frontier`, and a recorded answer to "is
`llm-platform` suspended, and who owns the three children today".

- [ ] **Step 1: Create the worktree.** Call `EnterWorktree` with name `ai-gateway-frontier`, which branches
  from `origin/main`. Then run `git branch -m feat/ai-gateway-frontier`.
- [ ] **Step 2: Bring the documents.** The SP4 design links the programme design, and that one links
  all four sub-project designs. So check whether the docs PR has merged first:

  ```bash
  git fetch origin
  git ls-tree --name-only origin/main docs/superpowers/specs/ | grep -c '2026-09-23-'
  ```

  - If it prints `9`, the programme set is on `main`: bring only the three files listed above.
  - Otherwise bring the whole set, because `validate-links.sh` fails on the dangling links:

  ```bash
  git checkout docs/agent-factory-design -- \
    'docs/superpowers/specs/2026-09-23-*.md' \
    docs/superpowers/plans/2026-09-25-llm-frontier-backends-plan.md
  ```

- [ ] **Step 3: Check the links.** Run `./scripts/ci/validate-links.sh`. Expected: exit 0.
- [ ] **Step 4: Commit.**

  ```bash
  git add docs/superpowers
  git commit -m "docs(superpowers): SP4 frontier routing design, research and slice-1 plan"
  ```

- [ ] **Step 5 [LIVE, read-only]: Record the precondition.** Skip it if no aws-0 is running, and say
  so in the PR body. Otherwise:

  ```bash
  kubectl get kustomization llm-platform -n flux-system -o jsonpath='{.spec.suspend}{"\n"}'
  kubectl get kustomization -n flux-system envoy-gateway envoy-ai-gateway vllm-semantic-router \
    -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}'
  ```

  - Expected: the first command prints `true`. The second prints `…=llm-platform` for each child, or
    `NotFound` if `llm-platform` was never resumed on this cluster.
  - Anything else means the move is not safe yet. Stop, and hand it to the owner (O3).

**Why the move is safe, and when it is not.**

- **Suspended `llm-platform`.** kustomize-controller's garbage collection deletes an object only when its
  owner labels still name the Kustomization doing the pruning. It passes `GetOwnerLabels` as the delete
  `Inclusions`: `internal/controller/kustomization_controller.go`, verified 2026-09-25. `ai-gateway`
  re-applies the three children and relabels them `kustomize.toolkit.fluxcd.io/name: ai-gateway`.
  After that, a later resume of `llm-platform` finds them in its stale inventory but skips them.
- **Resumed `llm-platform` at merge time.** It can reconcile first and delete the three children while
  they still carry its label. Deleting a child with `prune: true` uninstalls Envoy Gateway and every
  Gateway on the cluster until `ai-gateway` recreates them. The `suspend: true` in Git normally
  prevents this; a branch that commits `suspend: false` would not.

### Task 1: The render gate for cross-object invariants (A1–A3)

**Files:**
- Create: `scripts/ci/flux-schema/assert-ai-gateway.py`
- Create: `scripts/ci/tests/flux-schema/test-assert-ai-gateway.py`

**Interfaces:**
- Produces:
  - `python3 scripts/ci/flux-schema/assert-ai-gateway.py [BUNDLE_DIR]` → exit 0 when clean, 1 on
    violations (each printed as `FAIL …`), 2 when the bundle is missing.
  - Module functions `load_objects(bundle_dir) -> list[dict]`,
    `check_rate_limit_rules(objs) -> list[str]` and `check_identity_strips(objs) -> list[str]`.
  - A module-level `CHECKS` list. Task 9 appends `check_agent_pinning` and `check_zai_public_only` to it.
- Consumes: `scripts/ci/flux-schema/yamlcompat.py` (`YAML_LOADER`).

- [ ] **Step 1: Write the failing test.** Create `scripts/ci/tests/flux-schema/test-assert-ai-gateway.py`:

```python
#!/usr/bin/env python3
"""Tests for assert-ai-gateway.py, the gate for AI-gateway invariants that span objects.

Every invariant here fails silently on a cluster. An unshared budget rule is a
valid BackendTrafficPolicy. A Gateway without the header strip still routes. A
Z.ai route on the wrong listener still answers. So each check is pinned both
ways: the compliant shape passes, and each way of breaking it fails with a
message naming the object.

Run: python3 scripts/ci/tests/flux-schema/test-assert-ai-gateway.py
"""
import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile

import yaml

HERE = pathlib.Path(__file__).resolve().parent
SUBJECT_DIR = HERE.parent.parent / "flux-schema"
sys.path.insert(0, str(SUBJECT_DIR))
spec = importlib.util.spec_from_file_location("assert_ai_gateway", SUBJECT_DIR / "assert-ai-gateway.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

FAILURES = []
STRIPS = ["x-ar-agent", "x-ar-human", "x-ai-gateway-client-id", "agent-session-id"]


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}{(' -- ' + detail) if detail else ''}")
        FAILURES.append(name)


def rule(**overrides):
    r = {
        "clientSelectors": [{"headers": [{"name": "x-ar-human", "type": "Distinct"}]}],
        "limit": {"requests": 10_000_000, "unit": "Day"},
        "cost": {
            "request": {"from": "Number", "number": 0},
            "response": {"from": "Metadata",
                         "metadata": {"namespace": "io.envoy.ai_gateway", "key": "llm_total_token"}},
        },
        "shared": True,
        "shadowMode": True,
    }
    r.update(overrides)
    return r


def btp(rules, name="ai-gateway-token-budgets"):
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "BackendTrafficPolicy",
            "metadata": {"name": name, "namespace": "envoy-ai-gateway-system"},
            "spec": {"targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway",
                                     "name": "ai-gateway"}],
                     "rateLimit": {"global": {"rules": rules}}}}


def gateway(name="ai-gateway", ns="envoy-ai-gateway-system", cls="envoy-ai-gateway"):
    return {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "Gateway",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"gatewayClassName": cls, "listeners": []}}


def ctp(remove, gw="ai-gateway", ns="envoy-ai-gateway-system", section=None):
    target = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw}
    if section:
        target["sectionName"] = section
    spec = {"targetRefs": [target]}
    if remove is not None:
        spec["headers"] = {"earlyRequestHeaders": {"remove": remove}}
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "ClientTrafficPolicy",
            "metadata": {"name": "client", "namespace": ns}, "spec": spec}


def quiet(fn, *args):
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        return fn(*args)


print("A1/A2 — budget rules")
check("compliant rule passes", gate.check_rate_limit_rules([btp([rule()])]) == [])
errs = gate.check_rate_limit_rules([btp([rule(shared=False)])])
check("shared: false fails, naming the policy",
      len(errs) == 1 and "shared" in errs[0] and "ai-gateway-token-budgets" in errs[0], str(errs))
no_shared = rule()
del no_shared["shared"]
check("absent shared fails (Envoy Gateway defaults it to false)",
      len(gate.check_rate_limit_rules([btp([no_shared])])) == 1)
errs = gate.check_rate_limit_rules([btp([rule(cost={"request": {"from": "Number", "number": 1},
                                                     "response": rule()["cost"]["response"]})])])
check("request cost 1 fails", len(errs) == 1 and "request cost" in errs[0], str(errs))
wrong_key = rule()
wrong_key["cost"]["response"]["metadata"]["key"] = "llm_input_token"
errs = gate.check_rate_limit_rules([btp([wrong_key])])
check("response cost from another key fails", len(errs) == 1 and "response cost" in errs[0], str(errs))
no_cost = rule()
del no_cost["cost"]
check("a rule with no cost fails (it would count calls, not tokens)",
      len(gate.check_rate_limit_rules([btp([no_cost])])) == 2)
local_only = btp([])
local_only["spec"]["rateLimit"] = {"local": {"rules": [{"limit": {"requests": 5, "unit": "Second"}}]}}
check("a local-only rate limit is out of scope", gate.check_rate_limit_rules([local_only]) == [])

print("A3 — identity headers stripped before authentication")
check("full strip passes", gate.check_identity_strips([gateway(), ctp(STRIPS)]) == [])
errs = gate.check_identity_strips([gateway(), ctp(STRIPS[:-1])])
check("one header missing fails, naming it", len(errs) == 1 and "agent-session-id" in errs[0], str(errs))
check("no ClientTrafficPolicy fails", len(gate.check_identity_strips([gateway()])) == 1)
check("a policy in another namespace does not count",
      len(gate.check_identity_strips([gateway(), ctp(STRIPS, ns="other")])) == 1)
check("a listener-scoped policy does not cover the whole Gateway",
      len(gate.check_identity_strips([gateway(), ctp(STRIPS, section="http")])) == 1)
check("header names are case-insensitive",
      gate.check_identity_strips([gateway(), ctp([h.upper() for h in STRIPS])]) == [])
check("other GatewayClasses are out of scope", gate.check_identity_strips([gateway(cls="cilium")]) == [])

print("main()")
with tempfile.TemporaryDirectory() as d:
    p = pathlib.Path(d)
    (p / "overlay-a.yaml").write_text(yaml.safe_dump_all([gateway(), ctp(STRIPS), btp([rule()])]))
    check("exit 0 on a compliant bundle", quiet(gate.main, [d]) == 0)
    (p / "overlay-b.yaml").write_text(yaml.safe_dump_all([btp([rule(shared=False)], name="bad")]))
    check("exit 1 on a violation", quiet(gate.main, [d]) == 1)
check("exit 2 when the bundle is missing", quiet(gate.main, ["/nonexistent-bundle-dir"]) == 2)

if FAILURES:
    print(f"\n{len(FAILURES)} failed")
    sys.exit(1)
print("\nall passed")
```

- [ ] **Step 2: Run it and watch it fail.** Run
  `python3 scripts/ci/tests/flux-schema/test-assert-ai-gateway.py`. Expected: a traceback with
  `FileNotFoundError` on `assert-ai-gateway.py`.
- [ ] **Step 3: Write the gate.** Create `scripts/ci/flux-schema/assert-ai-gateway.py`:

```python
#!/usr/bin/env python3
"""Gate the rendered bundle on AI-gateway invariants that span objects.

`flux schema validate` checks each object alone. These rules relate objects,
and breaking any of them leaves every object valid and the gateway quietly
wrong:

  A1  Every global rate-limit rule sets `shared: true`. The default gives every
      route its own bucket, multiplying each budget by the number of routes a
      principal can reach (programme contract C5).
  A2  Every such rule charges tokens, not calls: request cost 0, response cost
      from io.envoy.ai_gateway/llm_total_token (SP4 design section 6).
  A3  Every Gateway of class envoy-ai-gateway is covered by a whole-Gateway
      ClientTrafficPolicy that removes the identity headers before
      authentication. Envoy's claim_to_headers APPENDS, so a client-sent value
      would otherwise survive beside the verified one (C5).

Usage: assert-ai-gateway.py [BUNDLE_DIR]    (default .bundle)
Exit:  0 clean, 1 violations (each printed), 2 bundle missing.
"""
import pathlib
import sys

import yaml

from yamlcompat import YAML_LOADER

AI_GATEWAY_CLASS = "envoy-ai-gateway"
IDENTITY_HEADERS = ("x-ar-agent", "x-ar-human", "x-ai-gateway-client-id", "agent-session-id")
COST_METADATA = {"namespace": "io.envoy.ai_gateway", "key": "llm_total_token"}


def ref(obj):
    meta = obj.get("metadata") or {}
    return f"{obj.get('kind')} {meta.get('namespace', '')}/{meta.get('name', '')}"


def spec_of(obj):
    return obj.get("spec") or {}


def load_objects(bundle_dir):
    objs = []
    for path in sorted(pathlib.Path(bundle_dir).glob("*.yaml")):
        for doc in yaml.load_all(path.read_text(), Loader=YAML_LOADER):
            if isinstance(doc, dict) and doc.get("kind"):
                objs.append(doc)
    return objs


def check_rate_limit_rules(objs):
    errors = []
    for obj in objs:
        if obj.get("kind") != "BackendTrafficPolicy":
            continue
        rules = ((spec_of(obj).get("rateLimit") or {}).get("global") or {}).get("rules") or []
        for i, rule in enumerate(rules):
            where = f"{ref(obj)} rule {i}"
            if rule.get("shared") is not True:
                errors.append(f"{where}: shared must be true, or each route gets its own bucket")
            cost = rule.get("cost") or {}
            request = cost.get("request") or {}
            if request.get("from") != "Number" or request.get("number") != 0:
                errors.append(f"{where}: request cost must be Number 0, so the rule counts tokens, not calls")
            response = cost.get("response") or {}
            if response.get("from") != "Metadata" or response.get("metadata") != COST_METADATA:
                errors.append(f"{where}: response cost must be Metadata "
                              f"{COST_METADATA['namespace']}/{COST_METADATA['key']}")
    return errors


def check_identity_strips(objs):
    removed_by_gateway = {}
    for obj in objs:
        if obj.get("kind") != "ClientTrafficPolicy":
            continue
        ns = (obj.get("metadata") or {}).get("namespace", "")
        early = (spec_of(obj).get("headers") or {}).get("earlyRequestHeaders") or {}
        removed = {h.lower() for h in early.get("remove") or []}
        for target in spec_of(obj).get("targetRefs") or []:
            # A sectionName scopes the policy to one listener; the invariant is per Gateway.
            if target.get("kind") == "Gateway" and not target.get("sectionName"):
                removed_by_gateway.setdefault((ns, target.get("name")), set()).update(removed)
    errors = []
    for obj in objs:
        if obj.get("kind") != "Gateway" or spec_of(obj).get("gatewayClassName") != AI_GATEWAY_CLASS:
            continue
        meta = obj.get("metadata") or {}
        have = removed_by_gateway.get((meta.get("namespace", ""), meta.get("name")), set())
        missing = [h for h in IDENTITY_HEADERS if h not in have]
        if missing:
            errors.append(f"{ref(obj)}: no whole-Gateway ClientTrafficPolicy removes "
                          f"{', '.join(missing)} before authentication")
    return errors


CHECKS = [check_rate_limit_rules, check_identity_strips]


def main(argv):
    bundle = pathlib.Path(argv[0] if argv else ".bundle")
    if not bundle.is_dir():
        print(f"error: bundle directory {bundle} not found; run render-bundle.py first", file=sys.stderr)
        return 2
    objs = load_objects(bundle)
    # The bundle holds a base and every overlay built on it, so one defect can
    # appear several times; report it once.
    errors = list(dict.fromkeys(e for check in CHECKS for e in check(objs)))
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    print(f"ai-gateway invariants: {len(CHECKS)} checks, {len(errors)} violations")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run the test again.** Run
  `python3 scripts/ci/tests/flux-schema/test-assert-ai-gateway.py`. Expected: `all passed` and exit 0.
  Then run `scripts/ci/tests/run.sh` and check that it lists
  `PASS  flux-schema/test-assert-ai-gateway`.
- [ ] **Step 5: Commit.**

  ```bash
  git add scripts/ci/flux-schema/assert-ai-gateway.py scripts/ci/tests/flux-schema/test-assert-ai-gateway.py
  git commit -m "feat(ci): gate the AI gateways on budget and identity-header invariants"
  ```

### Task 2: The `ai-gateway` umbrella and the move

**Files:**
- Create: `clusters/aws-0/ai-gateway.yaml`, `clusters/aws-0-ai-gateway/kustomization.yaml`,
  `clusters/aws-0-ai-gateway/README.md`
- Move, with content unchanged: `clusters/aws-0-llm-platform/infrastructure-{envoy-gateway,envoy-ai-gateway,vllm-semantic-router}.yaml`
  → `clusters/aws-0-ai-gateway/`
- Modify: `clusters/aws-0-llm-platform/kustomization.yaml`, `clusters/aws-0-llm-platform/README.md`,
  `clusters/aws-0/llm-platform.yaml`, `clusters/AGENTS.md`,
  `website/content/docs/platform/ai-platform/_index.md`,
  `website/content/docs/platform/gitops/repository-structure.md`

**Interfaces:**
- Produces: Flux Kustomization `ai-gateway` (namespace `flux-system`), and the children `envoy-gateway`,
  `envoy-ai-gateway` and `vllm-semantic-router` with unchanged names. SP1 phase 3 depends on
  `envoy-ai-gateway`.
- Consumes: nothing.

- [ ] **Step 1: Record the children before the move.** This is the failing test.

  ```bash
  names() { kustomize build "$1" | python3 -c 'import sys,yaml; print("\n".join(sorted(d["metadata"]["name"] for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind")=="Kustomization")))'; }
  before=$(mktemp); names clusters/aws-0-llm-platform > "$before"; wc -l < "$before"   # 8
  names clusters/aws-0-ai-gateway                                                    # fails: no such directory
  ```

- [ ] **Step 2: Move the three children.**

  ```bash
  mkdir -p clusters/aws-0-ai-gateway
  git mv clusters/aws-0-llm-platform/infrastructure-envoy-gateway.yaml clusters/aws-0-ai-gateway/
  git mv clusters/aws-0-llm-platform/infrastructure-envoy-ai-gateway.yaml clusters/aws-0-ai-gateway/
  git mv clusters/aws-0-llm-platform/infrastructure-vllm-semantic-router.yaml clusters/aws-0-ai-gateway/
  ```

- [ ] **Step 3: Write `clusters/aws-0-ai-gateway/kustomization.yaml`.**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Children of the always-on ai-gateway umbrella (../aws-0/ai-gateway.yaml).
# The first three moved here from aws-0-llm-platform/ with their names
# unchanged, so every dependsOn edge that names them still resolves.
resources:
  - infrastructure-envoy-gateway.yaml
  - infrastructure-envoy-ai-gateway.yaml
  - infrastructure-vllm-semantic-router.yaml
```

- [ ] **Step 4: Write `clusters/aws-0/ai-gateway.yaml`.**

```yaml
---
# AI gateway layer — always on (programme OD-3), CPU only.
#
# The Envoy Gateway and Agent Router controllers, the Semantic Router, and the
# human/system Gateway `ai-gateway`, with its frontier backends in namespace
# llm-gateway. Both the GPU fleet (llm-platform) and the agents
# (agent-platform) route through it. Agents run on frontier models with zero
# GPUs, which is impossible while these controllers live in the GPU umbrella.
#
# deletionPolicy Orphan: removing this object (a revert, a rename) must not
# cascade into uninstalling Envoy Gateway and every Gateway on the cluster.
# Tearing the layer down is explicit: aws-0-ai-gateway/README.md.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ai-gateway
  namespace: flux-system
spec:
  prune: true
  deletionPolicy: Orphan
  interval: 5m0s
  timeout: 5m0s
  # A sibling of clusters/aws-0/, not a sub-path: flux-system syncs that tree
  # recursively and would otherwise own the children itself, outside this
  # umbrella's inventory.
  path: ./clusters/aws-0-ai-gateway
  sourceRef:
    kind: GitRepository
    name: flux-system
```

- [ ] **Step 5: Shrink the `llm-platform` children list.** In
  `clusters/aws-0-llm-platform/kustomization.yaml`, the `resources:` list becomes:

```yaml
resources:
  - infrastructure-runtimeclass-nvidia.yaml
  - infrastructure-gpu-nodepools.yaml
  - apps-llm.yaml
  - security-llm-epi.yaml
  - tooling-promptfoo.yaml
```

  Drop the comment block about the AI gateway above the removed entries as well, since it now lives
  in the gateway's own umbrella.

- [ ] **Step 6: Make `llm-platform` depend on `ai-gateway`,** as C1 requires. In
  `clusters/aws-0/llm-platform.yaml`:
  - Add under `spec:`:

    ```yaml
      # C1: the GPU fleet attaches to the ai-gateway Gateway and its controllers.
      dependsOn:
        - name: ai-gateway
    ```

  - Remove `no vllm-semantic-router,` from the header comment's list.
  - Replace the teardown lines so that the moved children are no longer deleted:

    ```yaml
    #   flux delete kustomization \
    #     llm-platform-apps llm-platform-gpu-nodepools llm-platform-promptfoo \
    #     llm-platform-security-epi runtimeclass-nvidia \
    #     -n flux-system --silent
    ```

- [ ] **Step 7: Write `clusters/aws-0-ai-gateway/README.md`.**

````markdown
# AI gateway — always-on Flux umbrella

Aggregated by `../aws-0/ai-gateway.yaml`, which is **never suspended** (programme OD-3). CPU only. It
is what lets agents run on frontier models with no GPU node.

| Child Kustomization | Path | Holds |
|---|---|---|
| `envoy-gateway` | `infrastructure/base/envoy-gateway` | Envoy Gateway |
| `envoy-ai-gateway` | `infrastructure/base/envoy-ai-gateway` | Agent Router, the human/system Gateway `ai-gateway`, API-key auth, and the Semantic Router `EnvoyPatchPolicy` |
| `vllm-semantic-router` | `infrastructure/base/vllm-semantic-router` | The Semantic Router (`MoM`) |

## The ownership invariant

The first three children used to belong to `llm-platform`. Its garbage collection deletes an object
only while that object's `kustomize.toolkit.fluxcd.io/name` label still names `llm-platform`, and
`ai-gateway` rewrites the label when it applies the child. Before ever resuming `llm-platform` on a
cluster that ran it before this umbrella existed, check:

```bash
kubectl get kustomization -n flux-system envoy-gateway envoy-ai-gateway vllm-semantic-router \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}'
# every line must end in =ai-gateway
```

## Teardown

Deleting the umbrella orphans its children (`deletionPolicy: Orphan`). To remove the layer itself,
delete the children in reverse dependency order:

```bash
flux delete kustomization vllm-semantic-router envoy-ai-gateway envoy-gateway \
  -n flux-system --silent
```
````

  Later tasks keep this README true as they go. Task 4 adds the `llm-gateway` row and puts
  `llm-gateway` first in the teardown command. Tasks 5, 10 and 11 update the rows whose path moves to
  an overlay. Task 10 adds `ai-gateway-security-epi`, last in the teardown command.

- [ ] **Step 8: Update `clusters/aws-0-llm-platform/README.md`.**
  - "The 8 child Flux Kustomizations" becomes "The 5 child Flux Kustomizations".
  - Delete the table rows for `vllm-semantic-router`, `envoy-gateway` and `envoy-ai-gateway`.
  - Add this line under the table: "The gateway layer these children attach to is the always-on
    `ai-gateway` umbrella; see `../aws-0-ai-gateway/README.md`."
  - In both `flux delete kustomization` blocks ("Full teardown" and "Whole-cluster destroy"), the
    argument list becomes
    `llm-platform-apps llm-platform-gpu-nodepools llm-platform-security-epi llm-platform-promptfoo runtimeclass-nvidia`.

- [ ] **Step 9: Update the docs that count or list the children.**
  - `clusters/AGENTS.md`: "The umbrella aggregates 8 children" becomes "5 children". After that
    paragraph, add:

    > The gateway layer — Envoy Gateway, Agent Router, the Semantic Router and the human/system Gateway
    > `ai-gateway` — is the **always-on** `ai-gateway` umbrella (`aws-0/ai-gateway.yaml` →
    > `aws-0-ai-gateway/`, OD-3). Its children kept their names when they moved, so `dependsOn` edges
    > from `llm-platform` children still resolve. Read `aws-0-ai-gateway/README.md` before resuming
    > `llm-platform` on a cluster that ran it before the move.
  - `website/content/docs/platform/ai-platform/_index.md`:
    - "The umbrella aggregates **8** child" becomes "**5** child".
    - Delete the three moved rows from the table.
    - Add after the table:

      > The gateway layer these children attach to (Envoy Gateway, the Envoy AI Gateway, the Semantic
      > Router and the `ai-gateway` Gateway) is a separate, always-on umbrella, `ai-gateway`, under
      > `clusters/aws-0-ai-gateway/`. It is CPU only and has no gate.
  - `website/content/docs/platform/gitops/repository-structure.md`: in the exceptions paragraph,
    "Two Kustomizations are the exception" becomes "Three kinds of Kustomization are the exception".
    Also, "and the opt-in `llm-platform` umbrellas, whose paths (`clusters/aws-0-llm-platform/`,
    `clusters/gcp-0-llm-platform/`)" becomes "the always-on `ai-gateway` umbrella and the opt-in
    `llm-platform` umbrellas, whose paths (`clusters/aws-0-ai-gateway/`, `clusters/aws-0-llm-platform/`,
    `clusters/gcp-0-llm-platform/`)".

- [ ] **Step 10: Check that no child was lost or duplicated.**

  ```bash
  cat <(names clusters/aws-0-ai-gateway) <(names clusters/aws-0-llm-platform) | sort | diff - "$before" && echo SAME
  names clusters/aws-0-ai-gateway   # envoy-ai-gateway envoy-gateway vllm-semantic-router
  ```

  Expected: `SAME`.

- [ ] **Step 11: Validate.** Run `./scripts/ci/validate-manifests.sh` (expect exit 0,
  `Invalid: 0, Skipped: 0`), `./scripts/ci/validate-links.sh` (exit 0) and
  `./scripts/ci/verify-doc-paths.sh` (exit 0).
- [ ] **Step 12: Commit.**

  ```bash
  git add clusters website/content/docs/platform
  git commit -m "feat(clusters): move the gateway controllers into an always-on ai-gateway umbrella"
  ```

### Task 3: Identity headers — early strip, metrics attributes, and wiring the gate

**Files:**
- Modify: `infrastructure/base/envoy-ai-gateway/clienttrafficpolicy.yaml`,
  `infrastructure/base/envoy-ai-gateway/helmrelease.yaml`, `scripts/ci/validate-manifests.sh`,
  `scripts/AGENTS.md`

**Interfaces:**
- Produces:
  - Every request reaching `ai-gateway` has the four identity headers removed before authentication.
  - Agent Router metrics carry the labels `ar_agent`, `ar_human` and `ar_client`.
  - `validate-manifests.sh` runs the gate as "Gate 3".
- Consumes: `assert-ai-gateway.py` (Task 1).

- [ ] **Step 1: Wire the gate.** This is the failing test. In `scripts/ci/validate-manifests.sh`:
  - Renumber every `[n/6]` to `[n/7]`.
  - Insert after the Polaris block:

    ```bash
    echo "==> [6/7] Gate 3 — AI gateway invariants (budget rules, identity-header strip)"
    python3 scripts/ci/flux-schema/assert-ai-gateway.py "${BUNDLE_DIR}"
    ```

  - Relabel the Alertmanager step `==> [7/7] Gate 4 — Alertmanager Slack templates render`.
  - In the header comment, list item 5 becomes
    "gate the bundle: flux schema validate, polaris audit, AI-gateway invariants".
- [ ] **Step 2: Watch it fail.** Run `./scripts/ci/validate-manifests.sh`. Expected: exit 1 with
  `FAIL Gateway envoy-ai-gateway-system/ai-gateway: no whole-Gateway ClientTrafficPolicy removes x-ar-agent, x-ar-human, x-ai-gateway-client-id, agent-session-id before authentication`.
- [ ] **Step 3: Add the strip.** Replace `infrastructure/base/envoy-ai-gateway/clienttrafficpolicy.yaml` with:

```yaml
# Envoy Gateway accepts one whole-Gateway ClientTrafficPolicy per Gateway, so
# the buffer limit and the identity-header strip share this object.
#
# Buffer: Envoy's default 32KB receive buffer is too tight for chat completion
# bodies with long system prompts. 8Mi covers long-context OpenAI-compatible
# bodies (200–500 KB) with headroom; raise it if file attachments start landing.
#
# Strip: x-ar-agent, x-ar-human and x-ai-gateway-client-id name the principal
# that budgets and metrics charge. The gateway sets them from the verified
# credential, but Envoy's claim_to_headers APPENDS to a client-sent value, so
# a forged one must be gone before authentication runs (programme C5).
# agent-session-id is Agent Router's session key; no client chooses it here.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: ai-gateway-client-buffer
  namespace: envoy-ai-gateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
  connection:
    bufferLimit: 8Mi
  headers:
    earlyRequestHeaders:
      remove:
        - x-ar-agent
        - x-ar-human
        - x-ai-gateway-client-id
        - agent-session-id
```

- [ ] **Step 4: Map the identity headers to metric labels.** In
  `infrastructure/base/envoy-ai-gateway/helmrelease.yaml`, under `values.controller:` (**not**
  `extProc:`: in chart 1.1.0 the key sits under `controller`, as `helm show values` shows), add:

```yaml
      # Per-principal token counters: the run meter (SP3) and the budget alerts
      # read these labels. Per-run labels cost ~30 series per run (design R11).
      metricsRequestHeaderAttributes: "x-ar-agent:ar_agent,x-ar-human:ar_human,x-ai-gateway-client-id:ar_client"
```

- [ ] **Step 5: Document the gate.** In `scripts/AGENTS.md`, "then applies three gates" becomes
  "then applies four gates". Add a table row between Polaris and the Alertmanager row (the
  Alertmanager row becomes Gate 4):

  `| 3 | flux-schema/assert-ai-gateway.py | cross-object AI-gateway invariants: budget rules shared and token-costed, identity headers stripped on every envoy-ai-gateway Gateway |`

- [ ] **Step 6: Run it again.** Run `./scripts/ci/validate-manifests.sh`. Expected: exit 0,
  `Invalid: 0, Skipped: 0`, and `ai-gateway invariants: 2 checks, 0 violations`.
- [ ] **Step 7: Commit.**

  ```bash
  git add infrastructure/base/envoy-ai-gateway scripts/ci/validate-manifests.sh scripts/AGENTS.md
  git commit -m "feat(ai-gateway): strip client identity headers and label metrics by principal"
  ```

### Task 4: Namespace `llm-gateway`, the platform Z.ai backend, and `tier-frontier`

**Files:**
- Create: `namespaces/base/llm-gateway.yaml`, `infrastructure/base/llm-gateway/kustomization.yaml`,
  `infrastructure/base/llm-gateway/externalsecret-zai.yaml`, `infrastructure/base/llm-gateway/zai.yaml`,
  `infrastructure/base/llm-gateway/aigatewayroute.yaml`,
  `clusters/aws-0-ai-gateway/infrastructure-llm-gateway.yaml`
- Modify: `namespaces/base/kustomization.yaml`, `infrastructure/base/envoy-ai-gateway/gateway.yaml`,
  `infrastructure/base/envoy-gateway/network-policy.yaml`,
  `clusters/aws-0-ai-gateway/kustomization.yaml`, `clusters/aws-0-ai-gateway/README.md`

**Interfaces:**
- Produces:
  - Namespace `llm-gateway`.
  - `AIServiceBackend` `zai`, fed by Secret `zai-api-key` (key `apiKey`, from OpenBao `llm/zai#api_key`).
  - `AIGatewayRoute` `llm-gateway` with rule `tier-frontier` → `glm-5.2` and `llmRequestCosts`
    `llm_total_token`.
  - Flux child `llm-gateway`.
  - The data-plane CNP `envoy-data-plane` now selects the `ai-gateway` proxies only.
- Consumes: `openbao-platform` (existing), Gateway `ai-gateway`.

- [ ] **Step 1: Check that the route is absent.** This is the failing test.

  ```bash
  kustomize build infrastructure/base/llm-gateway 2>&1 | head -1   # error: must build at directory: not a valid directory
  ```

- [ ] **Step 2: Add the namespace.** Create `namespaces/base/llm-gateway.yaml` and add
  `- llm-gateway.yaml` to `namespaces/base/kustomization.yaml`:

```yaml
# Human and system frontier routes and backends behind the ai-gateway Gateway
# (programme C1). The platform Z.ai key lands here, and only here.
apiVersion: v1
kind: Namespace
metadata:
  name: llm-gateway
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

- [ ] **Step 3: Let the Gateway accept routes from `llm-gateway`.** In
  `infrastructure/base/envoy-ai-gateway/gateway.yaml`, replace the listener's `allowedRoutes` block with:

```yaml
      allowedRoutes:
        namespaces:
          # llm: the per-model AIGatewayRoutes (claims and llm-fleet).
          # llm-gateway: the frontier routes (tier-frontier, claude-*).
          from: Selector
          selector:
            matchExpressions:
              - key: kubernetes.io/metadata.name
                operator: In
                values: [llm, llm-gateway]
```

- [ ] **Step 4: Write the Z.ai secret.** Create `infrastructure/base/llm-gateway/externalsecret-zai.yaml`:

```yaml
# The PLATFORM Z.ai key, for human and system traffic. The agents' key is a
# separate one (platform/agents/zai, SP1's agents-secrets store), so revoking
# either never breaks the other, and provider-side spend splits by key
# (design S12).
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: zai-api-key
  namespace: llm-gateway
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao-platform
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
    name: zai-api-key
    template:
      type: Opaque
      data:
        # Agent Router's APIKey BackendSecurityPolicy reads this key name.
        apiKey: "{{ .api_key }}"
  data:
    - secretKey: api_key  # pragma: allowlist secret
      remoteRef:
        key: llm/zai
        property: api_key  # pragma: allowlist secret
```

- [ ] **Step 5: Write the Z.ai backend.** Create `infrastructure/base/llm-gateway/zai.yaml`:

```yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: zai
  namespace: llm-gateway
spec:
  endpoints:
    - fqdn:
        hostname: api.z.ai
        port: 443
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: zai
  namespace: llm-gateway
spec:
  targetRefs:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: zai
  validation:
    wellKnownCACertificates: System
    hostname: api.z.ai
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIServiceBackend
metadata:
  name: zai
  namespace: llm-gateway
spec:
  schema:
    name: OpenAI
    # Z.ai serves its OpenAI-compatible API under /api/paas/v4, not /v1
    # (the base_url RunLore uses today).
    prefix: /api/paas/v4
  backendRef:
    group: gateway.envoyproxy.io
    kind: Backend
    name: zai
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: BackendSecurityPolicy
metadata:
  name: zai
  namespace: llm-gateway
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: zai
  type: APIKey
  apiKey:
    secretRef:
      name: zai-api-key
```

- [ ] **Step 6: Write the route.** Create `infrastructure/base/llm-gateway/aigatewayroute.yaml`:

```yaml
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: llm-gateway
  namespace: llm-gateway
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
      namespace: envoy-ai-gateway-system
  # Without this the response carries no token metadata, and every budget rule
  # on ai-gateway charges these requests nothing.
  llmRequestCosts:
    - metadataKey: llm_total_token
      type: TotalToken
  rules:
    # The Semantic Router's hard-band target once PR 4 lands; callable by name
    # today. One backend at 100 %: no cross-model fallback (design S7, S8).
    - name: tier-frontier
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: tier-frontier
      backendRefs:
        - name: zai
          modelNameOverride: glm-5.2
          weight: 100
      # Agent Router defaults a rule to 60 s. A reasoning completion from a
      # frontier model, streamed or not, routinely runs longer.
      timeouts:
        request: 600s
```

- [ ] **Step 7: Write the kustomization.** Create `infrastructure/base/llm-gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - externalsecret-zai.yaml
  - zai.yaml
  - aigatewayroute.yaml
```

- [ ] **Step 8: Scope the data-plane CNP to `ai-gateway` and open Z.ai.** In
  `infrastructure/base/envoy-gateway/network-policy.yaml`, CNP `envoy-data-plane`:
  - Replace the `endpointSelector` with:

```yaml
  # ai-gateway's proxies only. Every Envoy Gateway proxy lands in this
  # namespace, and agent-router's (SP1) carries its own policy: without this
  # label, this policy's Z.ai egress and in-cluster ingress would leak onto it.
  endpointSelector:
    matchLabels:
      app.kubernetes.io/managed-by: envoy-gateway
      app.kubernetes.io/component: proxy
      gateway.envoyproxy.io/owning-gateway-name: ai-gateway
```

  - Append to `egress:`:

```yaml
    # Z.ai, the platform's frontier provider (llm-gateway/zai). Provider FQDNs
    # are allowed on data-plane pods only: a key-less pod elsewhere has no
    # reason to reach a provider (design threat model).
    - toFQDNs:
        - matchName: api.z.ai
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 9: Add the Flux child.** Create `clusters/aws-0-ai-gateway/infrastructure-llm-gateway.yaml`,
  and add `- infrastructure-llm-gateway.yaml` to `clusters/aws-0-ai-gateway/kustomization.yaml`. In
  `clusters/aws-0-ai-gateway/README.md`:
  - add the row
    `| llm-gateway | infrastructure/base/llm-gateway | Frontier routes and backends in namespace llm-gateway, token budgets B3–B5, price rules |`,
    with each cell in backticks as in the other rows;
  - prepend `llm-gateway` to the teardown command.

  The file:

```yaml
---
# Human and system frontier routes and backends on the ai-gateway Gateway, in
# namespace llm-gateway, plus that Gateway's token budgets and price rules.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: llm-gateway
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 5m0s
  path: ./infrastructure/base/llm-gateway
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    # The AIGatewayRoute binds to Gateway ai-gateway, and the Agent Router CRDs
    # ship with that child.
    - name: envoy-ai-gateway
    # The budget policy (Task 6) needs Envoy Gateway's rate-limit service.
    - name: envoy-gateway
```

- [ ] **Step 10: Check that the route renders.**

  ```bash
  kustomize build infrastructure/base/llm-gateway | grep -A3 'value: tier-frontier'
  ```

  Expected: the match, followed by the `zai` backendRef.
- [ ] **Step 11: Validate.** Run `./scripts/ci/validate-manifests.sh` → exit 0,
  `Invalid: 0, Skipped: 0`.
- [ ] **Step 12: Commit.**

  ```bash
  git add namespaces infrastructure/base/llm-gateway infrastructure/base/envoy-ai-gateway/gateway.yaml \
    infrastructure/base/envoy-gateway/network-policy.yaml clusters/aws-0-ai-gateway
  git commit -m "feat(llm-gateway): platform Z.ai backend and tier-frontier on the ai-gateway Gateway"
  ```

### Task 5: Envoy Gateway global rate limit on a Valkey `KVStore` (aws-0 overlay)

**Files:**
- Create: `infrastructure/aws-0/envoy-gateway/kustomization.yaml`,
  `infrastructure/aws-0/envoy-gateway/helmrelease-ratelimit.yaml` (patch),
  `infrastructure/aws-0/envoy-gateway/kvstore.yaml`,
  `infrastructure/aws-0/envoy-gateway/externalsecret-ratelimit-valkey.yaml`,
  `infrastructure/aws-0/envoy-gateway/network-policy-ratelimit.yaml`,
  `infrastructure/aws-0/envoy-gateway/vmpodscrape-ratelimit.yaml`
- Modify: `infrastructure/base/envoy-gateway/network-policy.yaml`,
  `clusters/aws-0-ai-gateway/infrastructure-envoy-gateway.yaml`

**Interfaces:**
- Produces:
  - Envoy Gateway's global rate-limit service: Deployment/Service `envoy-ratelimit` in
    `envoy-gateway-system`, gRPC :8081.
  - It is backed by `KVStore` `xplane-ai-gateway-ratelimit` (Service
    `xplane-ai-gateway-ratelimit-valkey:6379`).
  - Any `BackendTrafficPolicy.rateLimit.global` on either Gateway works from then on.
- Consumes: the `KVStore` XRD (`crossplane-configuration`) and `openbao-platform`.

- [ ] **Step 1: Check the overlay is absent.** This is the failing test. Run
  `kustomize build infrastructure/aws-0/envoy-gateway`. Expected: `not a valid directory`.
- [ ] **Step 2: Create the patch.** Create `infrastructure/aws-0/envoy-gateway/helmrelease-ratelimit.yaml`:

```yaml
# Enables Envoy Gateway's global rate limit: the token budgets are rules on it
# (ADR-0050). aws-0 only, because gcp-0 has no store behind it yet.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: envoy-gateway
  namespace: envoy-gateway-system
spec:
  values:
    config:
      envoyGateway:
        rateLimit:
          # failClosed stays false (the default): a store or rate-limit outage
          # admits traffic rather than failing every model call. Budgets bound
          # cost; they are not an availability dependency.
          backend:
            type: Redis
            redis:
              url: xplane-ai-gateway-ratelimit-valkey.envoy-gateway-system.svc.cluster.local:6379
        provider:
          type: Kubernetes
          kubernetes:
            rateLimitDeployment:
              replicas: 1
              container:
                # Envoy Gateway has no auth field for Redis. The rate-limit
                # binary reads REDIS_AUTH from its environment, which is the
                # pattern Envoy Gateway's own test fixtures use (research, R5).
                env:
                  - name: REDIS_AUTH
                    valueFrom:
                      secretKeyRef:
                        name: ai-gateway-ratelimit-valkey
                        key: REDIS_PASSWORD
                # The chart default requests 512Mi and sets no limit.
                resources:
                  requests:
                    cpu: 50m
                    memory: 128Mi
                  limits:
                    memory: 256Mi
```

- [ ] **Step 3: Create the store.** Create `infrastructure/aws-0/envoy-gateway/kvstore.yaml`:

```yaml
# Budget counters. Standalone and ephemeral: a restart resets the day's
# buckets, which costs nothing in shadow mode, and one window of headroom
# once enforced (PR 7 revisits persistence).
apiVersion: cloud.ogenki.io/v1alpha1
kind: KVStore
metadata:
  name: xplane-ai-gateway-ratelimit
  namespace: envoy-gateway-system
spec:
  size: nano
  auth:
    existingSecret: ai-gateway-ratelimit-valkey # pragma: allowlist secret — checkov:skip=CKV_SECRET_6 secret name, not a value
    passwordKey: REDIS_PASSWORD # pragma: allowlist secret
```

- [ ] **Step 4: Create the password secret.** Create
  `infrastructure/aws-0/envoy-gateway/externalsecret-ratelimit-valkey.yaml`:

```yaml
# Read by both ends: the KVStore composition sets it as Valkey's `default`
# password, and the rate-limit Deployment presents it as REDIS_AUTH.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ai-gateway-ratelimit-valkey
  namespace: envoy-gateway-system
spec:
  dataFrom:
    - extract:
        conversionStrategy: Default
        key: ai-gateway/ratelimit-valkey
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao-platform
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
    name: ai-gateway-ratelimit-valkey
```

- [ ] **Step 5: Create the rate-limit pod's policy.** Create
  `infrastructure/aws-0/envoy-gateway/network-policy-ratelimit.yaml`:

```yaml
# Default-deny for Envoy Gateway's rate-limit service. The KVStore composition
# admits 6379 from its whole namespace; every other pod here has default-deny
# egress without 6379, so in practice only this pod reaches Valkey.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: envoy-ratelimit
  namespace: envoy-gateway-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: envoy-ratelimit
      app.kubernetes.io/component: ratelimit
  ingress:
    # Rate-limit checks from every Envoy Gateway data plane: ai-gateway now,
    # agent-router once SP1 ships it. Which budgets apply is decided by each
    # Gateway's policy, not by who may ask.
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            app.kubernetes.io/managed-by: envoy-gateway
            app.kubernetes.io/component: proxy
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    # Kubelet probes on /healthcheck.
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vmagent
      toPorts:
        - ports:
            - port: "19001"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
    # Rate-limit descriptors over xDS from the controller, on Envoy Gateway's
    # second xDS port.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            control-plane: envoy-gateway
      toPorts:
        - ports:
            - port: "18001"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: valkey
            app.kubernetes.io/instance: xplane-ai-gateway-ratelimit-valkey
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
```

- [ ] **Step 6: Scrape the counters.** Create `infrastructure/aws-0/envoy-gateway/vmpodscrape-ratelimit.yaml`:

```yaml
# Shadow-mode counters: the only evidence, during the shadow week, of what the
# budgets WOULD have rejected (SC-3).
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: envoy-ratelimit
  namespace: envoy-gateway-system
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: envoy-ratelimit
      app.kubernetes.io/component: ratelimit
  namespaceSelector:
    matchNames:
      - envoy-gateway-system
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

- [ ] **Step 7: Write the overlay's kustomization.** Create `infrastructure/aws-0/envoy-gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# aws-0 adds the global rate limit and its store to the shared base.
# gcp-0's llm-platform keeps applying ../../base/envoy-gateway unchanged.
resources:
  - ../../base/envoy-gateway
  - kvstore.yaml
  - externalsecret-ratelimit-valkey.yaml
  - network-policy-ratelimit.yaml
  - vmpodscrape-ratelimit.yaml
patches:
  - path: helmrelease-ratelimit.yaml
```

- [ ] **Step 8: Open the base CNPs toward the rate-limit pod.** Rules toward a pod that gcp-0 never
  runs are inert there. In `infrastructure/base/envoy-gateway/network-policy.yaml`:
  - Add to CNP `envoy-gateway-controller` `ingress:`:

```yaml
    # The rate-limit service pulls its descriptors over xDS on 18001. It only
    # exists where an overlay enables the global rate limit (aws-0).
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            app.kubernetes.io/name: envoy-ratelimit
      toPorts:
        - ports:
            - port: "18001"
              protocol: TCP
```

  - Add to CNP `envoy-data-plane` `egress:`:

```yaml
    # Global rate limit (token budgets). A dropped check fails OPEN, so
    # without this rule every budget silently counts nothing.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            app.kubernetes.io/name: envoy-ratelimit
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
```

- [ ] **Step 9: Point the child at the overlay.** In
  `clusters/aws-0-ai-gateway/infrastructure-envoy-gateway.yaml`:
  - Set `path: ./infrastructure/aws-0/envoy-gateway`.
  - Append to `dependsOn:`:

```yaml
    # The KVStore claim needs its XRD.
    - name: crossplane-configuration
```

  In `clusters/aws-0-ai-gateway/README.md`, the `envoy-gateway` row becomes
  `| envoy-gateway | infrastructure/aws-0/envoy-gateway | Envoy Gateway, its global rate limit, and the Valkey KVStore behind it |`,
  with backticks as in the other rows.
- [ ] **Step 10: Check the render.**

  ```bash
  kustomize build infrastructure/aws-0/envoy-gateway | grep -E 'kind: KVStore|name: REDIS_AUTH|url: xplane-ai-gateway-ratelimit'
  ```

  Expected: three lines. Then run `./scripts/ci/validate-manifests.sh` → exit 0,
  `Invalid: 0, Skipped: 0`.
- [ ] **Step 11: Commit.**

  ```bash
  git add infrastructure/aws-0/envoy-gateway infrastructure/base/envoy-gateway/network-policy.yaml clusters/aws-0-ai-gateway
  git commit -m "feat(envoy-gateway): global rate limit on a Valkey KVStore for token budgets"
  ```

### Task 6: Budgets B3–B5 in shadow, price rules, and the frontier spend alert

**Files:**
- Create: `infrastructure/base/llm-gateway/btp-token-budgets.yaml`,
  `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml`
- Modify: `infrastructure/base/llm-gateway/kustomization.yaml`

**Interfaces:**
- Produces:
  - `BackendTrafficPolicy` `ai-gateway-token-budgets` (namespace `envoy-ai-gateway-system`). This is
    the **only** Gateway-level BTP on `ai-gateway`.
  - Recording rule `llm_gateway:price_usd_per_mtoken{gen_ai_request_model, gen_ai_token_type}`.
  - Alert `FrontierSpendGuardTripped`.
- Consumes: the rate-limit service (Task 5), and `llmRequestCosts` on the `llm-gateway` route (Task 4).

- [ ] **Step 1: Write the policy.** The gate's A1/A2 checks are its test. Create
  `infrastructure/base/llm-gateway/btp-token-budgets.yaml`:

```yaml
# Token budgets on the human/system Gateway (design section 6, OD-10, ADR-0050).
# Envoy Gateway accepts ONE Gateway-level BackendTrafficPolicy per Gateway and
# marks a second Conflicted, so B3–B5 are three rules of this one.
#
# All rules: shared (one bucket across every route; the default is a bucket per
# route), costed in tokens from the response (charged after it completes, so a
# stream can overshoot by one response), and in SHADOW for the first week:
# counted, never enforced. Enforcement is SP4 PR 7.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: ai-gateway-token-budgets
  namespace: envoy-ai-gateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
  rateLimit:
    global:
      rules:
        # B3 — each human, from the verified OIDC sub (the oidc listener, PR 2).
        - clientSelectors:
            - headers:
                - name: x-ar-human
                  type: Distinct
          limit:
            requests: 10000000
            unit: Day
          cost:
            request:
              from: Number
              number: 0
            response:
              from: Metadata
              metadata:
                namespace: io.envoy.ai_gateway
                key: llm_total_token
          shared: true
          shadowMode: true
        # B4 — each API-key client (RunLore, OpenWebUI, promptfoo), from the
        # client id apiKeyAuth forwards after matching the key.
        - clientSelectors:
            - headers:
                - name: x-ai-gateway-client-id
                  type: Distinct
          limit:
            requests: 5000000
            unit: Day
          cost:
            request:
              from: Number
              number: 0
            response:
              from: Metadata
              metadata:
                namespace: io.envoy.ai_gateway
                key: llm_total_token
          shared: true
          shadowMode: true
        # B5 — kill switch on all human and system frontier spend together.
        - clientSelectors:
            - headers:
                - name: x-ai-eg-model
                  type: RegularExpression
                  value: "^(tier-frontier|claude-.*)$"
          limit:
            requests: 20000000
            unit: Day
          cost:
            request:
              from: Number
              number: 0
            response:
              from: Metadata
              metadata:
                namespace: io.envoy.ai_gateway
                key: llm_total_token
          shared: true
          shadowMode: true
```

- [ ] **Step 2: Write the rules.** Create `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: llm-gateway
  namespace: observability
  labels:
    app.kubernetes.io/part-of: ai
spec:
  groups:
    # List price per 1M tokens, keyed by the model actually served
    # (gen_ai_request_model, after modelNameOverride). This is data, not a
    # measurement: SP3's cost reports and the routing dashboard multiply token
    # counters by it. Cached-input prices are left out, because budgets assume
    # no cache discount (design section 6).
    - name: llm-gateway-prices
      interval: 5m
      rules:
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(1.40)
          labels:
            gen_ai_request_model: "glm-5.2"
            gen_ai_token_type: input
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(4.40)
          labels:
            gen_ai_request_model: "glm-5.2"
            gen_ai_token_type: output
    - name: llm-gateway-budgets
      rules:
        - alert: FrontierSpendGuardTripped
          # Mirrors B5 from the gen_ai counters, so it also fires in shadow
          # mode, where the limiter never answers 429. A rolling 24 h covers at
          # least the limiter's fixed UTC day, so this fires no later than B5
          # would trip.
          expr: |
            sum(increase(gen_ai_client_token_usage_sum{gen_ai_original_model=~"tier-frontier|claude-.*"}[24h])) > 20e6
          for: 5m
          labels:
            severity: warning
            component: ai
          annotations:
            summary: "Human and system frontier spend crossed the B5 guard (20M tokens in 24h)"
            description: |
              tier-frontier and claude-* traffic on the ai-gateway Gateway used more than
              20M tokens over the last 24h. B5 in ai-gateway-token-budgets would reject
              further frontier requests once enforced. Split by principal with the
              ar_human and ar_client labels on gen_ai_client_token_usage_sum.
```

- [ ] **Step 3: Add both files** to `infrastructure/base/llm-gateway/kustomization.yaml` `resources:`:
  `- btp-token-budgets.yaml` and `- vmrule-llm-gateway.yaml`.
- [ ] **Step 4: Prove the gate guards the policy.** Temporarily set `shared: false` on B4 and run
  `./scripts/ci/validate-manifests.sh`. Expected: exit 1 with
  `FAIL BackendTrafficPolicy envoy-ai-gateway-system/ai-gateway-token-budgets rule 1: shared must be true…`.
  Revert the edit, and do not commit it.
- [ ] **Step 5: Validate.**
  - `./scripts/ci/validate-vmrules.sh` → exit 0.
  - `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`, `0 violations`.
- [ ] **Step 6: Commit.**

  ```bash
  git add infrastructure/base/llm-gateway
  git commit -m "feat(llm-gateway): token budgets B3-B5 in shadow, price rules and the frontier spend alert"
  ```

### Task 7: ADR-0046 (frontier providers) and ADR-0050 (token budgets)

**Files:**
- Create: `website/content/docs/decisions/0046-frontier-providers-zai-and-bedrock.md`,
  `website/content/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md`
- Modify: `website/content/docs/decisions/_index.md` (two table rows)

**Interfaces:** None in code. PR 2 and later PRs cite these ADRs.

- [ ] **Step 1: Write ADR-0046.** Start from `website/content/docs/decisions/template.md`. The
  complete file:

```markdown
---
title: Frontier models through Z.ai and Anthropic on Bedrock, behind the gateways
linkTitle: 0046 · Frontier providers
weight: 460
description: Frontier models reach the platform through two providers chosen by data class — Z.ai GLM for public data, with its key held by the gateways, and Anthropic's Claude on Amazon Bedrock EU for internal data, with no key at all (EKS Pod Identity). A native Anthropic API key and aggregators such as OpenRouter were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted
**Date**: 2026-09-25
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP4 — LLM complexity routing](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md)

---

## Context

Agents need a capable model with zero GPUs, and hard chat prompts need one above the local 7–8B fleet.
Until now the only frontier caller was RunLore, holding a Z.ai key in its own pod. The agent factory
adds a data-class rule: `public` agent work may go to a SaaS model, while `internal` data (cluster
reads, RunLore findings) may reach only EU-resident Anthropic or self-hosted models.

## Decision Drivers

- No provider key in any workload pod; keys live only where the gateways read them.
- Internal data stays in EU regions.
- Both client formats: OpenAI (OpenWebUI, OpenCode) and Anthropic (Claude Code).
- Cost: GLM-5.2 is $1.40 / $4.40 per 1M tokens; Claude Opus 5.5 is $4 / $20.

## Considered Options

### Option 1: Z.ai GLM + Anthropic on Bedrock (Pod Identity) / Vertex (Workload Identity)

**Pros**:
- Bedrock needs no key: the data plane's ServiceAccount assumes a role scoped to the `eu.anthropic.*`
  inference profiles.
- Agent Router translates both OpenAI and Anthropic input to Bedrock's `AWSAnthropic` schema.

**Cons**:
- EU geo profiles route across EU regions (Frankfurt, Paris, Stockholm, Milan, Spain, Ireland), not
  Paris alone.
- Bedrock is billed through AWS Marketplace, and model access needs a one-time subscription.

### Option 2: A native Anthropic API key

**Pros**:
- The simplest setup, and it gets new models first.

**Cons**:
- Agent Router v1.1.0 has **no** OpenAI → native-Anthropic translator (PR #2127 is open), so
  OpenAI-format clients cannot reach it.
- A long-lived key to hold and rotate.

### Option 3: OpenRouter or another aggregator

**Pros**:
- One key and many models.

**Cons**:
- A third party sees every prompt, and data residency is the aggregator's choice.
- It adds a hop and a markup.

### Option 4: Self-hosted only

**Pros**:
- No data leaves the cluster.

**Cons**:
- The fleet's 7–8B models are not agent-capable. It also ties agents to GPU capacity, which the
  programme exists to avoid.

## Decision Outcome

**Chosen option**: "Option 1"

**Rationale**: It is the only option that serves both client formats with no key in a workload pod,
and keeps internal data in the EU. Z.ai serves public work at roughly a third of Claude Opus 5.5's
list input price.

## Consequences

### Positive

- Separate keys per Gateway (the platform key under `platform/llm/zai`, the agents' key under
  `platform/agents/zai`) split both spend and blast radius.
- Bedrock credentials rotate themselves and cannot be exfiltrated as a string.

### Negative

- Z.ai's processing and retention terms are unverified (research, open question 10). That is why
  only `public` data may reach it.
- A Bedrock Marketplace subscription is an owner action per account.

### Neutral

- gcp-0 reaches the same Claude models through Vertex with Workload Identity (`GCPAnthropic`), in a
  follow-up.

---

## Implementation Notes

- SP4 PR 1: the platform Z.ai backend and `tier-frontier` on `ai-gateway`.
- SP4 PR 2: the Bedrock EPIs, `claude-*` on `ai-gateway`, and the agent tiers on `agent-router`.

---

## References

- [Agent Router v1.1.0 translators](https://github.com/theagentrouter/agent-router/blob/v1.1.0/internal/endpointspec/endpointspec.go)
- [Bedrock model cards](https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards.html)
- [Z.ai pricing](https://docs.z.ai/guides/overview/pricing)
```

- [ ] **Step 2: Write ADR-0050.** The complete file:

```markdown
---
title: Token budgets on Envoy Gateway's global rate limit, costed from response metadata
linkTitle: 0050 · Token budgets
weight: 500
description: Per-run, per-fleet, per-human and per-client daily token budgets are Envoy Gateway global rate-limit rules, charged after each response with the token count Agent Router writes into metadata, and stored in a Valkey KVStore. Agent Router's QuotaPolicy, a custom ext_proc and LiteLLM budgets were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted
**Date**: 2026-09-25
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP4 — LLM complexity routing](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md)

---

## Context

Frontier models cost real money, and a looping agent is a denial-of-wallet. Every principal needs a
daily token cap: a run, the agent fleet, each human, each API-key client, plus a kill switch on
frontier spend. They must be enforced at the gateways, the only path to a provider.

## Decision Drivers

- Enforced synchronously in the data path, with no custom data-path code.
- Keyed on identity headers set from a verified credential.
- One bucket per principal across every route the principal can reach.

## Considered Options

### Option 1: Envoy Gateway global rate limit, cost from response metadata, Valkey

**Pros**:
- A GA Envoy Gateway API. Agent Router's `llmRequestCosts` writes the token count into metadata, which
  the rule charges after the response.
- `shared: true` gives one bucket across routes, and `shadowMode` gives a measured dry run.

**Cons**:
- Charged after the response, so an admitted stream can overshoot by one response.
- Windows are fixed UTC days, not sliding.

### Option 2: Agent Router `QuotaPolicy`

**Pros**:
- Purpose-built for token quotas.

**Cons**:
- `v1alpha1` and partly unimplemented: `ServiceQuota` is not wired.
- In its only mode (Shared), a request passes if **any** matching bucket has room, so a per-principal
  cap never binds while a default bucket has headroom.

### Option 3: A custom ext_proc

**Pros**:
- Exact per-run caps with any logic.

**Cons**:
- Custom code in the data path of every request, and a new SPOF.

### Option 4: LiteLLM budgets

**Pros**:
- Mature budget features.

**Cons**:
- A second proxy in front of or behind Agent Router, duplicating routing, auth and keys.

## Decision Outcome

**Chosen option**: "Option 1"

**Rationale**: It enforces in the data path with GA APIs and no custom code, and `shared` plus
`shadowMode` make it both correct and safe to roll out.

## Consequences

### Positive

- A breach answers `429` before any provider token is spent on the next request.
- Shadow counters measure every rule for a week before enforcement.

### Negative

- The exact per-run cap (`spec.budget.maxTokens`) cannot live at the gateway, because a
  ServiceAccount token carries only `sub`. The gateway holds a 5M ceiling, and SP3's run meter revokes
  a run at its own cap.
- A store outage admits traffic (`failClosed: false`).
- Envoy Gateway accepts one Gateway-level `BackendTrafficPolicy` per Gateway, so all of a Gateway's
  budgets live in one object.

### Neutral

- Every rule must set `shared: true`. A render gate (`scripts/ci/flux-schema/assert-ai-gateway.py`)
  fails the build otherwise.

---

## Implementation Notes

- SP4 PR 1: the rate limit, the `KVStore`, and B3–B5 on `ai-gateway`, all in shadow.
- SP4 PR 2: B1–B2 on `agent-router`, in shadow.
- SP4 PR 7: enforcement.

---

## References

- [Agent Router usage-based rate limiting](https://github.com/theagentrouter/agent-router/blob/v1.1.0/site/docs/capabilities/traffic/usage-based-ratelimiting.md)
- [Envoy Gateway global rate limit](https://gateway.envoyproxy.io/docs/tasks/traffic/global-rate-limit/)
```

- [ ] **Step 3: Add the index rows.** Append two rows to the table in
  `website/content/docs/decisions/_index.md`, after 0040. 0041–0045 and 0047–0049 are reserved for
  other sub-projects, so the gaps are expected.

```markdown
| [0046]({{< relref "/docs/decisions/0046-frontier-providers-zai-and-bedrock.md" >}}) | Frontier models through Z.ai and Anthropic on Bedrock, behind the gateways | Accepted | 2026-09-25 |
| [0050]({{< relref "/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md" >}}) | Token budgets on Envoy Gateway's global rate limit, costed from response metadata | Accepted | 2026-09-25 |
```

- [ ] **Step 4: Validate.** Run `./scripts/ci/validate-links.sh` (exit 0) and
  `./scripts/ci/verify-doc-paths.sh` (exit 0).
- [ ] **Step 5: Commit.**

  ```bash
  git add website/content/docs/decisions
  git commit -m "docs(adr): 0046 frontier providers and 0050 token budgets"
  ```

### Task 8: Docs, final validation, live verification, and PR 1

**Files:**
- Modify: `website/content/docs/platform/ai-platform/gateway-and-routing.md`

**Interfaces:** None. This task closes PR 1.

- [ ] **Step 1: Document the frontier route and the budgets.** In `gateway-and-routing.md`, add
  before `## Known gaps`:

````markdown
## Frontier models and token budgets

`tier-frontier` is served by GLM-5.2 through Z.ai with the **platform** key, which only the gateway
holds. It needs no GPU, so it answers with `llm-platform` suspended.

```bash
curl -s https://llm.priv.aws.ogenki.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" -H "Content-Type: application/json" \
  -d '{"model": "tier-frontier", "messages": [{"role": "user", "content": "Say hi"}]}'
```

The gateway strips `x-ar-agent`, `x-ar-human` and `x-ai-gateway-client-id` from every request before
authentication, then sets them from the verified credential. A client cannot choose whose budget it
spends. Daily token budgets per API-key client (5M), per human (10M) and on all frontier spend (20M)
are counted in **shadow mode**: nothing is rejected yet
([ADR-0050]({{< relref "/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md" >}})).
````

- [ ] **Step 2: Rebase and run every gate.** Invoke the `sync-branch` skill (fetch, then rebase onto
  `origin/main`). Then run each command and cite its output:
  - `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`,
    `ai-gateway invariants: 2 checks, 0 violations`;
  - `task check` → exit 0;
  - `./scripts/ci/validate-links.sh` → exit 0.
- [ ] **Step 3: Commit.**

  ```bash
  git add website/content/docs/platform/ai-platform/gateway-and-routing.md
  git commit -m "docs(ai-platform): tier-frontier and token budgets on the ai-gateway Gateway"
  ```

- [ ] **Step 4: Nothing to seed** (O1 and O2 superseded 2026-09-26). A bootstrap must be one
  `terramate script run deploy`. Instead, check that both Secrets exist once `ai-gateway` is resumed:

  ```bash
  kubectl get externalsecret -n llm-gateway zai-api-key -o jsonpath='{.status.conditions[0].reason}{"\n"}'
  kubectl get externalsecret -n envoy-gateway-system ai-gateway-ratelimit-valkey -o jsonpath='{.status.conditions[0].reason}{"\n"}'
  ```

  Expected: `SecretSynced` for both.
- [ ] **Step 5 [OWNER] O3: Re-check the precondition** on every running aws-0, with Task 0 Step 5's
  commands. Expected: `llm-platform` suspended.
- [ ] **Step 6 [LIVE] L1: Deploy the branch.**

  Deploy this branch, or the `integration/agent-factory` branch that carries it:

  ```bash
  cd opentofu && TF_VAR_flux_git_ref='refs/heads/feat/ai-gateway-frontier' terramate script run deploy
  ```

  Then confirm that a default deploy leaves the umbrella suspended, resume it, and check that the
  resume survives the next `flux-system` reconcile:

  ```bash
  flux get kustomizations -n flux-system ai-gateway          # SUSPENDED True
  flux resume kustomization ai-gateway -n flux-system
  flux reconcile kustomization flux-system -n flux-system --with-source
  flux get kustomizations -n flux-system | grep -E '^(ai-gateway|envoy-gateway|envoy-ai-gateway|vllm-semantic-router|llm-gateway|llm-platform)\b'
  ```

  Expected: `ai-gateway` still `False` in the SUSPENDED column after the parent reconcile. Every row
  is `True` except `llm-platform`, which stays suspended.
- [ ] **Step 7 [LIVE]: Ownership and zero GPUs.**

  ```bash
  kubectl get kustomization -n flux-system envoy-gateway envoy-ai-gateway vllm-semantic-router \
    -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}'
  kubectl get nodes -l karpenter.sh/nodepool=gpu-l4 --no-headers | wc -l
  kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ai-gateway --no-headers | wc -l
  ```

  Expected:
  - each child `=ai-gateway`;
  - `0` GPU nodes;
  - at least `1` proxy pod.

  The last check matters because the narrowed `envoy-data-plane` policy selects on that label. If no
  pod carries it, no policy selects the proxies, and Cilium then **allows everything** rather than
  denying.
- [ ] **Step 8 [LIVE]: Check the store and the policy.**

  ```bash
  kubectl get kvstore -n envoy-gateway-system xplane-ai-gateway-ratelimit
  kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/name=envoy-ratelimit
  kubectl get btp -n envoy-ai-gateway-system ai-gateway-token-budgets \
    -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
  ```

  Expected: `READY True`, `Running 1/1`, and `Accepted=True`. Neither `Conflicted` nor `Invalid`.
  If the Valkey pod is rejected by PSS `restricted` admission, that fix belongs in the KVStore
  composition (crossplane-configuration), not here.
- [ ] **Step 9 [LIVE]: SC-1 gateway half.** From a tailnet host, with the promptfoo key from AWS SM
  `platform-llm-api-keys`:

  ```bash
  curl -s https://llm.priv.aws.ogenki.io/v1/chat/completions -H "Authorization: Bearer $LLM_API_KEY" \
    -H "Content-Type: application/json" -H "x-ai-gateway-client-id: forged" \
    -d '{"model":"tier-frontier","messages":[{"role":"user","content":"Reply with the word ok"}]}' | jq '.model, .usage'
  ```

  Expected: `"glm-5.2"` and a non-zero usage block. This also verifies the `/api/paas/v4` prefix.
- [ ] **Step 10 [LIVE]: SC-2, human/system half.** Query VictoriaMetrics
  `sum by (ar_client) (gen_ai_client_token_usage_sum{gen_ai_original_model="tier-frontier"})`.
  Expected: a `promptfoo` series and **no** `forged` series.
- [ ] **Step 11 [LIVE]: Tokens are charged, in shadow.**

  ```bash
  kubectl -n envoy-gateway-system port-forward deploy/envoy-ratelimit 19001 &
  curl -s localhost:19001/metrics | grep -E 'total_hits|shadow_mode' | head
  ```

  Expected: counters above 0 after Step 9. Record the metric names you find in the PR body: they are
  what PR 7's shadow-week analysis reads.
- [ ] **Step 12 [LIVE]: The R5 marker probe.** SC-3's marker half runs as a temporary, route-level
  policy on the generated HTTPRoute. A route-level BTP overrides the Gateway-level one for that route
  for the probe's minute. Nothing else changes.

  ```bash
  kubectl apply -f - <<'EOF'
  apiVersion: gateway.envoyproxy.io/v1alpha1
  kind: BackendTrafficPolicy
  metadata:
    name: zz-budget-marker-probe
    namespace: llm-gateway
  spec:
    targetRefs:
      - group: gateway.networking.k8s.io
        kind: HTTPRoute
        name: llm-gateway
    rateLimit:
      global:
        rules:
          - clientSelectors:
              - headers:
                  - name: x-budget-probe
                    type: Exact
                    value: marker
            limit: {requests: 1, unit: Hour}
            cost:
              request: {from: Number, number: 0}
              response: {from: Metadata, metadata: {namespace: io.envoy.ai_gateway, key: llm_total_token}}
            shared: true
  EOF
  for i in 1 2; do curl -s -o /dev/null -D - https://llm.priv.aws.ogenki.io/v1/chat/completions \
    -H "Authorization: Bearer $LLM_API_KEY" -H "Content-Type: application/json" -H "x-budget-probe: marker" \
    -d '{"model":"tier-frontier","messages":[{"role":"user","content":"ok"}]}' | grep -iE '^HTTP|x-envoy-ratelimited'; done
  kubectl delete btp -n llm-gateway zz-budget-marker-probe
  ```

  Expected: first `HTTP/2 200`, then `HTTP/2 429` with `x-envoy-ratelimited: true`. If the header is
  absent, record R5 as closed negative in the PR. SP1's harness must then detect a budget 429 by
  `x-ratelimit-reset` instead: raise it with the lead.
- [ ] **Step 13 [OWNER]: Tear down or keep.** The owner decides whether to keep the branch cluster for
  PR 2 or destroy it: `terramate script run --reverse destroy`, then sweep leftovers per memory.
- [ ] **Step 14: Open PR 1.** Invoke the `ship-it` skill. The PR body carries:
  - the design link;
  - the mermaid of the umbrella split, copied from the design's *Architecture* section;
  - the Task 0 precondition result;
  - Steps 6–12's outputs;
  - the rollback below;
  - the note that O1 **copies** the key: `runlore/credentials` keeps it until PR 6 (SC-10).

  The PR waits for owner review, because it holds docs.

**Rollback for PR 1.**

- **Preferred: fix forward.** It is always safe, because the children kept their names.
- **Full revert:** `git revert` the merge commit.
  - `flux-system` then deletes the `ai-gateway` object, and `deletionPolicy: Orphan` leaves its four
    children running.
  - `envoy-gateway` then fails to build, because its overlay path is gone. It keeps its last applied
    state and does not prune.
  - Finish with `flux delete kustomization llm-gateway -n flux-system` (it removes the Z.ai route and
    the budget policy) and
    `kubectl patch kustomization envoy-gateway -n flux-system --type=merge -p '{"spec":{"path":"./infrastructure/base/envoy-gateway"}}'`.
  - The three moved children then run orphaned until `llm-platform` is next resumed. It re-adopts
    them, because the revert restored them to its directory.
  - Revert while `llm-platform` is **still suspended**, for the same reason as the move.

---

## PR 2 — agent tiers, Bedrock EU, B1–B2 in shadow, the `oidc` listener

### Interfaces with SP1

PR 2 builds on objects that SP1 phase 3 creates, named as in SP1's plan
(`docs/superpowers/plans/2026-09-25-agent-runtime-identity-plan.md`, phase 3). Check every row against
SP1's merged code before Task 9.

| # | Assumed here | Used in |
|---|---|---|
| I1 | Flux Kustomization `agent-router` creates Gateway `agent-router`, file `clusters/aws-0-agent-platform/infrastructure-agent-router.yaml`, path `./infrastructure/base/agent-router`, `dependsOn` `envoy-ai-gateway` and `agent-secrets` | 12 (`dependsOn`) |
| I2 | `EnvoyProxy` `agent-router-proxy` in `agent-system`, file `infrastructure/base/agent-router/envoyproxy.yaml`. SP1 does **not** set `envoyServiceAccount` | 12 |
| I3 | `AIGatewayRoute` `agent-models` in `agent-system`, file `infrastructure/base/agent-router/aigatewayroute-agent-models.yaml`, `parentRefs` `{name: agent-router, sectionName: public}`. SP4 owns its content from this PR | 12 |
| I4 | The agents' Z.ai `AIServiceBackend` `zai` in `agent-system` (file `backend-zai.yaml`). Its `BackendSecurityPolicy` is `zai-api-key`, fed by Secret `agents-zai-api-key` from SecretStore `agents-secrets` (`agents/zai`). SP4 references only the `AIServiceBackend`. SP4's own `zai-api-key` Secret lives in `llm-gateway` and is a different object | 12 |
| I5 | Listeners `public` :8080 and `internal` :8081. Data-plane Service `agent-router` in `envoy-gateway-system`. Proxy pods labelled `gateway.envoyproxy.io/owning-gateway-name: agent-router` | 12, 15 |
| I6 | SP1's whole-Gateway `ClientTrafficPolicy` on `agent-router` removes all four identity headers. Gate A3 fails SP1's own CI otherwise | 9 |
| I7 | SP4 owns the **only** Gateway-level `BackendTrafficPolicy` on `agent-router` (`agent-router-token-budgets`). SP1 adds none, route-level included: a route-level policy would replace it for that route | 13 |
| I8 | SP1's probe sandbox `agent-probe` in `agents` (`scripts/ops/k8s/agent-probe.yaml`), ServiceAccount `agent-probe`, with tokens at `/var/run/secrets/probe/{public,internal}/token` | 15 |
| I9 | PR 1 already narrowed `envoy-data-plane` to `ai-gateway` (Task 4 Step 8). SP1 ships its own `agent-router` data-plane CNP and does not re-narrow | — |
| I10 | SP1's data-plane CNP `agent-router-data-plane`, file `infrastructure/base/agent-router/network-policy-data-plane.yaml`, already allows DNS inspection, vmagent → :1064 and `api.z.ai`. SP4 PR 2 adds the Bedrock and Pod Identity egress (Task 12) and the rate-limit egress (Task 13) to it | 12, 13 |

### Task 9: Gate A4–A5 — agent pinning, and Z.ai on `public` only

**Files:**
- Modify: `scripts/ci/flux-schema/assert-ai-gateway.py`,
  `scripts/ci/tests/flux-schema/test-assert-ai-gateway.py`

**Interfaces:**
- Produces: `check_agent_pinning(objs) -> list[str]` and `check_zai_public_only(objs) -> list[str]`,
  both appended to `CHECKS`. The gate now reports `4 checks`.
- Consumes: the Task 1 module.

- [ ] **Step 1: Create the PR 2 worktree.** Call `EnterWorktree` with name `agent-frontier-tiers`, then
  `git branch -m feat/agent-frontier-tiers`. Confirm that PR 1 and SP1 phase 3 are both on
  `origin/main`:

  ```bash
  git log --oneline origin/main -- clusters/aws-0/ai-gateway.yaml | head -1
  git ls-tree origin/main clusters/aws-0-agent-platform/
  ```

  Both must print something. Then reconcile I1–I9.
- [ ] **Step 2: Write the failing tests.** Append to `test-assert-ai-gateway.py`, **before** the
  `if FAILURES:` block:

```python
print("A4 — agent routes are pinned")


def route(name, rules, section="public", gw="agent-router", ns="agent-system"):
    parent = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw}
    if section:
        parent["sectionName"] = section
    return {"apiVersion": "aigateway.envoyproxy.io/v1beta1", "kind": "AIGatewayRoute",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"parentRefs": [parent], "rules": rules}}


def rrule(name, *refs):
    return {"name": name,
            "matches": [{"headers": [{"type": "Exact", "name": "x-ai-eg-model", "value": name}]}],
            "backendRefs": list(refs)}


PINNED = {"name": "zai", "modelNameOverride": "glm-5.2", "weight": 100}
check("one backend at 100 passes",
      gate.check_agent_pinning([route("agent-models", [rrule("tier-frontier", PINNED)])]) == [])
errs = gate.check_agent_pinning([route("agent-models", [rrule("tier-frontier", PINNED, dict(PINNED, name="b"))])])
check("two backends fail", len(errs) == 1 and "exactly one backendRef" in errs[0], str(errs))
check("weight 50 fails",
      len(gate.check_agent_pinning([route("agent-models", [rrule("t", dict(PINNED, weight=50))])])) == 1)
no_weight = dict(PINNED)
del no_weight["weight"]
check("absent weight fails (Agent Router defaults it to 1)",
      len(gate.check_agent_pinning([route("agent-models", [rrule("t", no_weight)])])) == 1)
check("a priority fails (it is cross-model failover)",
      len(gate.check_agent_pinning([route("agent-models-internal", [rrule("t", dict(PINNED, priority=1))])])) == 1)
check("other routes are out of scope",
      gate.check_agent_pinning([route("llm-fleet", [rrule("t", PINNED, PINNED)])]) == [])

print("A5 — Z.ai only on public listeners")


def backend(name, host, ns="agent-system"):
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "Backend",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"endpoints": [{"fqdn": {"hostname": host, "port": 443}}]}}


def aisb(name, backend_name, ns="agent-system"):
    return {"apiVersion": "aigateway.envoyproxy.io/v1beta1", "kind": "AIServiceBackend",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"schema": {"name": "OpenAI"},
                     "backendRef": {"group": "gateway.envoyproxy.io", "kind": "Backend", "name": backend_name}}}


BACKENDS = [backend("zai", "api.z.ai"), aisb("zai", "zai"),
            backend("bedrock-eu-west-3", "bedrock-runtime.eu-west-3.amazonaws.com"),
            aisb("bedrock-anthropic", "bedrock-eu-west-3")]
BEDROCK = {"name": "bedrock-anthropic", "weight": 100}
check("Z.ai on public passes",
      gate.check_zai_public_only(BACKENDS + [route("agent-models", [rrule("t", PINNED)], section="public")]) == [])
check("Bedrock on internal passes",
      gate.check_zai_public_only(BACKENDS + [route("agent-models-internal", [rrule("t", BEDROCK)],
                                                   section="internal")]) == [])
errs = gate.check_zai_public_only(BACKENDS + [route("agent-models-internal", [rrule("t", PINNED)],
                                                    section="internal")])
check("Z.ai on internal fails, naming the listener", len(errs) == 1 and "internal" in errs[0], str(errs))
errs = gate.check_zai_public_only(BACKENDS + [route("agent-models", [rrule("t", PINNED)], section=None)])
check("Z.ai with no sectionName fails (it attaches to every listener)",
      len(errs) == 1 and "every listener" in errs[0], str(errs))
check("routes on other Gateways are out of scope",
      gate.check_zai_public_only(BACKENDS + [route("llm-gateway", [rrule("t", PINNED)], section=None,
                                                   gw="ai-gateway", ns="agent-system")]) == [])
```

- [ ] **Step 3: Watch them fail.** Run the suite. Expected:
  `AttributeError: module 'assert_ai_gateway' has no attribute 'check_agent_pinning'`.
- [ ] **Step 4: Implement both checks.** In `assert-ai-gateway.py`, add A4 and A5 to the module
  docstring:

  ```
    A4  Every rule of the agent model maps (agent-models, agent-models-internal)
        has exactly one backendRef at weight 100 and no priority: nothing may
        re-route a run's trajectory (design S7).
    A5  An AIGatewayRoute on agent-router that reaches api.z.ai attaches to the
        `public` listener only, so an `internal` token has no path to Z.ai
        (design S13, OD-13).
  ```

  Then add these definitions above `CHECKS`:

```python
PINNED_ROUTES = ("agent-models", "agent-models-internal")
AGENT_GATEWAY = "agent-router"
ZAI_HOST = "api.z.ai"


def check_agent_pinning(objs):
    errors = []
    for obj in objs:
        if obj.get("kind") != "AIGatewayRoute" or (obj.get("metadata") or {}).get("name") not in PINNED_ROUTES:
            continue
        for i, rule in enumerate(spec_of(obj).get("rules") or []):
            where = f"{ref(obj)} rule {rule.get('name', i)}"
            refs = rule.get("backendRefs") or []
            if len(refs) != 1:
                errors.append(f"{where}: exactly one backendRef required, found {len(refs)}")
                continue
            if refs[0].get("weight") != 100:
                errors.append(f"{where}: weight must be 100")
            if "priority" in refs[0]:
                errors.append(f"{where}: priority is a cross-model failover; agent routes allow none")
    return errors


def _hosts_by_service_backend(objs):
    backend_hosts = {}
    for obj in objs:
        if obj.get("kind") == "Backend":
            meta = obj.get("metadata") or {}
            for endpoint in spec_of(obj).get("endpoints") or []:
                host = (endpoint.get("fqdn") or {}).get("hostname")
                if host:
                    backend_hosts.setdefault((meta.get("namespace", ""), meta.get("name")), set()).add(host)
    hosts = {}
    for obj in objs:
        if obj.get("kind") == "AIServiceBackend":
            meta = obj.get("metadata") or {}
            ns = meta.get("namespace", "")
            target = spec_of(obj).get("backendRef") or {}
            hosts.setdefault((ns, meta.get("name")), set()).update(
                backend_hosts.get((target.get("namespace") or ns, target.get("name")), set()))
    return hosts


def check_zai_public_only(objs):
    hosts = _hosts_by_service_backend(objs)
    errors = []
    for obj in objs:
        if obj.get("kind") != "AIGatewayRoute":
            continue
        ns = (obj.get("metadata") or {}).get("namespace", "")
        parents = [p for p in spec_of(obj).get("parentRefs") or [] if p.get("name") == AGENT_GATEWAY]
        if not parents:
            continue
        reaches_zai = any(ZAI_HOST in hosts.get((b.get("namespace") or ns, b.get("name")), set())
                          for rule in spec_of(obj).get("rules") or []
                          for b in rule.get("backendRefs") or [])
        wrong = [p.get("sectionName") or "every listener" for p in parents if p.get("sectionName") != "public"]
        if reaches_zai and wrong:
            errors.append(f"{ref(obj)}: reaches {ZAI_HOST} but attaches to agent-router "
                          f"{', '.join(wrong)}; Z.ai is public-only")
    return errors
```

  Finally, set `CHECKS = [check_rate_limit_rules, check_identity_strips, check_agent_pinning, check_zai_public_only]`.
  In `scripts/AGENTS.md`, extend Gate 3's row with `, agent routes pinned (one backend at 100 %, no priority), Z.ai only on public agent-router listeners`.
- [ ] **Step 5: Run the suite again.** Expected: `all passed`. Then run `./scripts/ci/validate-manifests.sh`.
  Expected: exit 0, `4 checks, 0 violations`. SP1's `agent-models` seed is pinned and on `public`; if
  it is not, that is an SP1 defect, so raise it.
- [ ] **Step 6: Commit.**

  ```bash
  git add scripts/ci scripts/AGENTS.md
  git commit -m "feat(ci): gate agent model routes on pinning and public-only Z.ai"
  ```

### Task 10: Bedrock identities — two EPIs and the `ai-gateway` data-plane ServiceAccount

**Files:**
- Create: `security/base/epis-ai-gateway/kustomization.yaml`,
  `security/base/epis-ai-gateway/ai-gateway-bedrock.yaml`,
  `security/base/epis-ai-gateway/agent-router-bedrock.yaml`,
  `clusters/aws-0-ai-gateway/security-ai-gateway-epi.yaml`,
  `infrastructure/aws-0/envoy-ai-gateway/kustomization.yaml`,
  `infrastructure/aws-0/envoy-ai-gateway/network-policy-aws.yaml`
- Modify: `clusters/aws-0-ai-gateway/kustomization.yaml`,
  `clusters/aws-0-ai-gateway/infrastructure-envoy-ai-gateway.yaml`,
  `clusters/aws-0-ai-gateway/README.md`

**Interfaces:**
- Produces:
  - EPIs `xplane-ai-gateway-bedrock` and `xplane-agent-router-bedrock` (namespace `security`), bound to
    the ServiceAccounts of the same names in `envoy-gateway-system`.
  - Flux child `ai-gateway-security-epi` (`wait: true`).
  - The `ai-gateway` proxies run as `xplane-ai-gateway-bedrock` and may reach Bedrock and the Pod
    Identity agent.
- Consumes: the `EPI` XRD, and `eks-pod-identities` (existing).

- [ ] **Step 1: Check the ServiceAccount is absent.** This is the failing test.

  ```bash
  kustomize build infrastructure/aws-0/envoy-ai-gateway 2>&1 | grep -c 'name: xplane-ai-gateway-bedrock'   # error / 0
  ```

- [ ] **Step 2: Write the `ai-gateway` EPI.** Create `security/base/epis-ai-gateway/ai-gateway-bedrock.yaml`:

```yaml
# Keyless Claude on Bedrock EU for the ai-gateway data plane (ADR-0046).
# Envoy Gateway creates ServiceAccount xplane-ai-gateway-bedrock itself, from
# EnvoyProxy ai-gateway-proxy (infrastructure/aws-0/envoy-ai-gateway).
#
# Policy shape, verified against a live call in SP4 PR 2 (design R7):
#   - the three EU geo inference profiles, callable from eu-west-3;
#   - their foundation models in EU regions ONLY THROUGH those profiles
#     (bedrock:InferenceProfileArn): a cross-region profile invokes the model
#     in whichever EU region serves it, and IAM checks that call too.
apiVersion: cloud.ogenki.io/v1alpha1
kind: EPI
metadata:
  name: xplane-ai-gateway-bedrock
spec:
  clusters:
    - name: "aws-0"
      region: "eu-west-3"
  serviceAccount:
    name: xplane-ai-gateway-bedrock
    namespace: envoy-gateway-system
  policyDocument: |
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "InvokeEuAnthropicInferenceProfiles",
                "Effect": "Allow",
                "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
                "Resource": [
                    "arn:aws:bedrock:eu-west-3:${aws_account_id}:inference-profile/eu.anthropic.claude-opus-5-5",
                    "arn:aws:bedrock:eu-west-3:${aws_account_id}:inference-profile/eu.anthropic.claude-sonnet-5",
                    "arn:aws:bedrock:eu-west-3:${aws_account_id}:inference-profile/eu.anthropic.claude-haiku-4-5-20251001-v1:0"
                ]
            },
            {
                "Sid": "InvokeTheirEuModelsThroughTheProfilesOnly",
                "Effect": "Allow",
                "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
                "Resource": [
                    "arn:aws:bedrock:eu-*::foundation-model/anthropic.claude-opus-5-5*",
                    "arn:aws:bedrock:eu-*::foundation-model/anthropic.claude-sonnet-5*",
                    "arn:aws:bedrock:eu-*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
                ],
                "Condition": {
                    "StringLike": {
                        "bedrock:InferenceProfileArn": "arn:aws:bedrock:eu-west-3:${aws_account_id}:inference-profile/eu.anthropic.*"
                    }
                }
            }
        ]
    }
```

- [ ] **Step 3: Write the `agent-router` EPI.** Create `security/base/epis-ai-gateway/agent-router-bedrock.yaml`
  with the same content, except:
  - the header comment's first two lines become `# Keyless Claude on Bedrock EU for the agent-router data plane (ADR-0046, OD-12).`
    and `# Envoy Gateway creates ServiceAccount xplane-agent-router-bedrock from SP1's EnvoyProxy agent-router-proxy.`;
  - add under the header: `# Same policy as xplane-ai-gateway-bedrock on purpose: two roles, so either data plane's credential can be revoked alone.`;
  - `metadata.name: xplane-agent-router-bedrock`;
  - `spec.serviceAccount.name: xplane-agent-router-bedrock`.
- [ ] **Step 4: Write the kustomization.** Create `security/base/epis-ai-gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: security

# Bedrock identities for the two gateway data planes. Applied by the always-on
# ai-gateway umbrella, since both data planes run in envoy-gateway-system, and
# not by the general epis/ tree, so they live and die with the gateway layer.
resources:
  - ai-gateway-bedrock.yaml
  - agent-router-bedrock.yaml
```

- [ ] **Step 5: Add the Flux child.** Create `clusters/aws-0-ai-gateway/security-ai-gateway-epi.yaml`,
  add it to the umbrella's `kustomization.yaml`, and add the README row
  `| ai-gateway-security-epi | security/base/epis-ai-gateway | Bedrock EPIs for both gateway data planes |`
  (backticked like the others). Append `ai-gateway-security-epi` to the README teardown command.

```yaml
---
# EKS Pod Identity for Bedrock on both gateway data planes (ADR-0046).
# wait: true, because envoy-ai-gateway depends on it: Pod Identity is injected
# at admission, so the proxies must roll only after the association exists.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ai-gateway-security-epi
  namespace: flux-system
spec:
  prune: true
  wait: true
  interval: 5m0s
  retryInterval: 30s
  timeout: 10m0s
  sourceRef:
    kind: ExternalArtifact
    name: security-artifact
  path: ./security/base/epis-ai-gateway
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    - name: eks-pod-identities
  healthCheckExprs:
    - apiVersion: cloud.ogenki.io/v1alpha1
      kind: EPI
      failed: status.conditions.filter(c, c.type == 'Synced' || c.type == 'Ready').all(c, c.status == 'False')
      current: status.conditions.filter(c, c.type == 'Synced' || c.type == 'Ready').all(c, c.status == 'True')
```

- [ ] **Step 6: Create the aws-0 overlay for `envoy-ai-gateway`.** Create
  `infrastructure/aws-0/envoy-ai-gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# aws-0 additions to the shared ai-gateway: the data plane's Bedrock identity
# and, from Task 14, the oidc listener. gcp-0's llm-platform keeps applying
# ../../base/envoy-ai-gateway unchanged.
resources:
  - ../../base/envoy-ai-gateway
  - network-policy-aws.yaml
patches:
  - target:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: ai-gateway-proxy
    patch: |-
      # Envoy Gateway creates this ServiceAccount, and EPI
      # xplane-ai-gateway-bedrock binds it: that binding is the data plane's
      # only credential for Bedrock.
      - op: add
        path: /spec/provider/kubernetes/envoyServiceAccount
        value:
          name: xplane-ai-gateway-bedrock
```

- [ ] **Step 7: Write the additive policy.** Create `infrastructure/aws-0/envoy-ai-gateway/network-policy-aws.yaml`:

```yaml
# aws-0 additions for the ai-gateway data plane. Cilium policies are additive,
# so this widens the cloud-neutral envoy-data-plane policy without editing it.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ai-gateway-data-plane-aws
  namespace: envoy-gateway-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/managed-by: envoy-gateway
      app.kubernetes.io/component: proxy
      gateway.envoyproxy.io/owning-gateway-name: ai-gateway
  egress:
    # DNS inspection, so the toFQDNs rules below have IPs to match.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
    # Claude on Bedrock EU (llm-gateway/bedrock-eu-west-3).
    - toFQDNs:
        - matchName: bedrock-runtime.eu-west-3.amazonaws.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    # The EKS Pod Identity agent at 169.254.170.23:80 runs on the node's host
    # network. Cilium classifies it as the host entity, so a toCIDR rule would
    # silently miss it (security/AGENTS.md, trap 3).
    - toEntities:
        - host
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
```

- [ ] **Step 8: Point the child at the overlay,** and make it wait for the identity. In
  `clusters/aws-0-ai-gateway/infrastructure-envoy-ai-gateway.yaml`:
  - Set `path: ./infrastructure/aws-0/envoy-ai-gateway`.
  - Append to `dependsOn:`:

```yaml
    # The proxies roll onto xplane-ai-gateway-bedrock. Its Pod Identity
    # association must exist first, or they start with no AWS credentials.
    - name: ai-gateway-security-epi
```

  In the README, the `envoy-ai-gateway` row's path becomes `infrastructure/aws-0/envoy-ai-gateway`.
- [ ] **Step 9: Check the render.**

  ```bash
  kustomize build infrastructure/aws-0/envoy-ai-gateway | grep -A1 envoyServiceAccount   # name: xplane-ai-gateway-bedrock
  ```

  Then run `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`.
- [ ] **Step 10: Commit.**

  ```bash
  git add security/base/epis-ai-gateway infrastructure/aws-0/envoy-ai-gateway clusters/aws-0-ai-gateway
  git commit -m "feat(ai-gateway): keyless Bedrock identities for both gateway data planes"
  ```

### Task 11: `claude-*` on `ai-gateway`, and the Claude prices

**Files:**
- Create: `infrastructure/aws-0/llm-gateway/kustomization.yaml`,
  `infrastructure/aws-0/llm-gateway/bedrock.yaml`,
  `infrastructure/aws-0/llm-gateway/aigatewayroute-bedrock.yaml`
- Modify: `clusters/aws-0-ai-gateway/infrastructure-llm-gateway.yaml`,
  `clusters/aws-0-ai-gateway/README.md`,
  `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml`

**Interfaces:**
- Produces:
  - `AIServiceBackend` `bedrock-anthropic` (schema `AWSAnthropic`) in `llm-gateway`.
  - `AIGatewayRoute` `llm-gateway-bedrock` with rules `claude-opus-5-5`, `claude-sonnet-5` and
    `claude-haiku-4-5`.
  - Price series for the three EU profiles.
- Consumes: `xplane-ai-gateway-bedrock` (Task 10). B5 already matches `claude-.*` (Task 6).

- [ ] **Step 1: Check the route is absent.** This is the failing test.
  `kustomize build infrastructure/aws-0/llm-gateway` → `not a valid directory`.
- [ ] **Step 2: Write the Bedrock backend.** Create `infrastructure/aws-0/llm-gateway/bedrock.yaml`:

```yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: bedrock-eu-west-3
  namespace: llm-gateway
spec:
  endpoints:
    - fqdn:
        hostname: bedrock-runtime.eu-west-3.amazonaws.com
        port: 443
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: bedrock-eu-west-3
  namespace: llm-gateway
spec:
  targetRefs:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: bedrock-eu-west-3
  validation:
    wellKnownCACertificates: System
    hostname: bedrock-runtime.eu-west-3.amazonaws.com
---
# AWSAnthropic accepts both OpenAI- and Anthropic-format input, which is why
# Claude goes through Bedrock rather than the native API (ADR-0046).
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIServiceBackend
metadata:
  name: bedrock-anthropic
  namespace: llm-gateway
spec:
  schema:
    name: AWSAnthropic
  backendRef:
    group: gateway.envoyproxy.io
    kind: Backend
    name: bedrock-eu-west-3
---
# No credentialsFile and no OIDC exchange: the AWS SDK default chain finds the
# EKS Pod Identity credentials of the data plane's ServiceAccount
# (xplane-ai-gateway-bedrock).
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: BackendSecurityPolicy
metadata:
  name: bedrock
  namespace: llm-gateway
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: bedrock-anthropic
  type: AWSCredentials
  awsCredentials:
    region: eu-west-3
```

- [ ] **Step 3: Write the route.** Create `infrastructure/aws-0/llm-gateway/aigatewayroute-bedrock.yaml`:

```yaml
# Claude for humans and system clients, by name, on the EU geo inference
# profiles only: data stays in EU regions (design section 4). Separate from the
# base llm-gateway route because the backend is per cloud: gcp-0 will map the
# same names to Vertex.
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: llm-gateway-bedrock
  namespace: llm-gateway
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
      namespace: envoy-ai-gateway-system
  llmRequestCosts:
    - metadataKey: llm_total_token
      type: TotalToken
  rules:
    - name: claude-opus-5-5
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: claude-opus-5-5
      backendRefs:
        - name: bedrock-anthropic
          modelNameOverride: eu.anthropic.claude-opus-5-5
          weight: 100
      timeouts:
        request: 600s
    - name: claude-sonnet-5
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: claude-sonnet-5
      backendRefs:
        - name: bedrock-anthropic
          modelNameOverride: eu.anthropic.claude-sonnet-5
          weight: 100
      timeouts:
        request: 600s
    - name: claude-haiku-4-5
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: claude-haiku-4-5
      backendRefs:
        - name: bedrock-anthropic
          modelNameOverride: eu.anthropic.claude-haiku-4-5-20251001-v1:0
          weight: 100
      timeouts:
        request: 600s
```

- [ ] **Step 4: Create the overlay.** Create `infrastructure/aws-0/llm-gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/llm-gateway
  - bedrock.yaml
  - aigatewayroute-bedrock.yaml
```

- [ ] **Step 5: Point the child at the overlay.** In
  `clusters/aws-0-ai-gateway/infrastructure-llm-gateway.yaml`, set
  `path: ./infrastructure/aws-0/llm-gateway`. In the README, the `llm-gateway` row's path becomes
  `infrastructure/aws-0/llm-gateway`, and its "Holds" gains `, Claude on Bedrock EU`.
- [ ] **Step 6: Add the Claude prices.** Append to the `llm-gateway-prices` group in
  `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml`. Add a comment line first:
  `# Claude: Anthropic's first-party list prices. Bedrock bills through AWS Marketplace, at prices not yet verified (design R7).`

```yaml
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(4)
          labels:
            gen_ai_request_model: "eu.anthropic.claude-opus-5-5"
            gen_ai_token_type: input
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(20)
          labels:
            gen_ai_request_model: "eu.anthropic.claude-opus-5-5"
            gen_ai_token_type: output
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(2)
          labels:
            gen_ai_request_model: "eu.anthropic.claude-sonnet-5"
            gen_ai_token_type: input
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(10)
          labels:
            gen_ai_request_model: "eu.anthropic.claude-sonnet-5"
            gen_ai_token_type: output
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(1)
          labels:
            gen_ai_request_model: "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
            gen_ai_token_type: input
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(5)
          labels:
            gen_ai_request_model: "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
            gen_ai_token_type: output
```

- [ ] **Step 7: Validate.**
  - `kustomize build infrastructure/aws-0/llm-gateway | grep -c 'value: claude-'` → 3.
  - `./scripts/ci/validate-vmrules.sh` → exit 0.
  - `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`.
- [ ] **Step 8: Commit.**

  ```bash
  git add infrastructure/aws-0/llm-gateway infrastructure/base/llm-gateway clusters/aws-0-ai-gateway
  git commit -m "feat(llm-gateway): Claude on Bedrock EU as claude-* on the ai-gateway Gateway"
  ```

### Task 12: Agent tiers on `agent-router` — `agent-models` and `agent-models-internal`

**Files:**
- Modify (SP1 files; SP4 owns the route's content): `infrastructure/base/agent-router/aigatewayroute-agent-models.yaml`,
  `infrastructure/base/agent-router/envoyproxy.yaml`,
  `infrastructure/base/agent-router/network-policy-data-plane.yaml`,
  `clusters/aws-0-agent-platform/infrastructure-agent-router.yaml`,
  `clusters/aws-0-agent-platform/kustomization.yaml`
- Create: `infrastructure/aws-0/agent-model-routing/kustomization.yaml`,
  `infrastructure/aws-0/agent-model-routing/bedrock.yaml`,
  `infrastructure/aws-0/agent-model-routing/aigatewayroute-agent-models-internal.yaml`,
  `clusters/aws-0-agent-platform/infrastructure-agent-model-routing.yaml`
- Modify: `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml` (Flash prices)

**Interfaces:**
- Produces:
  - The four C5 names on both `agent-router` listeners.
  - Flux child `agent-model-routing` (in `agent-platform`), with `dependsOn: agent-router`.
  - The `agent-router` proxies run as `xplane-agent-router-bedrock`.
- Consumes: I1–I5 and I10, and `xplane-agent-router-bedrock` (Task 10).

- [ ] **Step 1: Check the tiers are absent.** This is the failing test.

  ```bash
  kustomize build infrastructure/base/agent-router | grep -c 'value: tier-'   # 0: SP1 seeded agent-default only
  ```

- [ ] **Step 2: Replace the `agent-models` route.** Replace the content of
  `infrastructure/base/agent-router/aigatewayroute-agent-models.yaml` with:

```yaml
# The C5 model map for `public` runs. SP1 seeded it, and SP4 owns its content
# (design S12). Every name maps statically, 100 %, to one backend: no weights,
# no canary, no priority fallback and no Semantic Router, so nothing re-routes
# a trajectory mid-run (design S7). A mapping change is a reviewed PR, and
# in-flight runs see it on their next request.
#
# `internal` runs use agent-models-internal on their own listener. Z.ai is
# reachable from `public` only (design S13); gate A5 fails the build otherwise.
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: agent-models
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: public
  # Charged by B1 and B2 (agent-router-token-budgets), and read by SP3's run meter.
  llmRequestCosts:
    - metadataKey: llm_total_token
      type: TotalToken
  rules:
    - name: tier-light
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: tier-light
      backendRefs:
        - name: zai
          # API id unverified at design time; Task 15 proves it with a live call.
          modelNameOverride: glm-5.3-flash
          weight: 100
      timeouts:
        request: 600s
    - name: tier-standard
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: tier-standard
      backendRefs:
        - name: zai
          # API id unverified at design time; Task 15 proves it with a live call.
          modelNameOverride: glm-5.3-flashx
          weight: 100
      timeouts:
        request: 600s
    - name: tier-frontier
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: tier-frontier
      backendRefs:
        - name: zai
          modelNameOverride: glm-5.2
          weight: 100
      timeouts:
        request: 600s
    - name: agent-default
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: agent-default
      backendRefs:
        - name: zai
          modelNameOverride: glm-5.2
          weight: 100
      timeouts:
        request: 600s
```

- [ ] **Step 3: Give the `agent-router` proxies their Bedrock identity.** In
  `infrastructure/base/agent-router/envoyproxy.yaml`, add under `spec.provider.kubernetes:`:

```yaml
      # Envoy Gateway creates this ServiceAccount, and EPI
      # xplane-agent-router-bedrock (ai-gateway umbrella) binds it: the only
      # credential behind agent-models-internal's Bedrock backend.
      envoyServiceAccount:
        name: xplane-agent-router-bedrock
```

  In `clusters/aws-0-agent-platform/infrastructure-agent-router.yaml`, append to `dependsOn:`:

```yaml
    # Pod Identity is injected at admission: the proxies must roll onto
    # xplane-agent-router-bedrock only after its association exists.
    - name: ai-gateway-security-epi
```

- [ ] **Step 4: Write the agents' Bedrock backend.** Create
  `infrastructure/aws-0/agent-model-routing/bedrock.yaml`. It holds the same four objects as
  `infrastructure/aws-0/llm-gateway/bedrock.yaml` (Task 11 Step 2), in namespace `agent-system`: each
  Gateway has its own backends (design S12). Its header comment reads
  `# Bedrock EU for internal agent runs. Separate from llm-gateway's copy: each Gateway owns its backends, and the credential here is xplane-agent-router-bedrock's (design S12).`
  The full file:

```yaml
# Bedrock EU for internal agent runs. Separate from llm-gateway's copy: each
# Gateway owns its backends, and the credential here is
# xplane-agent-router-bedrock's (design S12).
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: bedrock-eu-west-3
  namespace: agent-system
spec:
  endpoints:
    - fqdn:
        hostname: bedrock-runtime.eu-west-3.amazonaws.com
        port: 443
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: bedrock-eu-west-3
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: bedrock-eu-west-3
  validation:
    wellKnownCACertificates: System
    hostname: bedrock-runtime.eu-west-3.amazonaws.com
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIServiceBackend
metadata:
  name: bedrock-anthropic
  namespace: agent-system
spec:
  schema:
    name: AWSAnthropic
  backendRef:
    group: gateway.envoyproxy.io
    kind: Backend
    name: bedrock-eu-west-3
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: BackendSecurityPolicy
metadata:
  name: bedrock
  namespace: agent-system
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: bedrock-anthropic
  type: AWSCredentials
  awsCredentials:
    region: eu-west-3
```

- [ ] **Step 5: Write the `internal` route.** Create
  `infrastructure/aws-0/agent-model-routing/aigatewayroute-agent-models-internal.yaml`:

```yaml
# The C5 model map for `internal` runs: Bedrock EU only (OD-13). Attached to
# the `internal` listener, whose SecurityPolicy accepts only
# agent-router.<role>.internal audiences, so an internal token never meets a
# Z.ai route (design S13). Pinned exactly like agent-models (design S7).
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: agent-models-internal
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: internal
  llmRequestCosts:
    - metadataKey: llm_total_token
      type: TotalToken
  rules:
    - name: tier-light
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: tier-light
      backendRefs:
        - name: bedrock-anthropic
          modelNameOverride: eu.anthropic.claude-haiku-4-5-20251001-v1:0
          weight: 100
      timeouts:
        request: 600s
    - name: tier-standard
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: tier-standard
      backendRefs:
        - name: bedrock-anthropic
          modelNameOverride: eu.anthropic.claude-sonnet-5
          weight: 100
      timeouts:
        request: 600s
    - name: tier-frontier
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: tier-frontier
      backendRefs:
        - name: bedrock-anthropic
          modelNameOverride: eu.anthropic.claude-opus-5-5
          weight: 100
      timeouts:
        request: 600s
    - name: agent-default
      matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: agent-default
      backendRefs:
        - name: bedrock-anthropic
          modelNameOverride: eu.anthropic.claude-opus-5-5
          weight: 100
      timeouts:
        request: 600s
```

- [ ] **Step 6: Open Bedrock on SP1's data-plane policy (I10).** In
  `infrastructure/base/agent-router/network-policy-data-plane.yaml`:
  - Change the header comment's last sentence, "SP4 PR 2 adds the Bedrock egress here.", to
    "SP4 adds the Bedrock, Pod Identity and rate-limit egress."
  - Append to `egress:`:

```yaml
    # Claude on Bedrock EU, behind agent-models-internal (SP4, OD-13).
    - toFQDNs:
        - matchName: bedrock-runtime.eu-west-3.amazonaws.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    # The EKS Pod Identity agent at 169.254.170.23:80 runs on the node's host
    # network. Cilium classifies it as the host entity, so a toCIDR rule would
    # silently miss it (security/AGENTS.md, trap 3).
    - toEntities:
        - host
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
```

  The policy's existing kube-dns rule already carries the DNS inspection that `toFQDNs` needs.

- [ ] **Step 7: Write the overlay's kustomization.** Create
  `infrastructure/aws-0/agent-model-routing/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# SP4 on the agents' Gateway. The internal model map is per cloud (Bedrock
# here, Vertex on gcp-0 later). The public map lives in SP1's
# infrastructure/base/agent-router/aigatewayroute-agent-models.yaml.
resources:
  - bedrock.yaml
  - aigatewayroute-agent-models-internal.yaml
```

- [ ] **Step 8: Add the Flux child.** Create
  `clusters/aws-0-agent-platform/infrastructure-agent-model-routing.yaml`, and add
  `- infrastructure-agent-model-routing.yaml` to `clusters/aws-0-agent-platform/kustomization.yaml`:

```yaml
---
# SP4 on the agents' Gateway: agent-models-internal (Bedrock EU) and the token
# budgets B1–B2.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-model-routing
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 5m0s
  path: ./infrastructure/aws-0/agent-model-routing
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    # Gateway agent-router and its listeners (SP1).
    - name: agent-router
    # The global rate-limit service (B1, B2).
    - name: envoy-gateway
```

- [ ] **Step 9: Add the Flash prices.** Append to `llm-gateway-prices`, after the GLM-5.2 entries, with
  the comment `# Flash ids are unverified until SP4 PR 2's live call (design section 5).`:

```yaml
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(0.37)
          labels:
            gen_ai_request_model: "glm-5.3-flashx"
            gen_ai_token_type: input
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(1.25)
          labels:
            gen_ai_request_model: "glm-5.3-flashx"
            gen_ai_token_type: output
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(0.15)
          labels:
            gen_ai_request_model: "glm-5.3-flash"
            gen_ai_token_type: input
        - record: llm_gateway:price_usd_per_mtoken
          expr: vector(0.50)
          labels:
            gen_ai_request_model: "glm-5.3-flash"
            gen_ai_token_type: output
```

- [ ] **Step 10: Prove gate A5 bites.** Temporarily change `agent-models-internal`'s
  `tier-light` backendRef to `zai`, and run `./scripts/ci/validate-manifests.sh`. Expected: exit 1,
  `FAIL AIGatewayRoute agent-system/agent-models-internal: reaches api.z.ai but attaches to agent-router internal; Z.ai is public-only`.
  Revert the edit, and do not commit it.
- [ ] **Step 11: Validate.**
  - `kustomize build infrastructure/base/agent-router | grep -c 'value: tier-'` → 3, plus
    `agent-default` on its own line.
  - `./scripts/ci/validate-vmrules.sh` → exit 0.
  - `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`, `4 checks, 0 violations`.
- [ ] **Step 12: Commit.**

  ```bash
  git add infrastructure/base/agent-router infrastructure/aws-0/agent-model-routing \
    clusters/aws-0-agent-platform infrastructure/base/llm-gateway
  git commit -m "feat(agent-router): pinned agent tiers, public on Z.ai and internal on Bedrock EU"
  ```

### Task 13: B1–B2 in shadow, the run-token recording rule, and the agent budget alerts

**Files:**
- Create: `infrastructure/base/agent-model-routing/kustomization.yaml`,
  `infrastructure/base/agent-model-routing/btp-token-budgets.yaml`,
  `infrastructure/base/agent-model-routing/vmrule-agent-budgets.yaml`
- Modify: `infrastructure/aws-0/agent-model-routing/kustomization.yaml`,
  `infrastructure/base/agent-router/network-policy-data-plane.yaml` (SP1's CNP, I10)

**Interfaces:**
- Produces:
  - `BackendTrafficPolicy` `agent-router-token-budgets` (namespace `agent-system`).
  - Recording rule `agent_router:run_tokens:total{principal="agent:<runId>"}`, the series SP3's run
    meter reads (design §6).
  - Alerts `AgentRunNearCeiling` and `FleetBudgetNearCap`.
- Consumes: the `ar_agent` label (Task 3), `llmRequestCosts` on both agent routes (Task 12), and the
  rate-limit service (PR 1, Task 5).

- [ ] **Step 1: Write the policy.** Gate A1/A2 is its test. Create
  `infrastructure/base/agent-model-routing/btp-token-budgets.yaml`:

```yaml
# Token budgets on the agents' Gateway (design section 6, OD-10, ADR-0050).
# The ONLY Gateway-level BackendTrafficPolicy on agent-router: Envoy Gateway
# marks a second one Conflicted. No sectionName, so B2 is one bucket across
# both listeners. Shared, token-costed, and in SHADOW for the first week
# (enforcement is SP4 PR 7).
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: agent-router-token-budgets
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
  rateLimit:
    global:
      rules:
        # B1 — per-run ceiling. x-ar-agent is the token's sub, which names the
        # run. 5M equals the AgentRun XRD's ceiling on spec.budget.maxTokens
        # (C3); SP3's run meter revokes a run at its own, lower cap.
        - clientSelectors:
            - headers:
                - name: x-ar-agent
                  type: Distinct
          limit:
            requests: 5000000
            unit: Day
          cost:
            request:
              from: Number
              number: 0
            response:
              from: Metadata
              metadata:
                namespace: io.envoy.ai_gateway
                key: llm_total_token
          shared: true
          shadowMode: true
        # B2 — the agent fleet, every run on either listener. Sized at least the
        # sum of SP3's admission caps (25M factory + 5M per launching human;
        # 40M for three), so neither kind starves the other (OD-10).
        - limit:
            requests: 40000000
            unit: Day
          cost:
            request:
              from: Number
              number: 0
            response:
              from: Metadata
              metadata:
                namespace: io.envoy.ai_gateway
                key: llm_total_token
          shared: true
          shadowMode: true
```

- [ ] **Step 2: Write the rules.** Create `infrastructure/base/agent-model-routing/vmrule-agent-budgets.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: agent-budgets
  namespace: observability
  labels:
    app.kubernetes.io/part-of: ai
spec:
  groups:
    - name: agent-router-usage
      rules:
        # Tokens per run under the canonical id agent:<runId> (programme C2).
        # SP3's run meter writes it into the AgentRun's usage annotation, and
        # revokes the run at spec.budget.maxTokens (design section 6).
        - record: agent_router:run_tokens:total
          expr: |
            label_replace(
              sum by (ar_agent) (gen_ai_client_token_usage_sum{ar_agent=~"system:serviceaccount:agents:xplane-run-.+"}),
              "principal", "agent:$1", "ar_agent", "system:serviceaccount:agents:xplane-run-(.+)"
            )
    - name: agent-router-budgets
      rules:
        # Both alerts read the gen_ai counters, so they fire in shadow mode too.
        # A rolling 24 h covers at least the limiter's fixed UTC day, so they
        # fire no later than the rule would trip.
        - alert: AgentRunNearCeiling
          # 80 % of B1 (5M tokens per run per day).
          expr: |
            sum by (ar_agent) (increase(gen_ai_client_token_usage_sum{ar_agent!=""}[24h])) > 4e6
          for: 5m
          labels:
            severity: warning
            component: ai
          annotations:
            summary: "Agent run {{ $labels.ar_agent }} is above 80% of the 5M per-run ceiling"
            description: |
              B1 in agent-router-token-budgets rejects this run's next request once the ceiling
              is crossed (when enforced). A run near the ceiling is usually looping.
        - alert: FleetBudgetNearCap
          # 80 % of B2 (40M tokens per day across all agent runs).
          expr: |
            sum(increase(gen_ai_client_token_usage_sum{ar_agent!=""}[24h])) > 32e6
          for: 5m
          labels:
            severity: warning
            component: ai
          annotations:
            summary: "Agent fleet token use is above 80% of the 40M daily cap"
            description: |
              B2 in agent-router-token-budgets stops every agent run once the fleet cap is
              crossed (when enforced). Top runs: topk(5, sum by (ar_agent)
              (increase(gen_ai_client_token_usage_sum{ar_agent!=""}[24h]))).
```

- [ ] **Step 3: Wire the base into the overlay.** Create `infrastructure/base/agent-model-routing/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# SP4's cloud-neutral share of the agent-router Gateway: its token budgets.
resources:
  - btp-token-budgets.yaml
  - vmrule-agent-budgets.yaml
```

  Then add `- ../../base/agent-model-routing` as the first entry of `resources:` in
  `infrastructure/aws-0/agent-model-routing/kustomization.yaml`.

- [ ] **Step 4: Let the `agent-router` proxies reach the rate-limit service (I10).** Append to
  `egress:` in `infrastructure/base/agent-router/network-policy-data-plane.yaml`:

```yaml
    # Global rate limit (B1, B2). A dropped check fails OPEN, so without this
    # rule the budgets silently count nothing. The Valkey store behind it is
    # reached by the rate-limit pod only, never by the proxies
    # (infrastructure/aws-0/envoy-gateway/network-policy-ratelimit.yaml).
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            app.kubernetes.io/name: envoy-ratelimit
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
```
- [ ] **Step 5: Validate.**
  - `kustomize build infrastructure/aws-0/agent-model-routing | grep -c 'kind: BackendTrafficPolicy'` → 1.
  - `./scripts/ci/validate-vmrules.sh` → exit 0.
  - `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`, `0 violations`.
- [ ] **Step 6: Commit.**

  ```bash
  git add infrastructure/base/agent-model-routing infrastructure/aws-0/agent-model-routing infrastructure/base/agent-router
  git commit -m "feat(agent-router): token budgets B1-B2 in shadow, run-token series and budget alerts"
  ```

### Task 14: The `oidc` listener on `ai-gateway`, and `/anthropic`

**Files:**
- Modify: `opentofu/aws/eks/configure/variables.tf`, `opentofu/aws/eks/configure/variables.tfvars`,
  `opentofu/aws/eks/configure/kubernetes.tf`, `scripts/ci/flux-schema/render-bundle.py`,
  `infrastructure/base/envoy-ai-gateway/security-policy.yaml`,
  `infrastructure/aws-0/envoy-ai-gateway/kustomization.yaml`,
  `infrastructure/aws-0/envoy-ai-gateway/network-policy-aws.yaml`,
  `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml`,
  `website/content/docs/platform/ai-platform/coding-clients.md`
- Create: `infrastructure/aws-0/envoy-ai-gateway/securitypolicy-oidc.yaml`,
  `infrastructure/aws-0/envoy-ai-gateway/httproute-oidc.yaml`

**Interfaces:**
- Produces:
  - Listener `oidc` (:8081) on `ai-gateway`, which accepts ZITADEL JWTs whose `aud` carries
    `${zitadel_project_id}`. It sets `x-ar-human` from `sub`, so B3 counts it.
  - Hostname `llm-oidc.${private_domain_name}`.
  - Cluster variable `zitadel_project_id` on aws-0.
  - Recording rule `ai_gateway:human_tokens:total{principal="human:<sub>"}`.
- Consumes: `${identity_provider_url}` (existing on aws-0).

- [ ] **Step 1: Write the policy.** It references a variable aws-0 does not define yet. Create
  `infrastructure/aws-0/envoy-ai-gateway/securitypolicy-oidc.yaml`:

```yaml
# Humans with a ZITADEL token (programme C2: principal human:<sub>). The
# token's aud must carry the platform project id. ZITADEL adds it only when a
# client asks for it with the project-audience scope, so tokens issued for the
# other apps' default audiences are rejected. The gateway sets x-ar-human from
# the verified sub, after the early strip removed any client-sent value.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ai-gateway-oidc
  namespace: envoy-ai-gateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
      sectionName: oidc
  jwt:
    providers:
      - name: zitadel
        issuer: ${identity_provider_url}
        audiences:
          - "${zitadel_project_id}"
        remoteJWKS:
          uri: ${identity_provider_url}/oauth/v2/keys
        claimToHeaders:
          - claim: sub
            header: x-ar-human
```

  Add `- securitypolicy-oidc.yaml` to the overlay's `resources:`.
- [ ] **Step 2: Watch the substitution check fail.** Run
  `python3 scripts/ci/flux-schema/check-substitution.py`. Expected: exit 1, naming
  `${zitadel_project_id}` as undefined in `eks-aws-0-vars` for Kustomization `envoy-ai-gateway`.
- [ ] **Step 3: Define the variable on aws-0,** mirroring gcp-0.
  - `opentofu/aws/eks/configure/variables.tf`:

```hcl
variable "zitadel_project_id" {
  description = "ZITADEL project id. The ai-gateway oidc listener accepts only tokens whose aud carries it, and ZITADEL puts it there only when the client requests the project-audience scope."
  type        = string
}
```

  - `opentofu/aws/eks/configure/variables.tfvars`:

```hcl
# The platform project, the same one gcp-0 federates
# (opentofu/gcp/gke/configure/variables.tfvars). If a rebuild changes it,
# scripts/provision/zitadel-oidc-clients.sh's reconcile_consumer_audience
# patches the vars ConfigMap to match.
zitadel_project_id = "388445486190712688"
```

  - `opentofu/aws/eks/configure/kubernetes.tf`, inside `flux_cluster_vars` `data = {…}`, after
    `identity_provider_url`:

```hcl
      # The audience the ai-gateway oidc listener requires of a ZITADEL token.
      zitadel_project_id = var.zitadel_project_id
```

  - `scripts/ci/flux-schema/render-bundle.py`, in `FIXTURE_VARS` after `identity_provider_url`:

```python
    # infrastructure/aws-0/envoy-ai-gateway's oidc SecurityPolicy audience.
    # Without it the bundle carries a literal ${zitadel_project_id}, which is
    # schema-valid and names no audience at all.
    "zitadel_project_id": "388445486190712688",
```

- [ ] **Step 4: Watch it pass.**
  - `python3 scripts/ci/flux-schema/check-substitution.py` → exit 0.
  - `tofu -chdir=opentofu/aws/eks/configure init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/aws/eks/configure validate`
    → `Success!`.
  - `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml opentofu/aws/eks/configure` → exit 0.
- [ ] **Step 5: Scope API-key auth to the `http` listener.** In
  `infrastructure/base/envoy-ai-gateway/security-policy.yaml`, set the target to
  `sectionName: http`, and prepend this line to the header comment:
  `# Scoped to the http listener: each listener carries its own SecurityPolicy (aws-0 adds oidc), and a Gateway-wide one would silently cover any listener added later.`

```yaml
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
      sectionName: http
```

- [ ] **Step 6: Add the listener and its route.**
  - Append to `patches:` in `infrastructure/aws-0/envoy-ai-gateway/kustomization.yaml`:

```yaml
  - target:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
    patch: |-
      # Humans with a ZITADEL token (x-ar-human, budget B3). Claude Code
      # reaches /anthropic here. There is no Semantic Router on this listener:
      # its EnvoyPatchPolicy names the http listener only, so MoM is http-only.
      - op: add
        path: /spec/listeners/-
        value:
          name: oidc
          protocol: HTTP
          port: 8081
          allowedRoutes:
            namespaces:
              from: Selector
              selector:
                matchExpressions:
                  - key: kubernetes.io/metadata.name
                    operator: In
                    values: [llm, llm-gateway]
```

  - Create `infrastructure/aws-0/envoy-ai-gateway/httproute-oidc.yaml`, and add it to `resources:`:

```yaml
# Tailnet entry for the oidc listener. It lives beside the data-plane Service
# it targets, as the base's llm.<private domain> route does.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ai-gateway-oidc
  namespace: envoy-gateway-system
spec:
  parentRefs:
    - name: platform-tailscale-general
      namespace: infrastructure
  hostnames:
    - "llm-oidc.${private_domain_name}"
  rules:
    - backendRefs:
        - name: ai-gateway
          port: 8081
```

  - Append to `infrastructure/aws-0/envoy-ai-gateway/network-policy-aws.yaml`:
    - a new `ingress:` block under `spec:`:

```yaml
  ingress:
    # The oidc listener, reached through the Tailscale Gateway.
    - fromEntities:
        - ingress
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
```

    - and under `egress:`:

```yaml
    # ZITADEL's JWKS, which Envoy fetches to verify oidc-listener tokens.
    - toFQDNs:
        - matchName: "auth.${public_domain_name}"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 7: Name humans by their canonical id.** Add a new group at the end of
  `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml`:

```yaml
    - name: ai-gateway-usage
      rules:
        # Tokens per human under the canonical id human:<sub> (programme C2).
        - record: ai_gateway:human_tokens:total
          expr: |
            label_replace(sum by (ar_human) (gen_ai_client_token_usage_sum{ar_human!=""}),
              "principal", "human:$1", "ar_human", "(.+)")
```

- [ ] **Step 8: Document Claude Code.** In `website/content/docs/platform/ai-platform/coding-clients.md`,
  append:

````markdown
## Claude Code through the gateway

Claude Code speaks the Anthropic API, which the gateway serves under `/anthropic`. As a human, use the
`oidc` listener, so that your tokens count against your own budget:

```bash
export ANTHROPIC_BASE_URL=https://llm-oidc.priv.aws.ogenki.io/anthropic
export ANTHROPIC_AUTH_TOKEN=<ZITADEL access token (JWT) whose aud carries the platform project id>
export ANTHROPIC_MODEL=claude-sonnet-5      # or claude-opus-5-5, claude-haiku-4-5, tier-frontier (GLM-5.2)
claude
```

The `claude-*` names are Claude on Amazon Bedrock, in EU regions only. `tier-frontier` is GLM-5.2,
translated from the Anthropic format by the gateway.

{{< callout type="warning" >}}
**No interactive login yet.** The listener validates ZITADEL JWTs, but no ZITADEL client is registered
yet to issue one to a human from the command line (a device-code app). Until one is, the listener is
usable only with a token minted another way.
{{< /callout >}}
````

- [ ] **Step 9: Validate.**
  - `kustomize build infrastructure/aws-0/envoy-ai-gateway | grep -E 'name: oidc|sectionName: (http|oidc)'`
    → the listener, plus both SecurityPolicies' sections.
  - `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`, `4 checks, 0 violations`.
  - `task check` → exit 0.
  - `./scripts/ci/validate-links.sh` → exit 0.
- [ ] **Step 10: Commit.**

  ```bash
  git add opentofu/aws/eks/configure scripts/ci/flux-schema/render-bundle.py infrastructure/base/envoy-ai-gateway \
    infrastructure/aws-0/envoy-ai-gateway infrastructure/base/llm-gateway website/content/docs/platform/ai-platform/coding-clients.md
  git commit -m "feat(ai-gateway): oidc listener for ZITADEL-authenticated humans, Anthropic API at /anthropic"
  ```

### Task 15: Final validation, live verification, and PR 2

**Files:**
- Modify: `website/content/docs/platform/ai-platform/gateway-and-routing.md`

**Interfaces:** None. This task closes the slice.

- [ ] **Step 1: Extend the docs.** Append to the `## Frontier models and token budgets` section of
  `gateway-and-routing.md`:

```markdown
Anthropic's Claude is available as `claude-opus-5-5`, `claude-sonnet-5` and `claude-haiku-4-5`,
through Amazon Bedrock's EU inference profiles. The gateway has no key: its data plane assumes an IAM
role through EKS Pod Identity. A second listener, `llm-oidc.priv.aws.ogenki.io`, authenticates
humans with ZITADEL tokens instead of API keys, and serves the Anthropic API under `/anthropic`.

Agents use a separate Gateway, `agent-router`. It has no Semantic Router, and each logical name maps
to exactly one model:

| Name | `public` runs (Z.ai) | `internal` runs (Bedrock EU) |
|---|---|---|
| `tier-light` | GLM-5.3-Flash | Claude Haiku 4.5 |
| `tier-standard` | GLM-5.3-FlashX | Claude Sonnet 5 |
| `tier-frontier`, `agent-default` | GLM-5.2 | Claude Opus 5.5 |
```

- [ ] **Step 2: Rebase and run every gate.** Invoke `sync-branch`. Then run and cite:
  - `./scripts/ci/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`, `4 checks, 0 violations`;
  - `task check` → exit 0;
  - `./scripts/ci/validate-links.sh` → exit 0.

  Then commit: `docs(ai-platform): Claude on Bedrock, the oidc listener and the agent tier map`.
- [ ] **Step 3 [OWNER] O4: Enable Bedrock model access.** In account eu-west-3, enable model access for
  Claude Opus 5.5, Sonnet 5 and Haiku 4.5: Bedrock console → *Model access*, which accepts the AWS
  Marketplace offer. The gateway roles deliberately lack `aws-marketplace:Subscribe`.
- [ ] **Step 4 [LIVE] L2: Deploy the branch** with the agent layer on:

  ```bash
  cd opentofu && TF_VAR_flux_git_ref='refs/heads/feat/agent-frontier-tiers' terramate script run deploy
  flux resume kustomization ai-gateway -n flux-system
  flux resume kustomization agent-platform -n flux-system
  flux get kustomizations -n flux-system | grep -E '^(ai-gateway-security-epi|envoy-ai-gateway|llm-gateway|agent-router|agent-model-routing)\b'
  ```

  - Expected: all `True`.
  - This deploy also applies `zitadel_project_id` to `eks-aws-0-vars`: `eks/configure` runs as part of it.
  - If `flux-system` re-suspends `agent-platform` on its next reconcile, commit `suspend: false` on
    **this branch only** for the test.
- [ ] **Step 5 [LIVE]: Identity wiring.**

  ```bash
  kubectl get epi -n security xplane-ai-gateway-bedrock xplane-agent-router-bedrock
  for gw in ai-gateway agent-router; do
    kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=$gw \
      -o jsonpath='{.items[0].spec.serviceAccountName} {.items[0].spec.containers[*].env[?(@.name=="AWS_CONTAINER_CREDENTIALS_FULL_URI")].value}{"\n"}'
  done
  ```

  Expected: both EPIs `READY True`, and each Gateway's pod on its `xplane-…-bedrock` ServiceAccount
  with the Pod Identity URI set. If the URI is empty, the pod predates the association: delete it once.
- [ ] **Step 6 [LIVE]: `claude-*` on `ai-gateway`, and R7.** From a tailnet host with the promptfoo key:

  ```bash
  for m in claude-haiku-4-5 claude-sonnet-5 claude-opus-5-5; do
    curl -s https://llm.priv.aws.ogenki.io/v1/chat/completions -H "Authorization: Bearer $LLM_API_KEY" \
      -H "Content-Type: application/json" -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}" \
      | jq -r '.model // .error.message'
  done
  ```

  - Expected: three Claude model ids.
  - An `AccessDenied` names the ARN IAM refused. Fix the EPI policy's resource pattern to cover
    exactly that ARN, redeploy, and record the final shape in the PR as R7's closure.
- [ ] **Step 7 [LIVE]: `/anthropic`, and R8.**

  ```bash
  curl -s https://llm.priv.aws.ogenki.io/anthropic/v1/messages -H "Authorization: Bearer $LLM_API_KEY" \
    -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" \
    -d '{"model":"tier-frontier","max_tokens":256,"tools":[{"name":"get_time","description":"Current UTC time","input_schema":{"type":"object","properties":{}}}],"messages":[{"role":"user","content":"What time is it? Use the tool."}]}' \
    | jq '.content[] | .type'
  ```

  - Expected: `"tool_use"` (GLM-5.2, translated).
  - Repeat with `claude-sonnet-5` and expect `"tool_use"` as well.
  - Record both outcomes as R8's result. If GLM loses the tool call, the Claude Code docs from Task 14
    must recommend the `claude-*` names only.
- [ ] **Step 8 [OWNER] O5 + [LIVE]: The `oidc` listener.** In ZITADEL, create machine user
  `ai-gateway-probe` with *Access Token Type: JWT*, and generate a client secret for it.

  ```bash
  TOKEN=$(curl -s -u "$PROBE_ID:$PROBE_SECRET" -d grant_type=client_credentials \
    -d "scope=openid urn:zitadel:iam:org:project:id:388445486190712688:aud" \
    https://auth.cloud.ogenki.io/oauth/v2/token | jq -r .access_token)
  for auth in "Bearer $TOKEN" "Bearer $LLM_API_KEY" ""; do
    curl -s -o /dev/null -w '%{http_code}\n' https://llm-oidc.priv.aws.ogenki.io/v1/chat/completions \
      ${auth:+-H "Authorization: $auth"} -H "Content-Type: application/json" \
      -d '{"model":"tier-frontier","messages":[{"role":"user","content":"ok"}]}'
  done
  ```

  - Expected: `200`, `401`, `401`.
  - Then `ai_gateway:human_tokens:total` shows `principal="human:<probe user id>"`.
  - Delete the machine user afterwards.
- [ ] **Step 9 [LIVE]: Agent tiers, SC-2 (agent half) and SC-11.** This uses SP1's `agent-probe`
  sandbox (I8): its ServiceAccount is `agent-probe`, and it holds `public` and `internal` tokens under
  `/var/run/secrets/probe/`.

  ```bash
  kubectl apply -f scripts/ops/k8s/agent-probe.yaml
  kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
  R=http://agent-router.envoy-gateway-system.svc.cluster.local
  p() { kubectl exec -n agents agent-probe -c probe -- sh -c "$1"; }
  PUB='-H "Authorization: Bearer $(cat /var/run/secrets/probe/public/token)"'
  INT='-H "Authorization: Bearer $(cat /var/run/secrets/probe/internal/token)"'
  JSON='-H "content-type: application/json"'
  ```

  - **Every public tier.** Expected: `200` four times. This is what proves the Flash API ids: fix any
    id that returns a model-not-found error, in the route and in its price rules.

    ```bash
    for m in tier-light tier-standard tier-frontier agent-default; do
      p "curl -s -o /dev/null -w '$m %{http_code}\n' $PUB $JSON -d '{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}' $R:8080/v1/chat/completions"
    done
    ```

  - **SC-2, agent half.** Forge another run's identity on a valid token:

    ```bash
    p "curl -s -o /dev/null -w 'forged %{http_code}\n' $PUB $JSON -H 'x-ar-agent: system:serviceaccount:agents:xplane-run-sp4forge' -d '{\"model\":\"tier-light\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}' $R:8080/v1/chat/completions"
    ```

    Then query `sum by (ar_agent) (gen_ai_client_token_usage_sum{ar_agent=~".*(agent-probe|sp4forge).*"})`.
    Expected: only `system:serviceaccount:agents:agent-probe`. `agent_router:run_tokens:total` omits
    the probe, whose name is not `xplane-run-*`.
  - **SC-11.** The internal token is refused on `public`, and on `internal` it reaches Bedrock:

    ```bash
    p "curl -s -o /dev/null -w 'internal→public %{http_code}\n' $INT $JSON -d '{\"model\":\"agent-default\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}' $R:8080/v1/chat/completions"
    for m in tier-light tier-standard tier-frontier agent-default; do
      p "curl -s $INT $JSON -d '{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}' $R:8081/v1/chat/completions" | jq -r --arg m "$m" '"\($m) \(.model // .error.message)"'
    done
    curl -s https://vl.priv.aws.ogenki.io/select/logsql/query --data-urlencode \
      'query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" _time:15m | unpack_json | log.listener_port:8081 | stats by (log.upstream_cluster) count() hits'
    ```

    Expected:
    - `internal→public 401`;
    - four Claude model ids (Haiku, Sonnet, Opus, Opus);
    - the 8081 lines show only the `bedrock-eu-west-3` upstream, and none contains `zai`.

    This closes SP1's SC-17 as well: before this PR, `internal` answered 404.
- [ ] **Step 10 [LIVE]: Budgets accepted and counting.**

  ```bash
  kubectl get btp -n agent-system agent-router-token-budgets \
    -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
  ```

  Expected: `Accepted=True`. The rate-limit counters (Task 8 Step 11) also grow for the agent-router
  descriptors.
- [ ] **Step 11: Open PR 2.** Invoke `ship-it`. The body carries:
  - the design link;
  - the SP1 reconciliation (I1–I9, as found);
  - Steps 4–10's outputs;
  - R7 and R8 as closed;
  - "**shadow week starts at merge: YYYY-MM-DD**", so PR 7 can enforce.

  The PR waits for owner review.

---

## Deviations from the spec, and gaps this plan closes or leaves open

Found while planning. D1–D8 and D11 have since been folded into the design; D9 is in the SP1 plan,
and D10 is programme-level. The table records why each changed.

| # | Item | Resolution here |
|---|---|---|
| D1 | The spec writes `extProc.metricsRequestHeaderAttributes`. In chart 1.1.0 the key sits under `controller:` | Task 3 uses `controller.metricsRequestHeaderAttributes` |
| D2 | "The platform Z.ai key moves from `runlore/credentials`". RunLore reads it there until PR 6 | O1 **copies** it; PR 6 removes it (SC-10) |
| D3 | `llmRequestCosts` is per `AIGatewayRoute`. Composition-rendered claim routes and `llm-fleet` declare none | B3/B4 count frontier routes only in this slice. Local-model tokens need a composition change: a PR 3 candidate |
| D4 | Envoy Gateway allows one Gateway-level `BackendTrafficPolicy` per Gateway | B3–B5 and B1–B2 are rules of one policy each. I7 tells SP1 to add none |
| D5 | The spec names the `agent:<runId>` and `human:<sub>` recording rules, but no outline PR owns them | Task 13 (`agent_router:run_tokens:total`) and Task 14 (`ai_gateway:human_tokens:total`) |
| D6 | The spec gives the `oidc` listener no audience and no way for a human to obtain a token | Audience = `zitadel_project_id`, now an aws-0 var. The human device-code client is **open**, and documented as such |
| D7 | §8 lists a controller PDB and 2 Envoy replicas for `ai-gateway`, but no outline PR owns them | Left out. Candidate: PR 6, before RunLore depends on the gateway |
| D8 | Until PR 4, SR's `ext_proc` (`failure_mode_allow: false`, 60 s) stalls **every** `http`-listener request, `tier-frontier` included, when SR is down | Accepted for this slice. SR now runs always (OD-3) |
| D9 | The SP1 spec narrows `envoy-data-plane` in its phase 3. PR 1 needs it first, because it adds Z.ai egress | Done in PR 1 (Task 4). I9 tells SP1 |
| D10 | The design doc links the programme doc, which links every sub-project design | Task 0 carries all nine `2026-09-23-*` files if the docs PR has not merged |
| D11 | The design's price-rule form, `label_replace(vector(1.40), …)`, repeated per model, fails `validate-vmrules.sh`: it runs `promtool check rules --lint-fatal`, and the duplicate-rule lint sees one record name with no static labels. Verified 2026-09-25 | Each price is `expr: vector(<price>)` with static `labels:` (model, token type), which passes the lint |
