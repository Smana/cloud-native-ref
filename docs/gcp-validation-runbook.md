# GCP end-to-end validation runbook

A from-scratch run that proves `gcp-0` reaches parity on the three things no gate
in this repository can check: that a model **serves**, that a database
**bootstraps from a backup**, and that **runlore can read GCP**.

Everything here is manual and destructive-by-design. `gcp-0` is rebuilt from
scratch and torn down after every run; nothing below assumes otherwise.

## Why this exists

CI validates structure. `validate-manifests.sh` renders every overlay and every
chart, `check-substitution.py` proves each `${var}` is defined, and both stay
green against configuration that is valid, well-formed and wrong for the cloud
it lands on. Two examples found on 2026-08-27, both silent:

- The Barman plugin's egress allowlist named `s3.${region}.amazonaws.com`.
  `region` **is** defined on `gcp-0`, so it substituted cleanly to
  `s3.europe-west4.amazonaws.com` — a valid policy resolving to nothing. The
  only symptom would have been backups that never complete.
- runlore's metadata-server rule used `toEntities: [host]`, correct on EKS.
  On GKE Cilium does not classify `169.254.169.254` as the host entity, so the
  rule matched nothing and surfaced as `gcp: project is required (autodetection
  found none)` — which reads as a config mistake, not a dropped packet.

Neither is findable without running the thing. That is what this runbook is for.

## Three structural facts, before you plan the run

**1. Serve one model, not four.** `apps/gcp-0/llm` pulls all of
`apps/base/ai/llm`: `qwen3-8b`, `qwen-coder`, `qwen-coder-fim` and
`llamaguard3-1b`. Each claims one GPU and each preload pulls its weights from
HuggingFace, so the default is four L4s and roughly an hour before anything
serves. For validating *GCP support*, three of them prove nothing that the
fourth does not.

Keep `qwen3-8b`. It is the only one that fits the test: `routing.tier: medium`,
`specialty: general`, and `toolCallParser: hermes` — runlore needs tool calling.
It is also still a defensible pin in 2026; the stale ones are the coder models
(`Qwen2.5-Coder`, late 2024, with Qwen3-Coder long since released). Refresh
those separately — not inside this run, where they are dead weight.

**2. The restore test needs two deploy cycles.** `objectStoreRecovery` restores
from a prefix captured *earlier*. A fresh bucket has nothing to restore from,
and pointing the claim at an empty prefix fails the bootstrap rather than
starting a fresh database. So the run is: deploy → back up → move the backup
aside → tear down → deploy again with recovery configured. Phases 5–7 below.

**3. The LLM umbrella's known blockers are closed, and unproven.** Both the
serving-pod identity and KEDA are resolved at the pinned
`crossplane-configuration` v0.4.1 — see
[`clusters/gcp-0-llm-platform/README.md`](../clusters/gcp-0-llm-platform/README.md).
That is a static read of the pinned package's golden fixture, not a cluster
result. Phase 3 is the first time it runs anywhere.

---

## Phase 0 — prerequisites

[`docs/gcp-bootstrap.md`](gcp-bootstrap.md) lists three things OpenTofu does not
manage. After a teardown, check which survive:

| Prerequisite | Survives teardown? |
|---|---|
| Cloud KMS key ring `openbao-dev` | **Yes, by design** — GCP cannot delete key rings |
| OpenTofu state bucket | Yes |
| Tailscale OAuth client | Yes, unless revoked |

So a rebuild normally needs none of them re-created. Confirm rather than assume:

```bash
gcloud kms keyrings list --location europe-west4 --project ogenki-435905
gcloud storage ls --project ogenki-435905 | grep tfstate
```

**Exit criteria:** all three present.

## Phase 1 — bootstrap (cycle 1)

`opentofu/gcp/network` has an `after` edge on `/opentofu/shared/tailscale`, so
the shared stacks come first. A GCP-only teardown leaves them intact, so this is
usually a no-op — but a truly clean project needs them.

```bash
# only if the shared stacks are not already applied
terramate -C opentofu/shared script run deploy

# the GCP stacks: network -> openbao/{cluster,management} -> gke/{init,configure}
TM_GCP_ENABLED=true \
TF_VAR_flux_git_ref=refs/heads/<your-branch> \
  terramate -C opentofu/gcp script run deploy
```

Also apply `opentofu/shared/aws-gcp-federation` if you want public ingress —
without it cert-manager and external-dns fail with `AccessDenied`, which
`gcp-bootstrap.md` warns reads like a stuck deploy but is not.

```bash
gcloud container clusters get-credentials gcp-0 \
  --zone europe-west4-a --project ogenki-435905 --internal-ip
flux get kustomizations -n flux-system
```

**Exit criteria:** every Flux Kustomization `Ready=True`. Expect a few minutes
of `AccessDenied` churn early if the federation stack lagged; that is documented
noise, not failure.

## Phase 2 — trim to one model

Edit `apps/gcp-0/llm/kustomization.yaml` so it selects only the `qwen3-8b` claim
rather than taking all of `../../base/ai/llm`. Commit and push — `gcp-0` tracks
your branch, not `main`.

**Exit criteria:** `./scripts/validate-manifests.sh` → `Invalid: 0, Skipped: 0`.

## Phase 3 — serve a model

```bash
flux resume kustomization llm-platform -n flux-system
flux get kustomizations -n flux-system | grep llm-platform
```

Watch in the order it can fail — this ordering is the point, because a FUSE
identity failure looks like a stuck mount and names nothing:

```bash
# 1. the per-claim identity binding exists
kubectl get gcpworkloadidentity -n llm

# 2. the serving pod actually mounts the weights bucket  <-- the real test
kubectl describe pod -n llm -l app.kubernetes.io/name=xplane-qwen3-8b

# 3. vLLM loads the model and reports ready
kubectl logs -n llm -l app.kubernetes.io/name=xplane-qwen3-8b --tail=50
```

**Exit criteria:** `GCPWorkloadIdentity` `Synced=True Ready=True`, the pod
`Running` with the bucket mounted, and vLLM serving. Getting past step 2 is the
thing this platform has never demonstrated.

## Phase 4 — point runlore at the served model

`observability/base/runlore/helmrelease.yaml` currently sends runlore to Z.ai:

```yaml
model:
  provider: openai
  model: glm-5.2
  base_url: https://api.z.ai/api/paas/v4/
```

vLLM behind Envoy AI Gateway is OpenAI-compatible, so this is a `base_url` and
`model` swap. Patch it in
`observability/gcp-0/runlore/helmrelease.yaml`, which already exists for exactly
this kind of per-cloud override — do **not** change the base, which `aws-0`
shares.

**Exit criteria:** runlore starts without config errors, and an investigation
produces output whose token usage appears in the vLLM metrics rather than at
Z.ai.

## Phase 5 — capture a backup, then set up the restore

Backups run on a schedule (`0 1 * * *` Harbor, `0 0 * * *` ZITADEL). Do not wait
for one:

```bash
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: preteardown
  namespace: security
spec:
  cluster:
    name: xplane-zitadel-cnpg-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
kubectl get backup preteardown -n security -w   # want phase=completed
```

Then **move** the prefix aside — never copy:

```bash
B=gs://ogenki-435905-ogenki-cnpg-backups
gcloud storage mv -r $B/xplane-zitadel-cnpg-cluster $B/zitadel-$(date +%Y%m%d)
```

Moving is load-bearing twice over. It leaves the live prefix empty, which barman
requires before a recreated cluster will begin archiving; and it decouples the
recovery seed from the live archive, so a bad day on the live cluster cannot
poison what you restore from. Copying leaves the live prefix populated and
wedges the next deploy — the trap documented in
`infrastructure/gcp-0/cloudnative-pg/gcs-bucket.yaml`.

**Exit criteria:** the dated prefix holds `base/` and `wals/`, and
`gcloud storage ls $B/` shows no `*-cnpg-cluster` prefix.

## Phase 6 — tear down, then redeploy with recovery

```bash
TM_GCP_ENABLED=true TM_DESTROY_CONFIRMED=true \
  terramate -C opentofu/gcp script run --reverse destroy
```

**Check the cloud, not the exit code.** A backgrounded
`terramate ... > log; tail log` reports `tail`'s status. On 2026-08-27 a run
looked like it succeeded at exit 0 while Terramate had refused to start and
destroyed nothing.

```bash
gcloud container clusters list --project ogenki-435905
gcloud compute instances list --project ogenki-435905
gcloud compute disks list --project ogenki-435905      # sweep orphaned pvc-*
```

Then add `objectStoreRecovery` to the ZITADEL claim in
`security/gcp-0/zitadel/kustomization.yaml`, pointing `path` at the dated prefix
from Phase 5 and `bucketName` at `${project_id}-ogenki-cnpg-backups`, and
redeploy as in Phase 1.

**Exit criteria:** the ZITADEL CNPG cluster reaches `Cluster in healthy state`,
and its logs show recovery from the dated prefix rather than `initdb`. The
decisive check is data, not status — the ZITADEL instance should carry the users
and OAuth apps from cycle 1:

```bash
kubectl logs -n security xplane-zitadel-cnpg-cluster-1 | grep -iE 'recovery|restore|initdb'
```

## Phase 7 — prove runlore reads GCP

This is the step the whole run exists for. `gcp: project is required
(autodetection found none)` is what a dropped metadata call looks like, so check
the packet path before believing a config error.

```bash
# provider actually initialised
kubectl logs -n runlore deploy/runlore | grep -i '"cloud"'    # want cloud:true, provider gcp

# metadata server reachable — ALLOWED, not DROPPED
hubble observe --pod runlore/ --to-ip 169.254.169.254 --last 20

# then an investigation that calls a GCP tool, and read its output
```

**Exit criteria:** `cloud:true`, metadata traffic `ALLOWED`, and an
investigation that returns real GCP data — not an empty result, which is what
insufficient IAM roles look like from the outside.

## Teardown

Same as Phase 6, plus the two things that outlive the stacks:

```bash
# 1. orphaned CSI disks — GKE does not remove PVC-backed PDs with the cluster
gcloud compute disks list --project ogenki-435905 --filter='name~^pvc-'

# 2. the backup bucket's live prefixes, or the next rebuild wedges
gcloud storage rm -r gs://ogenki-435905-ogenki-cnpg-backups/'*-cnpg-cluster'
```

Keep the dated recovery prefix if you want to re-run Phase 6 without re-running
Phase 5.

**Exit criteria:** zero GKE clusters, instances, disks, addresses, forwarding
rules and routers. Surviving by design: the KMS key ring, the state bucket, and
the `ogenki-harbor` / `ogenki-cnpg-backups` / `ogenki-llm-models` buckets, whose
`managementPolicies` deliberately omit `Delete`.

## What a pass actually claims

Each phase proves one thing that no gate in this repository can:

| Phase | Claim |
|---|---|
| 3 | GCS FUSE weights are readable by a serving pod's own identity |
| 4 | A self-hosted model can back runlore |
| 6 | A database restores from a GCS backup across a full rebuild |
| 7 | runlore authenticates to GCP and reads real data |

A failure in 3 or 7 is most likely a policy that is AWS-shaped and silent, not a
missing feature. Start with `hubble observe --verdict DROPPED`.
