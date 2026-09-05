# OpenBao store of record — Stage 1 live verification

Companion to
[`2026-09-02-openbao-store-of-record-design.md`](2026-09-02-openbao-store-of-record-design.md)
and its plan. Every command below was run against the real AWS account
(`396740644681`, `eu-west-3`) on **2026-09-05**, and the output is quoted as it
came back.

Status: **in progress** — the PKI ceremony, the lineage stack and the
pre-initialisation seal reading are done. The platform deploy, the
destroy/rehydrate proof and the drill are not.

---

## Starting state

The platform was fully torn down when this run began: no EKS cluster, no VPC,
no OpenBao node. The snapshot bucket existed and was **empty**, which is the
documented precondition for the strict legacy-object policy — an empty bucket
takes the first-deploy path and never consults the seal gate.

| Fact | Value |
|---|---|
| `aws eks list-clusters` | `{"clusters": []}` |
| `s3://eu-west-3-ogenki-openbao-snapshot` | exists, **0 objects** |
| `alias/xplane-openbao-snapshot` | `b767b332-3f86-471b-a866-4a01ff325860` |
| `alias/openbao-seal` | absent |
| `certificates/priv.aws.ogenki.io/{root-ca,intermediate-ca,openbao}` | present; `ca-chain` absent |
| Offline root | `~/gcp-openbao-pki-ceremony/root-ca-key.pem`, `CN=Ogenki Root CA`, `notAfter=2036-08-24` |

---

## Two blockers fixed before any cloud work

### The `v0.3.0` image could never have published

`gh workflow run build-container-images.yml` failed with:

```
ERROR: failed to build: invalid tag "ghcr.io/smana/openbao-snapshot:-": invalid reference format
```

Root cause: the version-extraction step's `grep -oP "ARG ${ARG_NAME}=\K[^\s]+"`
was unanchored, and `container-images/openbao-snapshot/Dockerfile` documents the
ARG naming convention in a **comment on line 12**, above the real `ARG` on
line 15:

```
12:# `ARG OPENBAO_SNAPSHOT_VERSION=` (the directory name upper-cased + _VERSION) and
15:ARG OPENBAO_SNAPSHOT_VERSION=v0.3.0
```

`head -1` therefore took the comment's closing backtick, and
`docker/metadata-action` sanitised that into `-`.

Fixed by anchoring to `^ARG` (`9dee7d09`). Verified against both images:
`openbao-snapshot` → `v0.3.0`, `pev2` → `v1.17.0` unchanged.

This mattered beyond CI hygiene: `snapshot-cronjob.yaml` pins `v0.3.0` with
`imagePullPolicy: IfNotPresent`, so no tag means `ImagePullBackOff`, no manual
snapshot, and nothing for the rehydrate proof to restore.

### The GHCR package was unlinked and private

After the tag fix the build still failed:

```
denied: permission_denied: read_package    → then → write_package
```

`ghcr.io/smana/openbao-snapshot` had been pushed by hand on 2026-08-26 and was
`visibility=private`, `repository=null`. The workflow's `GITHUB_TOKEN` carries
`packages: write` for `Smana/cloud-native-ref`, which grants nothing on a
package linked to no repository. Making it public silenced `read_package` (that
is anonymous read, not an Actions grant) and exposed `write_package` underneath.

Resolved by deleting the package and letting the workflow recreate it, which
links it to the pushing repository automatically.

Final state:

| Property | Value |
|---|---|
| Visibility | `public` |
| Repository | `Smana/cloud-native-ref` |
| Tags | `v0.3.0`, `latest`, `worktree-openbao-lineage`, `…-9dee7d0` |
| Anonymous pull | succeeds (no credentials) |
| Architectures | `linux/amd64`, `linux/arm64` |

Anonymous pull is load-bearing: `snapshot-cronjob.yaml:100` declares no
`imagePullSecret`.

---

## The AWS PKI ceremony

Signed against the existing offline root — **not** a new one. The root was
untouched throughout (`root-ca.pem`/`root-ca-key.pem` kept their
`Aug 24 23:58` mtimes and the fingerprint below).

```
intermediate-ca.pem: OK
server.pem: OK
X509v3 Subject Alternative Name:
    DNS:bao.priv.aws.ogenki.io, DNS:bao.priv.gcp.ogenki.io,
    DNS:openbao.security.svc.cluster.local, DNS:openbao.security.svc
```

Resulting hierarchy — one root, one intermediate per cloud, which is the shape
the design asks for:

| Tier | Subject | Issuer |
|---|---|---|
| Root | `CN=Ogenki Root CA` (`D5:09:47:A4:E1:A6:51:20:…`) | self |
| AWS intermediate | `CN=Ogenki AWS Intermediate CA` | `CN=Ogenki Root CA` |
| GCP intermediate | `CN=Ogenki GCP Intermediate CA` | `CN=Ogenki Root CA` |
| AWS leaf | `CN=bao.priv.aws.ogenki.io`, 4 SANs | `CN=Ogenki AWS Intermediate CA` |

Before this, AWS chained to a *different* root (`CN=Ogenki`, with
`CN=Ogenki Intermediate` beneath it) and its leaf carried a single SAN. That is
what made the ceremony a migration rather than a renewal.

### Deviation: the plan's write verbs are wrong for two of three secrets

The plan issues `create-secret` for all three. On this account
`certificates/priv.aws.ogenki.io/intermediate-ca` already existed holding the
pre-lineage `{cert, key}` pair, so `create-secret` fails with
`ResourceExistsException`. What actually ran:

| Secret | Verb used | Result |
|---|---|---|
| `…/intermediate-ca` | `put-secret-value` | version `afc9926c-e537-430a-ba98-d89ab9f6cab9` |
| `…/ca-chain` | `create-secret` | created |
| `…/openbao` | `put-secret-value` | version `2867a80c-0861-4465-a976-af753a21acd1` |

`put-secret-value` is also the safer verb here because the *shape* changes —
`{cert, key}` → `{bundle}` — and only the new shape satisfies
`jsondecode(...)["bundle"]` in `pki.tf:43`. The old version stays recoverable.

Read back from Secrets Manager afterwards:

```
intermediate-ca  keys: bundle
                 subject=CN=Ogenki AWS Intermediate CA  issuer=CN=Ogenki Root CA
ca-chain         keys: ca            (2 certificates)
openbao          keys: ca,cert,key
                 issuer=CN=Ogenki AWS Intermediate CA, 4 SANs
leaf verifies against the offline root: leaf.pem: OK
```

### Note on the working directory

The ceremony was run inside `~/gcp-openbao-pki-ceremony/` rather than a scratch
directory, which overwrote six GCP artefacts sharing the same filenames
(`intermediate-ca.{pem,key,csr,cnf,srl}`, `ca-chain.pem`). Nothing was lost:
`openbao-priv-gcp-intermediate-ca` in GCP Secret Manager still yields both
certificate and key and verifies `OK` against the root. The root pair itself was
not among the overwritten files.

The root **certificate** is committed as `.github/openbao-root-ca.pem`
(`6757cd03`), key-free (0 `PRIVATE KEY` blocks) and matching the offline root's
fingerprint. The intermediate and leaf keys were shredded.

---

## The lineage stack

Imports first, because the bucket and KMS key were Crossplane-managed and this
PR moves them to OpenTofu. The plan for this is:

```
Plan: 9 to add, 4 to change, 0 to destroy.
```

All four changes were in-place, none a replacement. One deserved a look: the
bucket's default SSE key moved from `85ca6e71-…` — an **unaliased orphan** — to
`b767b332-…`, the key `alias/xplane-openbao-snapshot` actually points at. Safe
because the bucket held 0 objects, and a cleanup rather than a regression.

After `terramate script run deploy`:

| Check | Result |
|---|---|
| Seal key | `mrk-dbd7c4a34a7f41f3811f45ee2ec0cf9b`, `PRIMARY`, `eu-west-3` |
| Multi-region + replica region | `[True, "eu-west-1"]` — **exit criterion 2 met** |
| Replica in `eu-west-1` | `REPLICA`, `Enabled` |
| Drill role | `arn:aws:iam::396740644681:role/openbao-restore-drill` |
| GitHub OIDC provider | `token.actions.githubusercontent.com` |
| Bucket versioning | `Enabled` |
| Public access block | `True` |
| Snapshot key rotation | `False` → `True` |

`AWS_DRILL_ROLE_ARN` set as a repository variable.

The `mrk-` prefix confirms a true multi-region key: snapshots wrapped in
`eu-west-3` are readable by the `eu-west-1` replica, which is what makes a
cross-cloud standby possible at all.

---

## Design risk settled: an uninitialised node reports its seal over TLS

The design's largest untested assumption. Both seal selectors read `.type` from
`GET /v1/sys/seal-status`, and `rehydrate`'s gate sits **before**
`bao operator init` — so it queries an OpenBao that is up and deliberately not
yet initialised. There was source-level proof and no live confirmation, and the
code fails closed: an empty `.type` blocks every deploy.

The window was created deliberately by applying `opentofu/aws/openbao/cluster`
on its own and stopping before `opentofu/aws/openbao/management`.

```json
{
  "type": "awskms",
  "initialized": false,
  "recovery_seal": true,
  "sealed": true,
  "version": "2.6.2"
}
```

| Field | Establishes |
|---|---|
| `type: "awskms"` | The barrier seal is legible before init — the value naming every snapshot object and compared by both gates |
| `initialized: false` | The reading was taken inside the window, not in the easy post-init case |
| `recovery_seal: true` | A real KMS barrier rather than a default |
| `version: "2.6.2"` | Rules out the pre-2.4.0 behaviour where `.type` was hardcoded `"shamir"` |

**Connectivity note.** `bao.priv.aws.ogenki.io` does not resolve over MagicDNS;
the tailnet routes the VPC but private Route53 names need VPC DNS. Resolved via
`dig @10.0.0.2` → `10.0.15.250`, `10.0.47.250`, `10.0.31.250` (the fixed NLB
addresses; `10.0.15.250` is the `openbao_target_ip` default), then reached with
`curl --resolve`.

### The new PKI confirmed live at the same time

TLS on that node terminates on the leaf issued this morning:

```
subject=CN=bao.priv.aws.ogenki.io
issuer=CN=Ogenki AWS Intermediate CA
X509v3 Subject Alternative Name:
    DNS:bao.priv.aws.ogenki.io, DNS:bao.priv.gcp.ogenki.io,
    DNS:openbao.security.svc.cluster.local, DNS:openbao.security.svc
Verification: OK
Verify return code: 0 (ok)
```

`openbao.security.svc.cluster.local` is present on a running node — the name
whose absence would have failed both clusters' `ClusterIssuer` with
`x509: certificate is valid for bao.priv.aws.ogenki.io, not
openbao.security.svc.cluster.local`.

---

## Repository changes made during this run

| Commit | What |
|---|---|
| `9dee7d09` | Anchor the version-ARG grep so a Dockerfile comment cannot win |
| `73b3a8c2` | PKI page: the leaf-issuance block it only described |
| `9b07dd16` | PKI page: warn that the root block builds a **new** lineage |
| `269178df` | PKI page: "Storing the chain", incl. the create-vs-put trap |
| `e858fb55` | PKI page: drop the internal plan's task IDs from a published page |
| `7e1e7bea` | PKI page: "Committing the root certificate" |
| `6757cd03` | Commit the offline root certificate |
| `c98dcde2` | Merge `origin/main`; ADR renumbered `0032` → **`0033`** |

The ADR renumber was forced by a collision: `main` merged `0032` as workforce
identity federation while this branch also used `0032`.

---

---

## The platform deploy

### Deviation: the deploy silently built `main`

`TF_VAR_flux_git_ref` was absent from the invocation that created the
FluxInstance. `flux_git_ref` defaults to `refs/heads/main`, nothing warns, and
the deploy succeeded — having pointed Flux at main's manifests while the
infrastructure underneath came from this branch.

The two are individually consistent and jointly irreconcilable. Main's
`security-openbao` substitutes from `Secret/cert-manager-openbao-approle`,
written by the AppRole resources this branch deletes:

```
Ready=False: post build failed for 'ClusterSecretStore':
  substitute from 'Secret/cert-manager-openbao-approle'
  error: secrets "cert-manager-openbao-approle" not found
```

That blocked `security`, and through it `observability`, `apps`,
`flux-operator` and `flux-notifications`. ZITADEL sits downstream of all of
them, so `eks/init`'s 45-minute ZITADEL wait was decided at its first poll and
spent the rest of its budget confirming it.

Re-running with the variable set flipped `spec.sync.ref` within ~40s, and
`security-openbao` reconciled immediately afterwards. Recorded as PR follow-ups
1-3, with the ordering and lint findings below.

### Result

| Check | Result |
|---|---|
| `spec.sync.ref` | `refs/heads/worktree-openbao-lineage` |
| `lastAppliedRevision` | `99ecefdd1658` — branch HEAD |
| `security-openbao` | Ready |
| ZITADEL | ready **~180s** after the ref flip (against a 45m budget) |

CNPG's first recovery pod failed on `Unable to locate credentials` — an EKS Pod
Identity race, not the known empty-archive refusal — and CNPG's own retry
completed with `restore command execution completed without errors`.

## Design risk settled: the cert-manager audience

The `ClusterIssuer` reports:

```
Ready=True: Vault verified
```

**No `bound_audiences` change was needed.** cert-manager's
`serviceAccountRef.audiences` are additive — the vendored CRD states the default
`vault://openbao` is always included — so the token carries a two-element `aud`
against a role bound to `openbao` alone, and OpenBao matches if *any* audience
is in `bound_audiences`. That was reasoned in the plan and is now observed.
Stage 2's other JWT consumers therefore need no audience pair either.

One condition proves four of this PR's mechanisms at once:

| Mechanism | Observed |
|---|---|
| Neutral in-cluster name | `server=https://openbao.security.svc.cluster.local:8200` |
| JWT rather than AppRole | `path=/v1/auth/jwt/aws-0`, `role=cert-manager` |
| ExternalName Service, `local` form | `openbao` → `bao.priv.aws.ogenki.io` |
| The `serviceaccounts/token` RBAC | `cert-manager-token-creator` Role + RoleBinding present |

`bao auth list` equivalent at this point: `jwt/aws-0/`, `token/`, `userpass/` —
**no `approle/`**. `auth/jwt/aws-0/role` lists `cert-manager`,
`external-secrets`, `openbao-snapshot`.

## The first snapshot

A manual run of the CronJob (`Complete`, 30s):

```
INFO: Authenticating with OpenBao via auth/jwt/aws-0 as role openbao-snapshot...
INFO: This node's seal is 'awskms'; the object will carry it.
INFO: Stamping lineage/check_timestamp before the snapshot
INFO: Requesting a snapshot via https://openbao.security.svc.cluster.local:8200
INFO: Wrote 2026-09-05T092947Z-awskms.snap
```

| Property | Value |
|---|---|
| Object | `2026-09-05T092947Z-awskms.snap` — seal in the name |
| Size | 74,785 bytes |
| Encryption | `aws:kms` under `b767b332…`, the aliased key |
| Freshness marker | `lineage/check_timestamp = 1788600586` |

`ISSUER_BEFORE`, for the rehydrate proof:

```
8A:C4:25:40:F3:40:CA:44:5C:2E:95:F3:9A:BC:BF:C1:C4:43:70:C3:B8:05:6F:D3:C4:A5:A6:E6:6B:D1:A2:57
```

---

## Follow-ups raised on the PR (not changed here)

| # | Finding |
|---|---|
| [1](https://github.com/Smana/cloud-native-ref/pull/1960#issuecomment-5550806743) | The bootstrap installs Flux **before** recycling bootstrap nodes, so workloads are scheduled onto ceiling-limited nodes that are being drained — the race the recycle exists to prevent |
| [2](https://github.com/Smana/cloud-native-ref/pull/1960#issuecomment-5550852542) | 60 inline `bash -c <<-BASH` blocks across 13 workflow files, none reachable by `shellcheck`, which already gates `scripts/**` |
| [3](https://github.com/Smana/cloud-native-ref/pull/1960#issuecomment-5550858250) | Deploy waits poll through terminal states and report blocker *names* without *messages*; plus no guard against deploying a ref other than the branch you are on |

Fixed on the branch during the run: `6bd8b556`, the recycle script's readiness
wait (`kubectl rollout status` does not wait for its object to appear, and
stderr was discarded).

---

## The platform, seen healthy

Before the teardown, with Flux on the branch:

| Check | Result |
|---|---|
| Flux Kustomizations | 22+ Ready; `observability -> tooling -> apps` cleared |
| `home.priv.aws.ogenki.io` | **HTTP 200**, `ssl_verify=0` |
| Certificate served | `CN=*.priv.aws.ogenki.io`, issuer `CN=Ogenki AWS Intermediate CA` |
| `headlamp` | 200 · `grafana` 302 (OIDC redirect) |

That fetch is the end-to-end PKI proof no `openssl verify` can give: a real HTTP
client retrieved a real page over TLS terminated by a leaf from the chain this
ceremony produced, verified against the CA chain built the same morning.

**An unrelated blocker had to be cleared first.** `victorialogs-datasource
0.32.0` arrived from main (#1959) and does not exist in the Grafana.com catalog
— only on GitHub, which is what the tracking comment watches. Grafana's plugin
installer is a startup module, so this was CrashLoopBackOff rather than a
missing datasource, and it stalled `observability` -> `tooling` -> `apps`. The
visible symptom was a 404 on the homepage.

Recovery needed three steps, because the *remediation* path was as broken as
the install: pin `0.31.0` (`0559ea75`); `helm uninstall --no-hooks`, because the
chart's cleanup-hook Job name is 65 bytes against the 63-byte label limit and
could not even be created; then strip `apps.victoriametrics.com/finalizer` from
four VM CRs whose operator had been deleted alongside them. Bug #1 alone would
have self-healed once the ConfigMap updated.

## Teardown

`TM_LINEAGE_DESTROY` deliberately unset. **The lineage survived**, which is the
half of success criterion 1 a destroy can prove on its own:

| Must persist | State after teardown |
|---|---|
| Seal key | `mrk-dbd7c4a3…`, `Enabled`, `MultiRegion=True` |
| `eu-west-1` replica | `Enabled` |
| Snapshot | `2026-09-05T092947Z-awskms.snap`, 74,785 bytes |
| Bootstrap secrets | root token, recovery keys, intermediate-ca, server cert, ca-chain |
| Old `root-ca` | **absent** — deleted earlier, after the new chain had issued |

Nothing billable remains: EKS 0, instances 0, NAT gateways 0, load balancers 0,
EIPs 0, non-default VPCs 0, orphaned EBS volumes 0.

### Deviation: the pre-destroy snapshot could not resolve a live node

The first teardown failed in `opentofu/aws/openbao/cluster`:

```
[ERROR] OpenBao at https://bao.priv.aws.ogenki.io:8200 is not active (HTTP 000);
        refusing to destroy without a snapshot.
```

The node was alive. In the same minute, `dig` returned nothing while
`curl --resolve …:10.0.15.250` returned **200**, with the instance running and
its NLB `active`. The Route53 record had gone before the snapshot step ran.

This stranded the walk after EKS was destroyed but before the NAT gateway, and
its suggested remedy (`TM_OPENBAO_SKIP_SNAPSHOT=true`) would discard an
obtainable snapshot. Safe here only because the manual CronJob snapshot already
sat in the bucket. Raised as PR follow-up
[#4](https://github.com/Smana/cloud-native-ref/pull/1960#issuecomment-5551254482):
the fix is the fixed NLB address this PR itself introduced.

The teardown was later killed by the OS under memory pressure, leaving a state
lock and two orphaned `terraform-provider-*` processes; recovered with
`tofu force-unlock` after killing the orphans, then completed stack-by-stack.

---

## The restore, proven against the surviving lineage

The drill workflow **cannot be dispatched before merge**: `workflow_dispatch` is
only exposed for workflows present on the default branch, and this one exists
only on the branch (`gh workflow run` → HTTP 404, `gh workflow list` does not
show it). Two exit criteria — success criterion 7 and design risk 3's
`web-identity-seal` job — are therefore unreachable until the PR that
introduces them has merged. Worth stating plainly rather than leaving as an
unticked box.

Its *substance* does not need the workflow. With the platform destroyed, the
`drill` job's steps were reproduced locally against the surviving lineage —
same `bao` version, same asset and checksum flow, same seal, same assertions:

```
[1/6] openbao_2.6.2_linux_amd64.tar.gz: OK   (checksums.txt verified)
      OpenBao v2.6.2
[2/6] newest object: 2026-09-05T092947Z-awskms.snap   seal segment: awskms
[3/6] throwaway node up, uninitialised (501)
[4/6] {"type":"awskms","initialized":false,"recovery_seal":true}
[5/6] unsealed and active after restore, with no operator input
[6/6] subject=CN=Ogenki AWS Intermediate CA  issuer=CN=Ogenki Root CA
      openssl verify -CAfile .github/openbao-root-ca.pem -> c1.pem: OK

before (live cluster, pre-teardown): 8A:C4:25:40:F3:40:CA:44:...:A2:57
after  (restored from snapshot)    : 8A:C4:25:40:F3:40:CA:44:...:A2:57
SAME ISSUER

{"type":"awskms","initialized":true,"sealed":false,"storage_type":"raft"}
```

Read-only against AWS (`s3:GetObject`, `kms:Decrypt`); the node was a temp
directory removed on exit.

**What this settles.** The snapshot survives a full teardown and is restorable;
the seal key unwraps it; the node unseals with no operator input; and
`pki_private_issuer` returns byte-identical and still chains to the committed
offline root. That is the mechanism the whole design rests on.

**What it does not settle, precisely.** Criterion 1 is *destroy + redeploy
returns the same fingerprint **with no seeding step***. This used the drill's
method — a manual `operator init` followed by `raft snapshot restore`. It did
**not** exercise `openbao-config.sh rehydrate`: snapshot *selection*, the seal
gate, the freshness marker, or `No changes.` from the management apply (design
risk 4). Those need one deploy.

Incidental: the drill's own download step (`openbao_${BAO_VERSION}_linux_amd64.tar.gz`
plus `checksums.txt`) is correct — a first local attempt used the wrong asset
names and the workflow's were right. `Error properly closing policy file: ...
file already closed` appears during restore and is benign; the restore
succeeded.

## Repository validators, re-run after every change on the branch

| Validator | Result |
|---|---|
| `./scripts/validate-manifests.sh` | exit 0 — `2110 resources found in 279 files - Valid: 2110, Invalid: 0, Skipped: 0`, both gates passed |
| PromQL (step 2/5) | 47 expressions in 11 groups parse; 1 group skipped **and named** (`loggen`, `type: vlogs`) |
| `check-substitution.py` | 68 Kustomizations, wiring consistent |
| `validate-links.sh` | exit 0 |
| `validate-doc-claims.sh` | exit 0 |
| `verify-doc-paths.sh` | exit 0 |
| `shellcheck -x -S warning` | exit 0 on every touched script |

---

## Success criterion 1, through `rehydrate` itself

The earlier proof used the drill's method — a manual `operator init` plus
`raft snapshot restore`. This one is the real path: the OpenBao cluster stack
destroyed, a fresh uninitialised node, and the management stack's own
`rehydrate` selecting and restoring:

```
This node's seal is 'awskms'; 2026-09-05T135753Z-awskms.snap carries 'awskms'.
Snapshot 2026-09-05T135753Z-awskms.snap found ... Initialising with throwaway
  shares, then restoring.
The restored snapshot was taken 0 day(s) ago.
PKI issuer present: subject=CN=Ogenki AWS Intermediate CA, O=Ogenki, C=FR

issuer fingerprint after : 8A:C4:25:40:F3:40:CA:44:...:6B:D1:A2:57
ISSUER_BEFORE            : 8A:C4:25:40:F3:40:CA:44:...:6B:D1:A2:57
```

Identical, and against a **different** snapshot than the local drill used, so the
result is not an artefact of replaying one object.

`/opentofu/aws/openbao/management` then reported **`No changes. Your
infrastructure matches the configuration.`** and `Apply complete! Resources: 0
added, 0 changed, 0 destroyed.` — design risk 4 settled: a rehydrated OpenBao is
indistinguishable from a freshly configured one, with no targeted import or
`state rm` needed.

Along the way this exercised, for the first time, the seal gate against a real
object, snapshot selection (it chose the newer of two), and the freshness marker.

### Three defects found by taking that path

| Fix | What it was |
|---|---|
| `3bd8dbd3` | `bao operator generate-root` is **unsupported on an auto-unsealed node** (405), and its counterpart `sys/generate-recovery-token` needs a token — the thing being obtained. The post-restore mint could never have worked here, on any node. Uses the lineage's stored root token instead, valid again by construction once the snapshot's token store is in place |
| `217e3108` / `94ed3d60` | A rehydrated node restores `jwt/<cluster>` **holding the OIDC issuer of the destroyed cluster**. `eks/configure`'s state is destroyed on every teardown, so OpenTofu tried to create what the snapshot restored, and failed 400. That 400 is protective: without it the deploy reports success and leaves an auth method that rejects every token |
| `6587a485` | Nothing refreshed the kubeconfig, so the recycle script asked the *previous* cluster about a DaemonSet — and reported it "never created" while it was healthy and 27 minutes old. Also a repeat of this file's own stderr-discarding defect, in the wait added earlier the same day |

## The platform, fully converged

| Check | Result |
|---|---|
| Flux Kustomizations | **28 Ready**; only `llm-platform` outstanding, the suspended umbrella |
| `jwt/aws-0` issuer | refreshed to the new cluster (`A0F8FD41…`, was `B5AC3FF6…`) |
| `ClusterIssuer openbao` | `Ready=True` — cert-manager authenticates through the refreshed mount |
| Flux sync ref | `refs/heads/worktree-openbao-lineage` |
| Snapshot image | `ghcr.io/smana/openbao-snapshot:v0.3.1`, job Complete in 40s |
| Snapshots in the lineage | three, each carrying its seal in the name |

## GCP, unblocked

| Item | Result |
|---|---|
| GCP lineage stack | `8 added, 0 changed, 0 destroyed`; bucket versioned, drill variables set |
| Task 14b | `openbao-priv-gcp-server-cert` v2 — four SANs, verifying against the chain and the committed offline root |
| Federation | `openbao-snapshot-mirror` and `openbao-standby-seal` roles created |
| **Mirror — criterion 5** | `2026-09-05T092947Z-awskms.snap`, **74785 bytes on both sides** |

Two defects there too: `32b253ff` (the Storage Transfer API was never enabled —
the failure surfaced as an AWS `AccessDenied`, naming the wrong cloud) and
`ff675908` (the pre-destroy snapshot resolves OpenBao by a DNS name the teardown
itself removes, while the node still answers on its fixed NLB address).

## Criterion 6, proven — and two defects that made it impossible

The headline cross-cloud claim, run for real. It did **not** need the GCP
platform: the claim is about an identity and a seal, not about a cluster, so a
throwaway `e2-medium` in the `default` network running as the real
`openbao-node` service account is a complete test — and a cheap one. This also
retires the earlier note in this file that design risk 3 "cannot be reproduced
locally"; it can, and doing so is what found the defects.

The drill asserts it holds no AWS credential, fetches a GCE identity token to a
**file**, and points `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` at OpenBao's
own `seal "awskms"` — so the AWS SDK's web-identity provider does the exchange,
exactly as the standby unit does. No manual `sts:AssumeRoleWithWebIdentity`
call stands in for the mechanism.

```
STANDBY no-static-credential OK
STANDBY identity-token-file bytes=656
STANDBY gcs-newest 2026-09-05T092947Z-awskms.snap
STANDBY seal-segment awskms OK
STANDBY snapshot-bytes 74785
STANDBY seal-status {"type":"awskms","initialized":false}
STANDBY init OK (awskms unwrapped a fresh barrier key over web identity)
STANDBY unsealed-after-restore OK no-operator-input
STANDBY issuer subject=CN = Ogenki AWS Intermediate CA  issuer=CN = Ogenki Root CA
STANDBY fingerprint 8A:C4:25:40:...:A2:57
```

That fingerprint is the AWS cluster's live issuer, byte for byte. A GCP node
holding no AWS credential read the GCS mirror, unsealed with the AWS
multi-region key, and served the same PKI.

**Getting there required fixing two defects, both on the path nothing had ever
executed.** Neither is visible from configuration review — each one fails only
when a real GCP identity tries the real thing.

| Defect | Symptom | Fix |
|---|---|---|
| `client_id_list` omitted the standby SA's unique ID | `InvalidIdentityToken` — every trust-policy condition matched and STS still refused | `opentofu/shared/aws-gcp-federation/google-identity.tf` |
| The snapshot bucket granted read to the CI drill SA but never to the node SA | standby could unseal a snapshot it had no permission to fetch | `opentofu/gcp/openbao/lineage/main.tf` |

The first is the interesting one. `client_id_list` reads like "the audiences we
accept", and the token's `aud` *was* `sts.amazonaws.com` — already in the list.
AWS also matches the **authorized party**, and for a GCE instance identity token
`azp` is the service account's unique ID:

```
{"aud":"sts.amazonaws.com","azp":"110583515827251510802",
 "iss":"https://accounts.google.com","sub":"110583515827251510802"}
```

The thumbprint was ruled out first — substituting each certificate of
`accounts.google.com`'s live chain changed nothing. Adding the unique ID, and
nothing else, produced
`arn:aws:sts::396740644681:assumed-role/openbao-standby-seal/webid-drill`.

Both fixes were then applied **from code**, and the final run above is against
that reconciled state: `client_id_list` shows no diff, and the exploratory
thumbprints were reverted to the single code-managed value by the apply, so the
committed configuration is what is proven. Live provider state afterwards:

```
clients:     sts.amazonaws.com, 103642011123339318159, 110583515827251510802
thumbprints: 08745487e891c19e3078c1f2a07e452950ef36f6
```

`gcloud compute instances list` → `Listed 0 items.` after the run.

## Still outstanding

- [x] Delete `certificates/priv.aws.ogenki.io/root-ca` and the two AppRole entries
- [x] **Redeploy and compare the issuer fingerprint (success criterion 1)** — done,
      through `rehydrate` itself. See above.
- [x] **GCP standby restores the AWS lineage (criterion 6)** — proven end to end,
      after fixing the two defects above.
- [x] **Design risk 3, the web-identity seal** — proven on a real GCE identity.
- [ ] Drill workflow, one green run — **blocked until merge**: `workflow_dispatch`
      needs the workflow on the default branch. Its substance is proven above; the
      workflow wrapper itself is not.
- [x] GCP server-certificate re-issue (Task 14b), lineage stack, federation, mirror
- [x] **Costs page re-measured** — the KMS row was the one projection in a table
      labelled *measured*, carrying four keys on the strength of the seal replica
      being committed rather than existing. It exists: `alias/openbao-seal`
      resolves `PRIMARY` in `eu-west-3` and `REPLICA` in `eu-west-1`. ADR-0033's
      `$23 → $24` is unchanged and correct — three keys were already billing at
      idle, and the lineage adds exactly one.
- [ ] **The OpenBao OIDC browser login (ADR-0034).** The offline suites pass, the
      terraform validates, and the two latent bugs found while writing it are
      fixed — but no human has completed the flow against a live ZITADEL. This is
      the one claim in the PR with no live evidence behind it.

## What a teardown proved on the way out

The final `--reverse destroy` is itself evidence, and it produced one defect and
one confirmation.

**The defect:** `--fallback-address` never reached the client taking the
snapshot. The parent's curl probe went green through the fallback —
`Reached OpenBao at 10.0.15.250 presenting bao.priv.aws.ogenki.io` — and the
child then died on the name the probe had just worked around, because
`bao operator raft snapshot save` is a Go client that never reads a `.curlrc`.
The node was reachable throughout, so this is exactly the loss the function
exists to prevent. Fixed in `cedcbda8`, with a regression test.

**The confirmation:** the lineage survived, which is the whole claim. After the
teardown, with 0 instances, 0 NAT gateways, 0 EKS clusters, 0 load balancers, 0
non-default VPCs and 0 EBS volumes:

```
seal key eu-west-3:  Enabled  PRIMARY
seal key eu-west-1:  Enabled  REPLICA
snapshots in S3:     3
```

plus the six bootstrap secrets. Both guards held: `TM_LINEAGE_DESTROY` and
`prevent_destroy` on the seal key.
