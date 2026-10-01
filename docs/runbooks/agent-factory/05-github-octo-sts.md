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
  `Smana/cloud-native-ref` only, and its `app_id`/`private_key` written to `github-app` on the cluster's
  `agents` mount.

## Steps

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
IMPL=$(task agent:run -- --role implementer --class public --minutes 20 --task "Run 'sleep 600' in the terminal, then finish. Change nothing." | tail -1); echo "$IMPL"
REVW=$(task agent:run -- --role reviewer --class public --minutes 20 --task-url "https://github.com/Smana/cloud-native-ref/pull/1" | tail -1); echo "$REVW"
kubectl wait -n agents agentrun/$IMPL agentrun/$REVW --for=jsonpath='{.status.phase}'=Running --timeout=15m
```

A reviewer run refuses `--task` text, so it cannot be paced: it ends when its review does. Run
Step 5's reviewer lines soon after this wait; if `$REVW`'s pod is gone, start another reviewer run.

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
grants only `contents: read`, so `remote: Permission to Smana/cloud-native-ref.git denied to
ogenki-agents[bot]`); the other repository's exchange fails with `HTTP Error 404`
`{"code":5,"message":"unable to find trust policy for \"agent-implementer\""}` (no trust policy
there); the reviewer asking for `agent-implementer` fails with a `403` `code 7` audience mismatch (its
projected token's audience is `octo-sts/Smana/cloud-native-ref/reviewer`, not `.../implementer`);
the direct call to octo-sts's Service exits 1 — a run's CNP opens no path to octo-sts except through
`agent-router`'s `sts` listener.

**What this proves:** SC-11 (the rest) and the `sts`-listener-only path. The trust policy's issuer
has two alternatives: gcp-0's GKE issuer, fixed by project, location and cluster name (#2122), and
aws-0's EKS issuer, matched by *pattern* because its ID changes on every aws-0 rebuild. The EKS
alternative is dormant while aws-0 is down. Either alternative alone would accept a token minted by
any cluster matching it; it is safe only because every token that reaches octo-sts has already been
verified against *this* cluster's exact issuer and JWKS by the `sts` listener, and nothing in
`agents` can route around it.

### Step 6 — clean up and record

```bash
IMPL_BRANCH=$(kubectl get agentrun -n agents $IMPL -o jsonpath='{.status.branch}')
kubectl delete agentrun -n agents $IMPL $REVW --wait
gh api --method DELETE "repos/Smana/cloud-native-ref/git/refs/heads/${IMPL_BRANCH#refs/heads/}"
kubectl logs -n agent-system deploy/octo-sts | grep -iE 'exchange|subject' | tail -5
```

Expected: the branch deleted (`204`); octo-sts logs `exchange request: "agent-implementer"` for
each exchange, and names the subject (`system:serviceaccount:agents:xplane-run-<id>`) only on a
rejected one (`WARN token does not match trust policy`).

## Results

### Round 7 — gcp-0, 2026-09-30 (`integration/agent-factory` @ `a2c645ba`)

The gcp-0 issuer alternative is on `main` (#2122): the implementer trust policy's `issuer_pattern` carries
`https://container\.googleapis\.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0`.
Runs: implementer `xplane-run-6qnowwxl`, reviewer `xplane-run-x6jexfi4` (task URL `pull/1`; a reviewer run
refuses `--task` text: `a reviewer run needs a pull request URL as its task`).

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — ruleset active | `active` | `active` | PASS |
| 2 — octo-sts up | `Ready=True` | `octo-sts` `Ready=True` | PASS |
| 4 — implementer exchange | `-> token ghs_…` | `exchange Smana/cloud-native-ref implementer -> token ghs_…`, a GKE-issued token accepted by the `sts` listener and by octo-sts | PASS |
| 4 — push to own branch | `ok` | `push HEAD:refs/heads/agent/6qnowwxl -> ok` | PASS |
| 4 — push to `main` | Rejected (`GH013`) | `remote: error: GH013: Repository rule violations found for refs/heads/main.` / `Cannot update this protected ref.` / `push declined due to repository rule violations` | PASS |
| 4 — push to a non-`agent/**` branch | Rejected (`GH013`) | `GH013: Repository rule violations found for refs/heads/sc11-not-agent` | PASS |
| 5 — reviewer exchange | Token issued | `exchange Smana/cloud-native-ref reviewer -> token ghs_…` | PASS |
| 5 — reviewer push rejected | Push rejected | Every push, `rc=128`: `remote: Permission to Smana/cloud-native-ref.git denied to ogenki-agents[bot].` (HTTP 403) | PASS |
| 5 — cross-repo exchange | denied | `HTTP Error 404: Not Found {"code":5,"message":"unable to find trust policy for \"agent-implementer\""}` | PASS |
| 5 — wrong-role exchange | Audience mismatch, both directions | Implementer asking for `agent-reviewer`: `403 {"code":7,"message":"trust policy: audience \"octo-sts/Smana/cloud-native-ref/reviewer\" did not match any of [\"octo-sts/Smana/cloud-native-ref/implementer\"]"}`. Reviewer asking for `agent-implementer`: the symmetric 403 | PASS |
| 5 — non-run subject rejected | 403 | `agent-probe`'s `sts` token on `:8082`: `{"code":7,"message":"trust policy: subject \"system:serviceaccount:agents:agent-probe\" did not match pattern …"}` HTTP 403 | PASS |
| 5 — direct octo-sts call | `exit=1` | `urlopen('http://octo-sts.agent-system.svc.cluster.local:8080/')` → exit=1 | PASS |
| 6 — revoke, branch, logs | Tokens revoked; branch deleted; log lines | Every minted token revoked (`DELETE /installation/token` → `204`). `agent/6qnowwxl` deleted through `gh api --method DELETE`. octo-sts logged `exchange request: "agent-implementer"` and the two `WARN token does not match trust policy` lines above | PASS |

### Earlier rounds — aws-0

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — ruleset active | `active` | `active` | PASS |
| 2 — octo-sts up | `Ready=True` | `octo-sts` `SUSPENDED=False READY=True`, pod `1/1 Running` | PASS |
| 4 — implementer exchange succeeds | `-> token ghs_…` | Round 4 (App fixed — `pull_requests: write` granted + installation accepted): real run `xplane-run-c4cnkg6r`, `/sts/exchange?scope=Smana/cloud-native-ref&identity=agent-implementer` → token minted (`ghs_...`, len 390); `GET /repos/Smana/cloud-native-ref` → `200` | PASS |
| 4 — implementer push to own branch | `ok` | `push HEAD:refs/heads/agent/c4cnkg6r -> ok` | PASS |
| 4 — implementer push to `main` | Rejected (`GH013`) | `remote: error: GH013: Repository rule violations found for refs/heads/main` / `Cannot update this protected ref` / `Changes must be made through a pull request` — push declined | PASS |
| 5 — reviewer exchange | Token issued | `xplane-run-p5h6crk6`, `identity=agent-reviewer` → token minted (len 390); `GET /repos/...` → `200` | PASS |
| 5 — reviewer push rejected | Push rejected | `push agent/p5h6crk6` → `returncode 128`, `remote: Permission to Smana/cloud-native-ref.git denied to ogenki-agents[bot]`, HTTP 403 — rejected at the App-token permission level (`contents: read`), never reaches the ruleset | PASS |
| 5 — cross-repo exchange | `403`/`PermissionDenied` | `agent-probe`'s token, `scope=Smana/crossplane-configuration`: `{"code":5,"message":"unable to find trust policy for \"agent-implementer\""}`, HTTP 404 | PASS (denied, as intended — wrong status code/message in the original text, corrected above) |
| 5 — wrong-role exchange | Audience mismatch failure | Round 4, both directions, with two real runs' own tokens: implementer run requesting `agent-reviewer` → `{"code":7,"message":"trust policy: audience \"octo-sts/.../reviewer\" did not match any of [\"octo-sts/.../implementer\"]"}`, HTTP 403; reviewer run requesting `agent-implementer` → the symmetric audience-mismatch 403 | PASS |
| 5 — non-run subject rejected (new) | — | `agent-probe`'s token → `{"code":7,"message":"trust policy: subject ... did not match pattern ..."}`, HTTP 403, for every identity/scope tried | PASS |
| 5 — direct octo-sts call | `exit=1` | `curl --max-time 5` to the Service directly → timeout, `exit=28` (CNP silently drops it) | PASS (corrected: no `python3` in the probe image, used `curl` instead) |
| 6 — revoke | — | Both runs' tokens: `DELETE /installation/token` → `204`, immediately after use | PASS |

Round 4 note: the App fix landed between rounds (`pull_requests: read & write` granted, installation
accepted the change) — see the README's Platform findings for round 3's diagnosis. All FAIL/BLOCKED
rows from round 3 are now PASS; nothing in this runbook remains blocked or failing.

**Static verification (code on `main` after #2113), all still match the runbook's claims:**
`.github/rulesets/agent-branches.json` — `target: branch`, `ref_name.include: ["~ALL"]` /
`exclude: ["refs/heads/agent/**"]`, rules `creation,update,deletion`, `bypass_actors: []`.
`.github/chainguard/agent-implementer.sts.yaml` — `permissions.contents: write`;
`agent-reviewer.sts.yaml` — `permissions.contents: read`. Both `subject_pattern:
'system:serviceaccount:agents:xplane-run-[a-z2-7]{8}'`, matching the run's real ServiceAccount name.
Both also request `checks: read` and `actions: read`. Round 3's 422 on every exchange came from the
App missing `pull_requests: read & write`, not from these; fixed in round 4 (README, Platform
findings).
