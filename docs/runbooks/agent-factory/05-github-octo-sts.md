# 05 — GitHub credentials via octo-sts

Proves that octo-sts is reachable only through `agent-router`'s `sts` listener (never directly), that
per-role trust policies actually enforce write-vs-read scoping, and that the branch ruleset confines
every token to `spec.branch` of one repository — an implementer can push its own run's `agent/**`
branch and nothing else, a reviewer cannot push at all, and no run can mint a token for another
repository or role. See [README.md](README.md) for prerequisites; run
[00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00 done.
- **Owner action 3, done BEFORE owner action 4**: `task ops:github:agent-branch-ruleset --
  Smana/cloud-native-ref`. If the App was installed before the ruleset exists, nothing stops it
  merging its own PR — this order is load-bearing, not a convenience.
- **Owner action 4, done**: the `ogenki-agents` GitHub App created on `Smana`, installed on
  `Smana/cloud-native-ref` only, and its `app_id`/`private_key` written to
  `platform/agents/github-app`.

## Steps

> Corrected 2026-09-27, round 3: runs still use the upstream `agent-server` image (no
> `git-credential-agent`, no `gh` wrapper — CC-2/#2110 not yet published), so Steps 3-6 below were
> **not run as written**. Instead: the throwaway `agent-probe` Sandbox's `sts`-audience token
> (`/var/run/secrets/probe/sts/token`) was used directly against `agent-router`'s `sts` listener
> (`:8082`) for every check that only needs a *rejection* (cross-repo, subject-pattern, direct-CNP);
> a real, minimal implementer/reviewer `AgentRun` (whose ServiceAccount name actually matches octo-sts's
> `xplane-run-[a-z2-7]{8}` subject pattern) was used for the one check that needs a *successful*
> exchange, calling `curl 127.0.0.1:4001/sts/exchange` from inside the harness directly (no git, no
> `gh` needed for this). See the Results table and Platform findings for what that found.

### Step 1 — the ruleset is active

```bash
gh api repos/Smana/cloud-native-ref/rulesets --jq '.[] | select(.name=="agent-branches") | .enforcement'
```

Expected: `active`.

### Step 2 — octo-sts is up, behind the `sts` listener only

```bash
flux get kustomizations -n flux-system octo-sts
```

Expected: `Ready=True`.

### Step 3 — start two runs, one per role

```bash
IMPL=$(task agent:run -- --role implementer --class public --task "SC-11 probe, idle." | tail -1); echo "$IMPL"
REVW=$(task agent:run -- --role reviewer --class public --task-url "https://github.com/Smana/cloud-native-ref/pull/1" | tail -1); echo "$REVW"
kubectl wait -n agents agentrun/$IMPL agentrun/$REVW --for=jsonpath='{.status.phase}'=Running --timeout=15m
```

### Step 4 — implementer pushes `spec.branch`, and only `spec.branch`

Write `/tmp/sc11.py` (Write tool; it runs inside the harness, so its token never leaves the pod):

```python
import json, os, subprocess, sys, urllib.request
role, repo = sys.argv[1], sys.argv[2]
url = "http://127.0.0.1:4001/sts/exchange?scope=%s&identity=agent-%s" % (repo, role)
try:
    token = json.load(urllib.request.urlopen(url, timeout=15))["token"]
except Exception as err:
    print("exchange", repo, role, "->", err); sys.exit(0)
print("exchange", repo, role, "-> token", token[:4] + "…")
remote = "https://x-access-token:%s@github.com/Smana/cloud-native-ref" % token  # pragma: allowlist secret
subprocess.run(["git", "clone", "-q", "--depth", "1", "https://github.com/Smana/cloud-native-ref", "/workspace/sc11"], check=True)
g = lambda *a: subprocess.run(["git", "-C", "/workspace/sc11", "-c", "user.name=sc11", "-c", "user.email=sc11@example.invalid", *a], capture_output=True, text=True)
g("commit", "--allow-empty", "-q", "-m", "test: SC-11 probe")
# BRANCH is one of the harness's own inputs (design section 5) — no need to pass it in.
for ref in ["HEAD:refs/heads/" + os.environ["BRANCH"], "HEAD:refs/heads/main", "HEAD:refs/heads/sc11-not-agent"]:
    r = g("push", remote, ref)
    print("push", ref, "->", "ok" if r.returncode == 0 else r.stderr.strip().splitlines()[-1])
```

```bash
kubectl cp /tmp/sc11.py agents/$IMPL:/tmp/sc11.py -c harness
kubectl exec -n agents $IMPL -c harness -- /usr/local/bin/python /tmp/sc11.py implementer Smana/cloud-native-ref
```

Expected: `-> token ghs_…`; `push HEAD:refs/heads/<branch> -> ok`; `push HEAD:refs/heads/main ->` a
rejection (`GH013`/protected branch); `push HEAD:refs/heads/sc11-not-agent ->` a rejection
(`GH013: Repository rule violations`).

> Corrected 2026-09-27, round 3: **the exchange itself never succeeds, for any role** — see Platform
> findings. `curl 127.0.0.1:4001/sts/exchange?scope=Smana/cloud-native-ref&identity=agent-implementer`
> from inside a real implementer run's harness returns `{"code":7,"message":"token exchange failure
> (StatusUnprocessableEntity)"}`, HTTP 403, reproducibly. Nothing past this point in Step 4 (push to
> `agent/**`, rejection on `main`) could be exercised — there is no token to push with.

**What this proves:** SC-11 (the push half) — an implementer's token is scoped to `contents: write`,
but the branch ruleset (`agent/**` only, every other actor confined) is what actually stops it from
touching `main` or any non-`agent/**` branch, since the token permission alone would allow both.

### Step 5 — reviewer cannot push; no token for another repository or role; octo-sts unreachable directly

```bash
kubectl cp /tmp/sc11.py agents/$REVW:/tmp/sc11.py -c harness
kubectl exec -n agents $REVW -c harness -- /usr/local/bin/python /tmp/sc11.py reviewer Smana/cloud-native-ref
kubectl exec -n agents $IMPL -c harness -- /usr/local/bin/python /tmp/sc11.py implementer Smana/crossplane-configuration
kubectl exec -n agents $REVW -c harness -- /usr/local/bin/python /tmp/sc11.py implementer Smana/cloud-native-ref
kubectl exec -n agents $IMPL -c harness -- /usr/local/bin/python -c "import urllib.request; urllib.request.urlopen('http://octo-sts.agent-system.svc.cluster.local:8080/', timeout=5)" ; echo "exit=$?"
```

Expected: the reviewer gets a token but every push is rejected (`403`/permission — its trust policy
grants only `contents: read`); the other repository's exchange fails (`HTTP Error 403`/
`PermissionDenied`: no trust policy there, App not installed); the reviewer asking for
`agent-implementer` fails (audience mismatch — its projected token's audience is
`octo-sts/Smana/cloud-native-ref/reviewer`, not `.../implementer`); the direct call to octo-sts's
Service exits 1 — a run's CNP opens no path to octo-sts except through `agent-router`'s `sts`
listener (`http://octo-sts.agent-system.svc.cluster.local:8080` is not in the allowlist at all).

> Corrected 2026-09-27, round 3, verified live with the `agent-probe`'s `sts` token
> (audience `octo-sts/Smana/cloud-native-ref/implementer`, subject `agent-probe` — not a real run):
> - **reviewer push rejected:** not exercisable — reviewer's exchange 422s too (Platform findings),
>   so no token is ever issued to test a push with.
> - **cross-repo exchange:** `scope=Smana/crossplane-configuration&identity=agent-implementer` →
>   `{"code":5,"message":"unable to find trust policy for \"agent-implementer\""}`, **HTTP 404** — not
>   `403`/`PermissionDenied` as written; correct the expectation to this exact message and code.
> - **wrong-role/audience exchange:** `scope=Smana/cloud-native-ref&identity=agent-reviewer` with an
>   implementer-audience token → the *same* subject-pattern rejection as below, not a distinct
>   audience-mismatch error — octo-sts checks the caller's subject before it checks whether the
>   requested identity matches the token's audience, so this specific negative case is masked by the
>   probe's non-run subject and was not independently proven; it needs two real runs of different
>   roles cross-requesting each other's identity, which the 422 bug also blocks.
> - **probe's own subject rejected (new, not in the original text):**
>   `{"code":7,"message":"trust policy: subject \"system:serviceaccount:agents:agent-probe\" did not
>   match pattern \"system:serviceaccount:agents:xplane-run-[a-z2-7]{8}\"}"`, HTTP 403 — proves no
>   pod other than a real run's own projected identity can mint anything, regardless of role.
> - **direct octo-sts call:** the runbook's `python3` check doesn't apply (`agent-probe`'s `curl`
>   image has no `python3` — same gap as runbook 02). `curl --max-time 5
>   http://octo-sts.agent-system.svc.cluster.local:8080/` times out (`exit=28`), confirming the CNP
>   silently drops the packet rather than erroring — same shape as the original `exit=1`, different
>   command.

**What this proves:** SC-11 (the rest) and the `sts`-listener-only path — octo-sts's trust policies
match the EKS issuer by *pattern* (`OD-5`), which alone would accept a token minted by any EKS
cluster in the region; it is safe only because every token that reaches octo-sts has already been
verified against *this* cluster's exact issuer and JWKS by the `sts` listener, and nothing in `agents`
can route around it.

### Step 6 — clean up and record

```bash
IMPL_BRANCH=$(kubectl get agentrun -n agents $IMPL -o jsonpath='{.status.branch}')
kubectl delete agentrun -n agents $IMPL $REVW --wait
gh api --method DELETE "repos/Smana/cloud-native-ref/git/refs/heads/${IMPL_BRANCH#refs/heads/}"
kubectl logs -n agent-system deploy/octo-sts | grep -iE 'exchange|subject' | tail -5
```

Expected: the branch deleted; octo-sts log lines naming the run subjects
(`system:serviceaccount:agents:xplane-run-<id>`).

> Corrected 2026-09-27, round 3: no branch was ever created (no working exchange, see above), so
> nothing to delete. octo-sts's logs name the subject only on a **rejected** exchange (the WARN
> line); a request that clears the subject/issuer check logs `exchange request: "agent-implementer"`
> and `found trust policy in cache for {Smana cloud-native-ref agent-implementer}` — no
> `system:serviceaccount:agents:xplane-run-<id>` string appears anywhere for a passing check.

## Results

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — ruleset active | `active` | `active` | PASS |
| 2 — octo-sts up | `Ready=True` | `octo-sts` `SUSPENDED=False READY=True`, pod `1/1 Running` | PASS |
| 4 — implementer exchange succeeds | `-> token ghs_…` | `{"code":7,"message":"token exchange failure (StatusUnprocessableEntity)"}`, HTTP 403, from a real implementer run (`xplane-run-bx7qwi6i`) — reproducible on retry | **FAIL** (platform bug, see Platform findings) |
| 4 — implementer push to own branch / `main` / unrelated | `ok` / rejected / rejected | Not attempted — no token from the step above | BLOCKED (platform bug, same as above) |
| 5 — reviewer exchange | Token issued | Same `StatusUnprocessableEntity` 422/403, from a real reviewer run (`xplane-run-iqeuqxbv`) | **FAIL** (platform bug, same) |
| 5 — reviewer push rejected | Push rejected | Not attempted — no token issued | BLOCKED (platform bug, same) |
| 5 — cross-repo exchange | `403`/`PermissionDenied` | `agent-probe`'s token, `scope=Smana/crossplane-configuration`: `{"code":5,"message":"unable to find trust policy for \"agent-implementer\""}`, HTTP 404 | PASS (denied, as intended — wrong status code/message in the original text, corrected above) |
| 5 — wrong-role exchange | Audience mismatch failure | Masked by the probe's own subject-pattern rejection (see correction above) — not independently proven | BLOCKED (needs two real runs; also hits the 422 bug) |
| 5 — non-run subject rejected (new) | — | `agent-probe`'s token → `{"code":7,"message":"trust policy: subject ... did not match pattern ..."}`, HTTP 403, for every identity/scope tried | PASS |
| 5 — direct octo-sts call | `exit=1` | `curl --max-time 5` to the Service directly → timeout, `exit=28` (CNP silently drops it) | PASS (corrected: no `python3` in the probe image, used `curl` instead) |

**Static verification (code on `main` after #2113), all still match the runbook's claims:**
`.github/rulesets/agent-branches.json` — `target: branch`, `ref_name.include: ["~ALL"]` /
`exclude: ["refs/heads/agent/**"]`, rules `creation,update,deletion`, `bypass_actors: []`.
`.github/chainguard/agent-implementer.sts.yaml` — `permissions.contents: write`;
`agent-reviewer.sts.yaml` — `permissions.contents: read`. Both `subject_pattern:
'system:serviceaccount:agents:xplane-run-[a-z2-7]{8}'`, matching the run's real ServiceAccount name.
Both also request `checks: read` and `actions: read` — see Platform findings for why every live
exchange against these policies 422s regardless of role.
