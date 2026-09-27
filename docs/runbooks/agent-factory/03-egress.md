# 03 — Egress

Proves that a run's `CiliumNetworkPolicy` and the DNS L7 rule enforce the default-deny-plus-allowlist
egress model: allowed hosts (GitHub, the gateway) resolve and connect, everything else is refused at
name resolution, and a random subdomain under a non-allowed domain is denied at the DNS proxy rather
than merely dropped at L4. See [README.md](README.md) for prerequisites; run
[00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00 done. No owner action.

## Steps

### Step 1 — start a run

```bash
RUN=$(task agent:run -- --role implementer --class public --minutes 20 --task "Idle. Do nothing, change nothing." | tail -1); echo "$RUN"
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Running --timeout=15m
```

### Step 2 — allowed, denied and refused names

```bash
kubectl exec -n agents $RUN -c harness -- git ls-remote https://github.com/Smana/cloud-native-ref HEAD
kubectl exec -n agents $RUN -c harness -- /usr/local/bin/python -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)" ; echo "exit=$?"
kubectl exec -n agents $RUN -c harness -- /usr/local/bin/python -c "import socket, secrets; socket.getaddrinfo(secrets.token_hex(6)+'.example.org', 443)" ; echo "exit=$?"
kubectl exec -n agents $RUN -c harness -- /usr/local/bin/python -c "import socket; print(socket.getaddrinfo('api.github.com', 443)[0][4])"
```

Expected: a `HEAD` SHA; `exit=1` for `example.com`; `exit=1` for the random `*.example.org` name
(name resolution fails — it is refused, not merely unrouted); an IP tuple for `api.github.com` (Q4: a
bare public name resolves even with `ndots:1`, which changes only the search-path variants).

**What this proves:** SC-09 — allow, deny and refuse all behave as the design's egress profile
promises.

### Step 3 — Hubble verdicts confirm it is the DNS proxy, not chance (Q3)

```bash
NODE=$(kubectl get pod -n agents $RUN -o jsonpath='{.spec.nodeName}')
AGENT=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system $AGENT -- hubble observe --from-pod agents/$RUN --type l7 --protocol dns --last 30
kubectl exec -n kube-system $AGENT -- hubble observe --from-pod agents/$RUN --verdict DROPPED --last 30
```

Expected: DNS entries show `github.com`/`api.github.com` FORWARDED and `example.com` /
`*.example.org` REFUSED or DROPPED at the L7 DNS filter; the second command shows DROPPED TCP toward
`example.com`'s IPs only if something got far enough to try — a clean setup shows the drop already
happening at DNS, before any TCP attempt.

**What this proves:** Q3 — the FQDN allowlist and the DNS L7 rule work correctly under gVisor, ENI
mode and kube-proxy-replacement (KPR); a denied name never resolves, so nothing downstream ever
reaches L4.

### Cleanup

```bash
kubectl delete agentrun -n agents $RUN --wait
```

## Results

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 2 — `git ls-remote` | A SHA | `674175608fa9bdcf05a44190748e8de6bcae94c6\tHEAD` | PASS |
| 2 — `example.com` | `exit=1` | `socket.gaierror: ... Temporary failure in name resolution`, exit=1 | PASS |
| 2 — random `*.example.org` | `exit=1` | Same `gaierror`, exit=1 | PASS |
| 2 — `api.github.com` | An IP | `('140.82.121.5', 443)` | PASS |
| 3 — Hubble DNS | Allowed FORWARDED, denied REFUSED/DROPPED | `github.com`/`api.github.com` A+AAAA `FORWARDED`; `example.com`/`*.example.org` A+AAAA `DROPPED` at the DNS proxy | PASS |
| 3 — Hubble DROPPED | No TCP reaches a denied host | All DROPPED entries are `dns-request proxy DROPPED`; no TCP verdict toward `example.com`/`example.org` IPs at all | PASS |
