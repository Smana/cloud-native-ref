# OpenBao on GCP — private PKI for the GKE cluster

**Status:** design approved 2026-08-24, not yet implemented
**Workstream:** 11 of the [GCP support design](./2026-08-18-gcp-support-design.md)
**Depends on:** workstream 1 (GCP network) — deployed. Also needs one addition to
workstream 5's IAM allowlist; see *A dependency on slice 5* below.

## Why

GCP has no private certificate authority. The GKE cluster can issue nothing for
`*.priv.gcp.ogenki.io`, which blocks every private-TLS consumer the AWS platform
takes for granted. AWS solves this with OpenBao at `bao.priv.aws.ogenki.io`; GCP
needs its own, because [`opentofu/aws/openbao/`](../../../opentofu/aws/openbao/)
is AWS-shaped throughout — ASG, ELB, KMS, Route53, and Secrets Manager for every
credential.

## Scope

**PKI only.** A root of trust, an issuing CA, a cert-manager role and one
AppRole. Deliberately NOT ported: the `app` tenant namespace, its kv-v2 mount,
the snapshot AppRole, and operator userpass login. None has a consumer on GCP,
and the GCP tree has been built minimal-until-needed throughout.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Scope | PKI only | No GCP consumer for the rest yet |
| Topology | Single node, `file` backend | Mirrors what AWS actually runs (`mode = "dev"` is committed); cheapest for a build-validate-destroy platform |
| Root CA custody | **Offline**. Signs GCP's intermediate now; becomes the shared anchor when AWS migrates | See *The PKI reconsideration* |
| cert-manager auth | AppRole via GCP Secret Manager + External Secrets | Parity with AWS; the existing `security/base/cert-manager` manifests work with only the SecretStore backend changed |
| Stack split | Two stacks, `cluster/` + `management/` | The `vault` provider needs a reachable, initialised server at plan time — the same constraint that splits `gke/init` from `gke/configure` |

## The PKI reconsideration

**This supersedes the two-root decision recorded in the GCP support design's
*Private certificates on GCP* section.** That section is amended to point here.

### What was wrong

The AWS design imports a pem_bundle containing the **root key** into the live
`pki_private_issuer` mount, then has OpenBao generate its own intermediate and
sign it internally. [`pki-and-secrets.md`](../../../website/content/docs/platform/security/pki-and-secrets.md)
documents this and warns against it verbatim: *"do not carry it into a deployment
where the root CA matters."* The first draft of this design carried it into GCP
anyway.

It inverts the property an offline root exists to provide. A root signs
intermediates a handful of times in its life; keeping it off any
network-reachable system means compromising the issuing CA does not compromise
the trust anchor. As written, compromising OpenBao yields the root.

The earlier two-root decision was also rejected-for-the-wrong-reason. It ruled
out a shared root because cross-signing would be *"a manual ceremony on every
rebuild"*. That premise is false: the intermediate lives in Secret Manager
independently of OpenBao's lifecycle, which is precisely why AWS's survives
rebuilds today. Signing happens **once per cloud, ever**. The better option was
rejected over a cost it does not have.

### The chain

```
Offline Root CA (EC secp384r1) — never on a networked system
  ├── GCP intermediate (EC secp384r1) → imported as pki_private_issuer → leaves
  └── AWS intermediate                → later; see Migration below
```

The root signs the GCP intermediate's CSR **once, offline**, then returns to
offline storage. Only the intermediate's certificate and key reach GCP Secret
Manager. `vault_pki_secret_backend_config_ca` imports that bundle and it *is*
the issuer.

This also removes work. The AWS sequence —
`vault_pki_secret_backend_key` → `intermediate_cert_request` →
`root_sign_intermediate` → `intermediate_set_signed` — exists only to generate
an OpenBao-internal intermediate under an imported root. Importing the
openssl-made intermediate directly deletes all four resources.

**The root key is never in Secret Manager, never in the mount, never in
OpenTofu state.**

### Migration, and the interim cost

GCP adopts this first; AWS follows later. Until it does, tailnet clients trust
**two** anchors — AWS's existing live-key root and the new offline root. That is
the same cost as the two-root design being abandoned, but temporary with a
defined end rather than permanent by construction.

Migrating AWS means a new intermediate signed by the offline root and a
coordinated re-trust. Out of scope here.

## Architecture

Two stacks under `opentofu/gcp/openbao/`.

| AWS | GCP |
|---|---|
| Auto Scaling Group + launch template | Zonal MIG + instance template (`europe-west4-a`) |
| Internal NLB, TCP 8200 | Internal passthrough Network LB — forwarding rule, backend service, health check |
| `aws_kms_key` | `google_kms_key_ring` + `google_kms_crypto_key` |
| Route53 private A record | `google_dns_record_set` in the existing `priv-gcp-ogenki-io` zone |
| Security group | `google_compute_firewall` |
| Instance profile + role policies | `google_service_account` + scoped Secret Manager / KMS bindings |
| Secrets Manager | GCP Secret Manager |
| cloud-init `user_data` | metadata `startup-script` |

**Zonal is a real availability property, not an oversight.** The node dies with
the zone. That is consistent with the GKE cluster, which is also zonal, and with
a platform that is rebuilt rather than repaired.

### Deliberately not ported

- **Hardened-image plumbing.** AWS carries `ami_owner` / `ami_filter` variables
  that are commented out and unused. Copying them would be copying scaffolding.
- **The `mode` variable.** AWS defines `dev`/`ha` and commits `dev`. A variable
  with one reachable value is worse than a constant, and the HA path would ship
  untested. Single node, stated plainly.
- **An always-on admin path.** AWS keeps SSM enabled because it is how you reach
  a node whose boot script failed. GCP's counterpart is IAP TCP forwarding. The
  firewall rule is written but disabled by default: the tailnet already reaches
  the subnet, and an always-on admin path is a standing exposure.

## Boot sequence

Per instance, via metadata `startup-script`:

1. Format and mount the data disk.
2. Install a pinned OpenBao version.
3. Fetch the server leaf certificate and key from Secret Manager using the
   instance service account.
4. Write config: TLS listener on 8200, `file` storage, and a `gcpckms` seal
   stanza. The instance service account needs
   `cloudkms.cryptoKeyEncrypterDecrypter` on that key and nothing else.
5. Start the service.

Initialisation stays a separate, deliberate step —
`scripts/openbao-config.sh init` — as on AWS. An auto-init path was considered
and rejected: a documented procedure already exists, and a second one is how the
two clouds drift.

### Certificate details to carry forward

From `pki-and-secrets.md`, all three still apply:

- OpenBao's own leaf is **EC P-256** against the P-384 CAs.
- `openssl` writes key files world-readable — `chmod 600`. This key terminates
  TLS for every client.
- The SAN list carries the **DNS name only, no IP**. On AWS that is why a client
  reaching a Raft peer by private IP cannot verify TLS. Single-node here makes it
  moot today; the constraint stays so it does not surprise a future HA change.

## Management stack

Mirrors AWS's `pki.tf` with the data source swapped and the internal-intermediate
sequence removed:

- `vault_mount` — the `pki_private_issuer` mount
- `vault_pki_secret_backend_config_ca` — imports the intermediate bundle from
  GCP Secret Manager
- `vault_pki_secret_backend_issuer` — to name the issuer `config_ca` creates and
  set its usage. Whether this resource is needed at all depends on the same
  assumption flagged in *Risks*: confirm what `config_ca` leaves behind before
  writing it, rather than porting it from AWS on faith
- a cert-manager role scoped to `priv.gcp.ogenki.io`
- one AppRole, whose `role-id` / `secret-id` are written to Secret Manager

## `openbao-config.sh` gains `--cloud gcp`

The script is AWS-only today. Its coupling is contained to three seams, which is
what makes a flag the right shape rather than a sibling script:

| Seam | AWS | GCP |
|---|---|---|
| write | `secretsmanager create-secret` / `update-secret` | `gcloud secrets create` / `versions add` |
| read | `secretsmanager get-secret-value` | `gcloud secrets versions access latest` |
| CLI prefix | `get_aws_cmd()` | project-scoped `gcloud` |

`--region` / `--profile` stay AWS-only and `--project` is GCP-only; passing one
to the wrong cloud must fail at argument parsing, not at the API call.

### Secret naming — a constraint that forces a rename

AWS secret names are paths: `certificates/priv.aws.ogenki.io/root-ca`.
**GCP Secret Manager secret IDs permit only letters, digits, `-` and `_`** — no
slashes, no dots. Every name has to be rewritten; the two clouds cannot share one
convention. Following the `flux-github-app` precedent already in the GCP tree:

| Secret | Contents |
|---|---|
| `openbao-priv-gcp-intermediate-ca` | intermediate certificate **+ key** |
| `openbao-priv-gcp-server-cert` | OpenBao's leaf, EC P-256 |
| `openbao-priv-gcp-ca-chain` | root + intermediate **certificates only** — public, what clients trust |
| `openbao-priv-gcp-root-token` | written by `openbao-config.sh init` |
| `openbao-priv-gcp-recovery-keys` | written by `openbao-config.sh init` |

The domain's dots are dropped rather than encoded: `priv-gcp-ogenki-io` adds
length without disambiguating anything in a single-domain project.

**No root-CA secret exists on GCP.** Its absence is the design.

## How GKE consumes it

External Secrets pulls the AppRole credentials and the CA chain from GCP Secret
Manager. cert-manager's `ClusterIssuer` points at `bao.priv.gcp.ogenki.io:8200`.
A `Certificate` resource proves the chain end to end.

### A dependency on slice 5

External Secrets needs to read GCP Secret Manager, which means a Google identity
— a `GCPWorkloadIdentity` claim. But the IAM condition in
[`opentofu/gcp/gke/init/iam.tf`](../../../opentofu/gcp/gke/init/iam.tf)
allowlists **only** `xplane_dns_editor`. A claim requesting Secret Manager access
is refused at the provider.

So this workstream requires a second pre-created custom role — `xplane_secret_reader`,
holding `secretmanager.versions.access` — added to `crossplane_grantable_roles`.

That is the mechanism working as intended, not an obstacle: adding a capability
is a deliberate act in OpenTofu, and a claim cannot grant itself one.

## Success criteria

Falsifiable, verified against a live cluster.

1. `bao status` against `https://bao.priv.gcp.ogenki.io:8200` reports
   `Initialized: true`, `Sealed: false`, from a tailnet device.
2. The node is unsealed **without operator input** after a stop/start — proving
   the `gcpckms` seal, not a manual unseal.
3. `openssl s_client` against the endpoint presents a chain that verifies to the
   **offline root**, and the served leaf's SAN contains the DNS name and no IP.
4. `gcloud secrets list` shows **no secret containing the root CA private key**.
5. The `pki_private_issuer` mount's issuer is the openssl-made intermediate:
   `bao read pki_private_issuer/issuer/default` returns a certificate whose
   subject matches it, and no OpenBao-generated intermediate exists.
6. A cert-manager `Certificate` in the GKE cluster reaches `Ready=True`, issued
   by the ClusterIssuer, with a chain terminating at the offline root.
7. `terramate script run deploy` for both stacks produces a 0-change plan on a
   second run.
8. Teardown removes every billable resource; `gcloud compute instances list` and
   `gcloud container clusters list` are empty afterwards.

## Risks and open questions

- **Offline root custody is a procedure, not a resource.** The design says the
  root never touches a networked system, but where it *does* live — encrypted
  media, a password manager — is an operator decision this document does not
  make. It must be written down somewhere before the first signing ceremony,
  or the property is aspirational.
- **The interim two-anchor state has no deadline.** AWS migrates "later". If
  that slips indefinitely the platform keeps two trust anchors, which is the
  outcome this design set out to avoid.
- **`file` storage on a single node has no backup story here.** The snapshot
  AppRole was scoped out because GCP has no consumer, but that also means
  nothing is backing up the PKI. Acceptable while the platform is rebuilt from
  scratch; not acceptable the moment anything long-lived depends on it.
- **Untested at design time:** that `config_ca` alone, without the
  CSR/sign/set-signed sequence, leaves the mount able to issue. This is the
  standard import-an-existing-CA flow, but it has not been exercised in this
  repository, and it is the single assumption the chain rests on. Verify it
  early in implementation rather than at the end.
