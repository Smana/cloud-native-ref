# GCP private ingress — live verification

Task 6 of [the plan](../plans/2026-08-25-gcp-private-ingress.md), against
[the design](2026-08-25-gcp-private-ingress-design.md).

**Date:** 2026-08-25 · **Cluster:** `gcp-0`, project `ogenki-435905`, `europe-west4-a`
**Branch deployed:** `worktree-gcp-private-ingress` @ `9dc52b23`
**Outcome:** 7 of 8 criteria PASS, 1 PARTIAL. Everything torn down afterwards.

---

## Criteria

### 1. Both Gateways Programmed — PASS

```
NAME                         CLASS              ADDRESS                                       PROGRAMMED
platform-tailscale-admin     cilium-tailscale   gateway-admin-priv-gcp-0.tail9c382.ts.net     True
platform-tailscale-general   cilium-tailscale   gateway-general-priv-gcp-0.tail9c382.ts.net   True
```

Conditions on both: `Accepted=True Programmed=True`.

This is also the live test of the final review's Important finding. `healthChecks` on a
Gateway asserts existence only; the branch now carries `healthCheckExprs` gating on
`Programmed`. `infrastructure-gapi` reached Ready **after** both Gateways were genuinely
programmed, not on object creation.

### 2. Per-cluster Tailscale devices — PASS

```
100.122.5.127   gateway-admin-priv-gcp-0     tagged-devices  linux
100.123.86.11   gateway-general-priv-gcp-0   tagged-devices  linux
```

Both carry the `-gcp-0` suffix from Task 1's `${cluster_name}` parameterisation. The
operator's own device hostname (final review, Minor 4) is also parameterised — verified in
the running deployment rather than in YAML:

```
$ kubectl get deploy operator -n tailscale -o jsonpath='{...OPERATOR_HOSTNAME...}'
tailscale-operator-gcp-0
```

### 3. Wildcard certificate from the offline-root chain — PASS

```
NAME                          READY   SECRET
private-gateway-certificate   True    private-gateway-tls

issuer=CN=Ogenki GCP Intermediate CA, O=Ogenki, C=FR
subject=C=FR, O=Ogenki, CN=*.priv.gcp.ogenki.io
notBefore=Aug 25 11:32:24 2026 GMT   notAfter=Nov 23 11:32:54 2026 GMT
```

90-day leaf, so cert-manager exercises renewal at ~60 days. Issued by the `openbao`
ClusterIssuer with no GCP-specific manifest — the shared `platform-private-gateway-certificate.yaml`
worked unchanged.

### 4. A real route served over the tailnet — PASS

```
$ curl --cacert <offline-root chain> https://probe.priv.gcp.ogenki.io/
http=200 ssl_verify=0 ip=100.123.86.11

served leaf: subject=CN=*.priv.gcp.ogenki.io  issuer=CN=Ogenki GCP Intermediate CA
```

`ssl_verify=0` is the part that matters: the chain validated against the offline root's
published bundle. A 200 with a non-zero verify result would mean TLS was not actually
trusted. The connection landed on `100.123.86.11` — the general Gateway's Tailscale address,
not a cloud load balancer.

### 5. external-dns created the record and its TXT registry — PASS

```
probe.priv.gcp.ogenki.io.     A    100.123.86.11
a-probe.priv.gcp.ogenki.io.   TXT  "heritage=external-dns,external-dns/owner=gcp-0,
                                    external-dns/resource=httproute/apps/probe"
```

Owner is `gcp-0`, and the registry names the source as `httproute/apps/probe` — so the
`gateway-httproute` source, the label filter and the namespace filter are all working.

This is the `GCPWorkloadIdentity` composition's **first consumer**, and it worked:

```
NAME                  SYNCED   READY
xplane-external-dns   True     True      (Responsive=True)
```

The claim went Ready in `kube-system`, the composition derived the ServiceAccount namespace
from the claim's own, and external-dns authenticated to Cloud DNS by subject with no key
material anywhere.

### 6. `policy: sync` actually prunes — PASS

Deleting the HTTPRoute removed **both** records within ~30s (the `--min-event-sync-interval`).
Creating records is the easy half; a registry that never prunes leaves a zone slowly filling
with dead names.

### 7. Two-gateway ACL split — PARTIAL

Verified:
- The admin Gateway accepts a route from `kube-system` (`Accepted=True ResolvedRefs=True`) —
  confirming its `allowedRoutes` namespace list, which does **not** include `apps`.
- It serves over the tailnet with a valid chain: `http=200 ssl_verify=0` on
  `probe-admin.priv.gcp.ogenki.io` → `100.122.5.127`, the admin Gateway's own device.
- The two Gateways are distinct devices with distinct Tailscale tags (`tag:admin` vs
  `tag:k8s`), which is what the ACL evaluates.

**Not verified: the denial.** Proving a non-admin device is refused needs a tailnet device
outside `group:admin`. `opentofu/shared/tailscale/variables.tfvars` sets
`admin_users = ["smainklh@gmail.com"]`, the tailnet owner — the only device available here.
Recorded as unverified rather than asserted from configuration. Testing it needs a second
tailnet device, or temporarily removing the owner from `group:admin`, neither of which was in
scope for this run.

### 8. Teardown leaves nothing billable — PASS

See *Teardown* below.

---

## Defects this deploy found

### `opentofu/gcp/openbao/management/variables.tfvars` was never committed (fixed, `9dc52b23`)

The stack could not be deployed from a clean checkout:

```
Error: Failed to read variables file
Given variables file variables.tfvars does not exist.
```

`*.tfvars` is gitignored repo-wide (`.gitignore:55`), and every other GCP stack —
`network`, `gke/init`, `gke/configure`, `openbao/cluster` — has its copy force-added past
that rule. `openbao/management` was missed in #1830. The gap was invisible because the file
existed **untracked** in the worktree where that stack was originally written and verified,
so its own live verification passed over the defect.

This is a defect in merged `main`, not in this branch. It is fixed here because it blocked
this branch's verification.

### `kubectl wait --for=condition=Accepted httproute/...` does not work

The plan's Task 6 Step 3 used it; it times out even on a healthy route:

```
error: timed out waiting for the condition on httproutes/probe
```

An HTTPRoute has no top-level `Accepted` condition — it lives under
`status.parents[].conditions`, per parent. The route was in fact `Accepted=True
ResolvedRefs=True` the whole time.

This is **the same shape** as the final review's Gateway `healthChecks` finding: a readiness
assertion that silently checks nothing because the Gateway API puts conditions where the
generic tooling does not look. Worth remembering as a class, not two incidents.

## Two credentials the plan did not list as prerequisites

Both cost a round trip mid-deploy:

- **AWS credentials.** A GCP-only deploy failed at `tofu init` with `No valid credential
  sources found`, purely because GCP state still lives in the S3 bucket. This is the coupling
  ADR-0018 / PR #1831 removes, demonstrated concretely rather than argued.
- **`TF_VAR_tailscale_api_key`.** The network stack manages tailnet ACLs and auth keys and
  has no default for it.

`docs/gcp-bootstrap.md` covers the three GCP-side prerequisites but says nothing about what
must be in the operator's shell. Worth a follow-up section.

## Teardown

`terramate script run --reverse destroy` across all GCP stacks, then verified against the
API rather than the exit code — a teardown in this repo has previously reported success
while destroying nothing:

```
gcloud compute instances list      Listed 0 items.
gcloud container clusters list     (empty)
gcloud compute forwarding-rules    Listed 0 items.
gcloud compute addresses list      Listed 0 items.
gcloud compute networks list       default
gcloud compute disks list          (empty)
gcloud dns record-sets list        404 — the managed zone itself is gone
tailscale status | grep -c gcp-0   0
```

Two things went better than the previous GCP teardown:

- **No leaked disks.** The earlier run left an unattached 5 GB `pvc-*` volume from
  `flux-system/source-controller`. None this time.
- **No stale tailnet devices.** Both Gateway devices and the operator's own deregistered on
  teardown, so the per-cluster hostnames did not accumulate. Criterion 8's "leaves no
  Tailscale device" is met without hand-cleanup.

Deliberate survivors, not leaks:

```
KMS   openbao-dev/openbao-unseal          GCP cannot delete a key ring or crypto key, and
                                          destroying it would make any sealed OpenBao
                                          unrecoverable. Costs nothing idle.
Secrets  flux-github-app, openbao-priv-gcp-{ca-chain, intermediate-ca, recovery-keys,
         root-token, server-cert}, tailscale-k8s-operator-oauth
```

`openbao-priv-gcp-approle-cert-manager` is **absent** from that list — the management
stack's unconditional sweep removed it, which is the one credential-bearing secret that
outlives OpenBao itself.
