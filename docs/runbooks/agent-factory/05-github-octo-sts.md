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

## Results

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — ruleset active | `active` | Empty result — no ruleset named `agent-branches` exists on the repo yet | BLOCKED (owner action 3) |
| 2 — octo-sts up | `Ready=True` | `octo-sts` Ready=False (`dependency 'flux-system/agent-secrets' is not ready`) | BLOCKED (owner action 1) |
| 4 — implementer push to own branch | `ok` | Not attempted — no run reaches `Running` with a working `sts` exchange until owner actions 1/3/4 land | BLOCKED (owner action 1, 3, 4) |
| 4 — implementer push to `main` | Rejected (`GH013`) | Same | BLOCKED (owner action 1, 3, 4) |
| 4 — implementer push to unrelated branch | Rejected (`GH013`) | Same | BLOCKED (owner action 1, 3, 4) |
| 5 — reviewer push | Token issued, push rejected | Same | BLOCKED (owner action 1, 3, 4) |
| 5 — cross-repo exchange | `403`/`PermissionDenied` | Same | BLOCKED (owner action 1, 3, 4) |
| 5 — wrong-role exchange | Audience mismatch failure | Same | BLOCKED (owner action 1, 3, 4) |
| 5 — direct octo-sts call | `exit=1` | Not attempted live; structurally true today regardless — `octo-sts`'s Service does not exist yet either (Kustomization never reconciled) | BLOCKED (owner action 1) |

**Static verification (code at 76716898), all match the runbook's claims:**
`.github/rulesets/agent-branches.json` — `target: branch`, `ref_name.include: ["~ALL"]` /
`exclude: ["refs/heads/agent/**"]`, rules `creation,update,deletion`, `bypass_actors: []`.
`.github/chainguard/agent-implementer.sts.yaml` — `permissions.contents: write`;
`agent-reviewer.sts.yaml` — `permissions.contents: read`. Both `subject_pattern:
'system:serviceaccount:agents:xplane-run-[a-z2-7]{8}'`, matching the run's real ServiceAccount name.
`opentofu/aws/openbao/management/policies/agents-secrets.hcl` scopes to `platform/data/agents/*`
only. `container-images/agent-harness/git_credential_agent.py` and
`infrastructure/base/agent-runtime/identity-proxy-configmap.yaml` confirm the `sc11.py` probe's
`http://127.0.0.1:4001/sts/exchange?scope=<repo>&identity=agent-<role>` contract and its `{"token":
...}` response shape exactly.
