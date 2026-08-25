# OpenBao on GCP — first live deploy, verification and findings

**Date:** 2026-08-25
**Design:** [`2026-08-24-gcp-openbao-design.md`](./2026-08-24-gcp-openbao-design.md)
**Plan:** [`../plans/2026-08-24-gcp-openbao.md`](../plans/2026-08-24-gcp-openbao.md)
**Outcome:** PKI chain proven end to end. Nine findings, five fixed on the branch,
four recorded here. Torn down to zero billable resources.

## Why this document exists

Four of the plan's eight tasks passed every static gate — `tofu validate`,
`trivy`, `tflint`, `shellcheck` — plus a per-task review each and a whole-branch
review that found a Critical security hole. Then the first live deploy found
**nine more things**, six of which no static analysis could reach.

That ratio is the point. The gates and reviews were not wasted — the
whole-branch review caught a project-wide IAM grant that fails *open* and would
never have surfaced in a deploy at all. But a design sentence like *"the instance
service account needs `cloudkms.cryptoKeyEncrypterDecrypter` and nothing else"*
can be read by three reviewers, restated in a plan, implemented faithfully, and
still be false.

## What was proven

| Design criterion | Result |
|---|---|
| 2 — unsealed **without operator input** after init | **PASS** — `Sealed: false`, `Recovery Seal Type: gcpckms` |
| 3 — chain verifies to the **offline root**; leaf SAN has DNS and no IP | **PASS** — `Verify return code: 0 (ok)` |
| 8 — teardown removes every billable resource | **PASS** — 25 destroyed, 0 instances/networks/rules remain |

Plus three things the design assumed but had never exercised:

- **`config_ca` alone leaves the mount able to issue.** The design deletes four
  resources (`key` → `intermediate_cert_request` → `root_sign_intermediate` →
  `set_signed`) on this assumption and flagged it as the single untested premise
  the chain rests on. Probed directly: importing the openssl-made intermediate
  produced both an issuer and a key, a role issued a leaf, and that leaf verified
  to the offline root. **The premise holds.**
- **`openbao-config.sh --cloud gcp` works end to end** — waited for readiness,
  initialised, created both Secret Manager secrets, and reported the server
  initialised, unsealed and active.
- **The pinned OpenBao GPG fingerprint verifies on a real boot**
  (`66D1 5FDD 8728 7219 C8E1 5478 D200 CD70 2853 E6D0`), and the Secret Manager
  fetch works under a binding scoped to one secret.

## Findings

### 1. The `gcpckms` seal needs `cloudkms.cryptoKeys.get` — FIXED (`77d7fcef`)

The design said `roles/cloudkms.cryptoKeyEncrypterDecrypter` **"and nothing
else"**. That is false. OpenBao's `gcpckms` seal verifies the key *exists* before
using it, and encrypterDecrypter grants encrypt/decrypt without `cryptoKeys.get`:

```
Error configuring seal "gcpckms": error checking key existence:
PermissionDenied: Permission 'cloudkms.cryptoKeys.get' denied on resource
.../cryptoKeys/openbao-unseal (or it may not exist).
```

Fixed by binding `roles/cloudkms.viewer` at the crypto-key level — the
least-privileged predefined role carrying that permission, scoped so it sees one
key.

**The failure mode is the quiet one.** The seal is configured *after* the process
starts, so the instance reaches `RUNNING`, joins the MIG and reports healthy
while `openbao.service` crashloops. With no health check at the time, nothing
surfaced it but the serial console.

### 2. Cloud KMS API is not enabled on a fresh project — FIXED (`e1df0880`)

`gcloud kms keyrings create` fails with `PERMISSION_DENIED`, which reads as an
IAM problem. gcloud offers to enable the API interactively, but the prompt
**defaults to no**, so a non-interactive run just fails. Neither the design nor
the plan mentioned it; now in `kms.tf`'s bootstrap comment.

### 3. Enabling that API and applying immediately still fails — RECORDED

Separate from finding 2 and more confusing. After `gcloud services enable`
returned success, `keyrings create` worked — so the API looked live — but the
first `tofu apply` still failed:

```
Error 403: Google Cloud KMS API has not been used in project ... or it is disabled.
```

Propagation took several minutes. Anyone hitting only this would reasonably
conclude their `services enable` had not worked and re-run it. **Wait, then
apply.**

### 4. systemd gives up permanently after three rapid failures — OPEN

```
openbao.service: Start request repeated too quickly.
```

Once the start limit trips, the service never retries — even after the
underlying cause is fixed. Combined with the MIG having **no
`auto_healing_policies`** (deferred to Task 6 and still not added), a transient
IAM or network problem at boot leaves a permanently dead service on a `RUNNING`
instance that nothing recycles.

**Follow-up:** add `auto_healing_policies` to the MIG using the health check
Task 6 introduced.

### 5. `recreate-instances` returned SUCCESS without recreating anything — RECORDED

```
gcloud compute instance-groups managed recreate-instances ... → STATUS: SUCCESS
```

The MIG then reported `isStable: true` and `versionTarget.isReached: true`, and
the instance kept its original creation timestamp. Nothing was recreated.
Deleting the instance directly was what actually forced a rebuild. Treat that
command's SUCCESS as "request accepted", not "instance replaced" — verify by
creation timestamp.

### 6. An INTERNAL backend service requires `CONNECTION` balancing mode — FIXED (`2ec60d19`)

The provider defaults a backend to `UTILIZATION`, which GCP rejects:

```
Error 400: Invalid value for field 'resource.backends[0].balancingMode':
'UTILIZATION'. Balancing mode must be CONNECTION for an INTERNAL backend service.
```

Passthrough load balancers distribute connections, not requests, so there is no
utilization signal. Not guessable from the field name; the error is recorded
verbatim in `load_balancer.tf`.

### 7. The network stack's split-DNS is EMPTY on first apply — FIXED (`f9222ed8`)

`opentofu/gcp/network/tailscale.tf` creates
`tailscale_dns_split_nameservers.gcp_private` from
`data.google_compute_addresses.dns_inbound`, filtered on `purpose = "DNS_RESOLVER"`
with a `depends_on` on the inbound DNS policy. But `depends_on` on a data source
does not guarantee the policy has finished *allocating its address*. After a
first apply:

```
resource "tailscale_dns_split_nameservers" "gcp_private" {
    domain      = "priv.gcp.ogenki.io"
    nameservers = []          # EMPTY
}
```

The deploy reports success and **no tailnet client can resolve anything under
`priv.gcp.ogenki.io`**. A second apply populates it (`["10.10.0.2"]`) because the
address now exists.

This is a pre-existing bug in the network stack, not introduced by the OpenBao
work — but it blocks reaching OpenBao, so it belongs to this workstream now.
Verified the VPC side was never at fault: querying the resolver directly
(`dig @10.10.0.2 bao.priv.gcp.ogenki.io`) returned the right address throughout.

**Fixed** with two changes, the second mattering more than the first: a 60s
`time_sleep` between the policy and the data read (the same `hashicorp/time`
provider the AWS llm-platform stack already uses for EFS mount-target
propagation), and a `precondition` asserting the address list is non-empty. A
fixed wait alone would still degrade to the original bug on a slow allocation —
a successful apply configuring no resolver. The precondition turns that silent
failure into a loud one naming the consequence, recoverable by re-running.

Not verified against a live first apply: proving it needs another full network
build and teardown. The precondition means the untested path now fails loudly
rather than silently, which is the property that was missing.

### 8. The root-token secret's shape is `{"token": …}` — RECORDED

Not `{"root_token": …}`. A probe using the wrong key and a `// .` fallback
silently produced the entire JSON blob as the token, which surfaced as
`configured Vault token contains non-printable characters` — an error that says
nothing about the actual mistake. Anything reading that secret should use
`jq -r '.token'`.

### 9. A stale Tailscale search domain — PRE-EXISTING, not blocking

`tailscale dns status` lists `priv.gcp.cloud.ogenki.io`, the domain from before
[ADR-0017](../../../website/content/docs/decisions/0017-multi-cloud-dns-naming.md)
renamed it. The split *route* is keyed correctly to `priv.gcp.ogenki.io`, so this
is cosmetic today — but it lives in the tailnet-wide config owned by
`shared/tailscale`, which the rename never reached.

## Still unverified

- **Criterion 6** — a cert-manager `Certificate` reaching `Ready=True` in GKE.
  Needs Tasks 7 and 8 and a running cluster; not attempted.
- **Criterion 7** — a second `terramate script run deploy` producing a 0-change
  plan. Not tested; the deploy was amended several times mid-flight.
- **Criterion 5** in its real form — the probe used a throwaway `pki_test` mount,
  not the `pki_private_issuer` mount the management stack will create.
- The **management stack (Task 7) does not exist yet**, nor the GKE wiring
  (Task 8).

## Housekeeping

**The root CA private key is at `~/gcp-openbao-pki-ceremony/root-ca-key.pem`.**
The operator has confirmed a safe copy exists elsewhere. The local copy is the
last step of the ceremony and is deliberately left for a human to remove:

```bash
shred -u ~/gcp-openbao-pki-ceremony/{root-ca-key,intermediate-ca-key,server-key}.pem
```

Do not delete it without confirming the offline copy — it is the only thing that
can sign AWS's intermediate when that migration happens.

**Two Secret Manager entries are now stale**:
`openbao-priv-gcp-root-token` and `openbao-priv-gcp-recovery-keys` belong to a
destroyed server. They are inert, and `init` overwrites them on the next
rebuild — but anything reading them in between gets credentials for nothing. The
three PKI secrets (`intermediate-ca`, `server-cert`, `ca-chain`) are genuinely
reusable and should stay.

**The KMS key ring and key survive by design.** GCP cannot delete a key ring, and
a crypto key's deletion only schedules its versions for destruction — which is
exactly why they are a bootstrap prerequisite rather than stack-managed. They
cost nothing idle. Do not treat them as a teardown leak.
