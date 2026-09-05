---
title: PKI & Secrets
weight: 20
description: The three-tier PKI chain OpenBao issues from, how cert-manager and External Secrets pull from it, and how the chain rotates. One offline root for both clouds is the target; on AWS the ceremony has not run yet.
lastVerified: 2026-09-02
---

Every internal TLS certificate on this platform — Gateway API listeners,
service-to-service TLS — traces back to one private PKI hosted in
[OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}). Nothing here
is a public CA: `bao.priv.aws.ogenki.io` and everything it signs is only
meaningful inside the tailnet.

## The three-tier chain

```
Root CA  →  Intermediate CA  →  Issuer CA (OpenBao pki_private_issuer)  →  Leaf certificates
```

A Root CA at the top, an Intermediate CA in the middle, end-entity leaf
certificates at the bottom. The Root CA issues only to the Intermediate; the
Intermediate is what OpenBao's `pki_private_issuer` mount imports as its
signing certificate and uses to issue every leaf, which keeps
revocation/rotation scoped to the tier that actually changed.

{{< callout type="warning" >}}
**The AWS root CA private key has not been taken offline yet.** It is present in
the AWS `pki_private_issuer` mount as this platform last deployed it — imported
there inside a bundle from `certificates/priv.aws.ogenki.io/root-ca`, a secret
that still exists. This is an accepted trade-off **for this reference
platform**; do not carry it into a deployment where the root CA matters.

**On GCP it already is offline.** The 2026-08-25 ceremony signed
`openbao-priv-gcp-intermediate-ca` under a root whose private key never entered
GCP (`docs/gcp-bootstrap.md`, *What is NOT a prerequisite*).

`opentofu/aws/openbao/management/pki.tf` is already written for the offline
shape — it imports an intermediate bundle as the mount's issuer and generates
nothing inside OpenBao — but the secret it reads does not exist yet. Two
hand-performed steps close the gap, both documented below, and **neither has run
on AWS**:

| Step | What it does | Where |
|---|---|---|
| The signing ceremony | Signs an AWS intermediate under the offline root, issues a new server certificate, and stores both — then commits the root *certificate* as `openbao-root-ca.pem` in `.github/`, which does not exist until this runs | [Building the chain](#building-the-chain), [Storing the chain](#storing-the-chain), [Committing the root certificate](#committing-the-root-certificate) |
| Retiring the old root | Deletes `certificates/priv.aws.ogenki.io/root-ca`, and only after the new chain has issued a certificate | [Rotation](#rotation) |

Until both are done, read every "one offline root for both clouds" statement
below as what the ceremony produces, not as the current state. The AWS root and
the GCP root are also not yet the same root — signing the AWS intermediate with
the key the GCP ceremony produced is the step that makes them one.

If you are standing this platform up yourself, none of this is a caveat: you
perform the ceremony once, before the first deploy, and start from the offline
shape.
{{< /callout >}}

### Building the chain

The root CA is generated once, on an offline medium, with `openssl` — EC keys
(`secp384r1` for the CAs, `prime256v1` for OpenBao's own leaf) rather than RSA.

{{< callout type="warning" >}}
**Run this block only when creating a brand-new lineage.** The root already
exists — the 2026-08-25 ceremony produced `CN=Ogenki Root CA`, valid to
**2036-08-24**, and GCP's intermediate is already signed by it. Adding a cloud,
re-issuing an intermediate or re-issuing a leaf all reuse that root; none of
them generate one.

Re-running it is quiet rather than loud, which is what makes it worth a
warning: it overwrites `root-ca.pem` and `root-ca-key.pem` in the working
directory, and every step afterwards still *succeeds* — the intermediate signs,
`openssl verify` passes, the leaf gets its four SANs. You would simply have
built that chain under a root nothing else trusts, leaving two roots again,
which is the condition [ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}})
exists to remove. It surfaces days later, when the weekly restore drill's
`openssl verify -CAfile .github/openbao-root-ca.pem` fails.

To build under the existing root, copy `root-ca.pem` and `root-ca-key.pem` from
the offline medium into a scratch directory and start at the **intermediate**
block below.
{{< /callout >}}

```bash
openssl ecparam -genkey -name secp384r1 -out root-ca-key.pem
openssl req -x509 -new -nodes -key root-ca-key.pem -sha384 -days 3653 -out root-ca.pem
```

Its private key never leaves that medium. A **new intermediate per lineage** is
signed there too, and only the intermediate's own certificate and key come
back:

```bash
cat > intermediate-ca.cnf <<'EOF'
[ v3_req ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
openssl ecparam -genkey -name secp384r1 -out intermediate-ca-key.pem
openssl req -new -key intermediate-ca-key.pem \
  -subj "/CN=Ogenki AWS Intermediate CA/O=Ogenki/C=FR" -out intermediate-ca.csr
openssl x509 -req -in intermediate-ca.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out intermediate-ca.pem -days 1827 -sha384 \
  -extfile intermediate-ca.cnf -extensions v3_req
openssl verify -CAfile root-ca.pem intermediate-ca.pem
```

The intermediate's certificate and key go to Secrets Manager as
`{"bundle": "..."}` under `certificates/priv.aws.ogenki.io/intermediate-ca`;
the certificates-only chain goes to `certificates/priv.aws.ogenki.io/ca-chain`
as `{"ca": "..."}`. `opentofu/aws/openbao/management/pki.tf` imports the bundle
as the mount's issuer:

```hcl
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.aws_secretsmanager_secret_version.intermediate_ca.secret_string)["bundle"]
}
```

OpenBao's own server certificate (the one terminating TLS on
`bao.priv.aws.ogenki.io:8200`) is a leaf signed by that intermediate, generated
once before the cluster exists and stored in Secrets Manager for
`opentofu/aws/openbao/cluster/` to consume at bootstrap. It is issued on the
same offline medium, immediately after the intermediate and while its key is
still to hand:

```bash
cat > server.cnf <<'EOF'
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:bao.priv.aws.ogenki.io, DNS:bao.priv.gcp.ogenki.io, DNS:openbao.security.svc.cluster.local, DNS:openbao.security.svc
EOF
openssl ecparam -genkey -name prime256v1 -out server-key.pem && chmod 600 server-key.pem
openssl req -new -key server-key.pem \
  -subj "/CN=bao.priv.aws.ogenki.io/O=Ogenki/C=FR" -out server.csr
openssl x509 -req -in server.csr -CA intermediate-ca.pem -CAkey intermediate-ca-key.pem \
  -CAcreateserial -out server.pem -days 825 -sha256 \
  -extfile server.cnf -extensions v3_req
cat intermediate-ca.pem root-ca.pem > ca-chain.pem
openssl verify -CAfile root-ca.pem -untrusted intermediate-ca.pem server.pem
openssl x509 -in server.pem -noout -ext subjectAltName
```

`openssl verify` must print `server.pem: OK` and the SAN line must list all
four names before anything is written to a secret store — a leaf short of one
name fails at a different layer for each name it lacks, and the cheapest place
to catch that is here.

The CN stays the node's own address (`bao.priv.aws.ogenki.io`), so nothing
already trusting that name has to change; the other three names ride along as
SANs. **The GCP leaf is issued exactly the same way**, against
`openbao-priv-gcp-intermediate-ca` rather than the AWS intermediate and with
`/CN=bao.priv.gcp.ogenki.io` — the SAN list is identical, because either node
may answer for either address during a failover.

Two details worth carrying forward if you regenerate it:

- The key is EC P-256, matching the EC P-384 CAs above, and `openssl` writes
  key files world-readable by default — `chmod 600` it, since this key
  terminates TLS for every OpenBao client.
- The SAN list has **no IP address** — the load-bearing property, and the one
  the four names above do not imply: a client connecting to a Raft peer by
  private IP (rather than by one of those names) cannot verify TLS against it.
  The names cover every way a client may legitimately connect: the node's own
  address, the other cloud's node during a failover, and the neutral in-cluster
  Service in both its forms.
- **On this reference platform the deployed certificates do not carry that list
  yet.** `certificates/priv.aws.ogenki.io/openbao` predates it and holds only
  `bao.priv.aws.ogenki.io`; `openbao-priv-gcp-server-cert` holds only
  `bao.priv.gcp.ogenki.io`. Each is fixed by re-issuing that cloud's leaf with
  the SAN list above, under that cloud's own intermediate. Until then,
  cert-manager cannot verify `openbao.security.svc.cluster.local` and its
  `ClusterIssuer` fails with `x509: certificate is valid for
  bao.priv.<cloud>.ogenki.io, not openbao.security.svc.cluster.local`.

### Storing the chain

Three secrets carry the result. Build the JSON payloads with `jq --rawfile` so
the PEM newlines survive — a shell-interpolated `"$(cat …)"` collapses them and
OpenBao rejects the bundle:

```bash
jq -n --rawfile c intermediate-ca.pem --rawfile k intermediate-ca-key.pem '{bundle: ($c + $k)}' > intermediate.json
jq -n --rawfile ca ca-chain.pem '{ca: $ca}' > chain.json
jq -n --rawfile cert server.pem --rawfile key server-key.pem --rawfile ca ca-chain.pem '{cert: $cert, key: $key, ca: $ca}' > server.json
```

**Which verb depends on whether the secret already exists**, and on AWS the
answer differs per secret — `create-secret` on an existing name fails with
`ResourceExistsException`, and `put-secret-value` on a missing one fails with
`ResourceNotFoundException`. Check first rather than guess:

```bash
aws secretsmanager list-secrets --region eu-west-3 \
  --query 'SecretList[?contains(Name, `priv.aws.ogenki.io`)].Name' --output text
```

| Secret | Holds | Verb |
|---|---|---|
| `certificates/priv.aws.ogenki.io/intermediate-ca` | `{"bundle": …}` — intermediate cert **+ key**, the issuer `pki.tf` imports | `put-secret-value` if it already holds the pre-lineage `{cert, key}` pair, else `create-secret` |
| `certificates/priv.aws.ogenki.io/ca-chain` | `{"ca": …}` — certificates only, no key | `create-secret` on first run |
| `certificates/priv.aws.ogenki.io/openbao` | `{"cert", "key", "ca"}` — the server leaf the node reads at boot | `put-secret-value` |

```bash
aws secretsmanager put-secret-value --region eu-west-3 \
  --secret-id certificates/priv.aws.ogenki.io/intermediate-ca --secret-string file://intermediate.json
aws secretsmanager create-secret --region eu-west-3 \
  --name certificates/priv.aws.ogenki.io/ca-chain --secret-string file://chain.json
aws secretsmanager put-secret-value --region eu-west-3 \
  --secret-id certificates/priv.aws.ogenki.io/openbao --secret-string file://server.json
```

Prefer `put-secret-value` wherever the name exists: it adds a version and
leaves the previous one recoverable, which matters because the shape changes —
`intermediate-ca` moves from `{cert, key}` to `{bundle}`, and only the new shape
satisfies `jsondecode(...)["bundle"]` in `pki.tf`.

Then destroy the key material that does not belong in a secret store. The
intermediate key exists only inside `intermediate-ca`'s bundle from here on, and
the leaf key only inside `openbao`:

```bash
shred -u intermediate-ca-key.pem server-key.pem intermediate.json server.json 2>/dev/null \
  || rm -f intermediate-ca-key.pem server-key.pem intermediate.json server.json
```

The root key is **not** in that list and must never be — it stays on the offline
medium.

### Committing the root certificate

The root *certificate* is public, and the weekly restore drill verifies a
restored chain against it with `openssl verify -CAfile`. Reading it from the
repository rather than from a cloud secret store is deliberate: the one job
whose value is being usable during an outage should not depend on the outage
being over. From the ceremony directory, with `REPO` pointing at your clone:

```bash
REPO=~/Sources/cloud-native-ref
cp root-ca.pem "$REPO/.github/openbao-root-ca.pem"
cd "$REPO"
git check-ignore .github/openbao-root-ca.pem   # exit 1 == not ignored == correct
git add .github/openbao-root-ca.pem
git ls-files --error-unmatch .github/openbao-root-ca.pem   # errors if still untracked
git commit -m "chore(pki): commit the offline root certificate for the restore drill"
```

Only `root-ca.pem` is copied. `root-ca-key.pem` sits beside it under a name one
character longer and never leaves the offline medium — it is the *only* file in
the ceremony that can issue a certificate, and the whole design rests on it
never reaching a networked store.

{{< callout type="info" >}}
**Check `git check-ignore` before trusting the `git add`.** `.gitignore` carries
a blanket `*.pem` with a single negation for `openbao-root-ca.pem` in
`.github/`. Without that negation `git add` fails *silently*, the file stays
untracked, and the drill fails every week with `No such file or directory` —
after having already proved the restore worked.

Read the **exit code**, not the output, and run it with **no** `-v`: the
negation is itself a match, so `-v` exits 0 and prints the `!` line, which reads
like "ignored" when it means the opposite. Exit 1 is what you want.

The blanket `*.pem` keeps full force everywhere else, `.github/` included — the
negation names one exact path, not a glob — and `detect-private-key` runs as a
pre-commit hook regardless.
{{< /callout >}}

## Trusting the CA on your machine

Every private service is served with a certificate from this chain, and no
system trust store knows the offline root. Until you import it, browsers and
`curl` reject `*.priv.aws.ogenki.io` and `*.priv.gcp.ogenki.io` outright — the
failure looks like a broken deployment rather than a missing trust anchor.

**This has to be redone whenever the root changes**, which in practice means
after a cluster rebuild that regenerated the PKI, or when a cluster moves to a
new private domain.

Fetch the chain with `openbao-config.sh ca` — it knows where the secret lives on
each cloud, and that AWS stores it as JSON under a `.ca` key while GCP stores raw
PEM:

```bash
# aws-0
./scripts/openbao-config.sh ca --region eu-west-3 \
  --root-ca-secret-name certificates/priv.aws.ogenki.io/ca-chain \
  --ca-output-file /tmp/ogenki-aws-ca.pem

# gcp-0
./scripts/openbao-config.sh ca --cloud gcp --project ogenki-435905 \
  --root-ca-secret-name openbao-priv-gcp-ca-chain \
  --ca-output-file /tmp/ogenki-gcp-ca.pem
```

Check you got a certificate and not an error page before importing anything:

```bash
openssl x509 -in /tmp/ogenki-aws-ca.pem -noout -subject -dates
```

Then add it to the system trust store:

```bash
# Arch / Fedora (p11-kit)
sudo trust anchor --store /tmp/ogenki-aws-ca.pem

# Debian / Ubuntu
sudo cp /tmp/ogenki-aws-ca.pem /usr/local/share/ca-certificates/ogenki-aws.crt
sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/ogenki-aws-ca.pem
```

{{< callout type="info" >}}
**Firefox does not use the system store.** It keeps its own NSS database, so a
certificate trusted by `curl` and Chrome is still rejected there. Import it under
*Settings → Privacy & Security → Certificates → View Certificates → Authorities*.
{{< /callout >}}

**Once Tasks 14 and 14b have run**, both clouds chain to the same offline root
([ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}}))
and one import covers both. Until then it is two imports: the AWS chain still
descends from the root in `certificates/priv.aws.ogenki.io/root-ca`, and the GCP
chain from the 2026-08-25 offline root. Import both files above and you are
covered under either state.

Nothing else on your machine needs the file afterwards. The OpenBao management
stack fetches its own copy into a gitignored `.tls/` directory at apply time —
that one exists so the Vault provider can verify the server at plan time, not for
your browser.

## cert-manager: issuing from the PKI

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao
  namespace: security
spec:
  vault:
    server: https://openbao.security.svc.cluster.local:8200
    path: pki_private_issuer/sign/ogenki
    caBundleSecretRef:
      name: openbao-ca
      key: ca.crt
    auth:
      kubernetes:
        mountPath: /v1/auth/jwt/${cluster_name}
        role: cert-manager
        serviceAccountRef:
          name: cert-manager
          audiences:
            - openbao
```

A `ClusterIssuer` reaches OpenBao by the **neutral in-cluster name**
`openbao.security.svc.cluster.local` — an `ExternalName` Service in
`security/base/openbao-endpoint/` that a cluster points at its own cloud's
load balancer (local form) or, through the Tailscale operator's egress
`ProxyGroup`, at the other cloud's (remote form). It authenticates with a
**projected ServiceAccount token** against `jwt/<cluster>`: cert-manager
requests a 10-minute token with audience `openbao` for its own ServiceAccount
and POSTs it with the role name. No AppRole, no `SecretID`, nothing synced. The
CA bundle is still an `ExternalSecret`, from `certificates/<domain>/ca-chain`.

Neither the PKI mount nor the auth mount needs a `namespace:` field on the
issuer — both live in OpenBao's root namespace (see
[OpenBao]({{< relref "/docs/platform/security/openbao.md#namespace-layout" >}})).

A `Certificate` object requesting one of these leaves looks like any other
cert-manager request:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: foobar
spec:
  secretName: foobar-tls
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  commonName: foobar.priv.aws.ogenki.io
  dnsNames:
    - foobar.priv.aws.ogenki.io
    - foobar.security.svc.cluster.local
  issuerRef:
    name: openbao
    kind: ClusterIssuer
    group: cert-manager.io
```

This is also what terminates TLS at the Gateway API layer: Gateway listeners
reference a `Secret` cert-manager keeps populated from this same issuer, so
rotation is automatic — cert-manager renews `renewBefore` the expiry and the
Gateway picks up the new `Secret` without a redeploy.

## External Secrets: the other direction

Where cert-manager pulls certificates *out* of OpenBao's PKI, External
Secrets Operator pulls arbitrary credentials *out of the cloud's managed
secret store* — the CA chain above, the OpenBao admin password, every
application credential. One `ClusterSecretStore` backs every `ExternalSecret`
in the cluster:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: clustersecretstore
spec:
  provider:
    aws:
      region: ${region}
      service: SecretsManager
```

On `gcp-0` the same store name is backed by GCP Secret Manager instead
(`security/gcp-0/openbao/clustersecretstore.yaml`), with no `auth` block at
all — deliberately: under GKE Workload Identity the controller's
ServiceAccount is itself a Google principal, so there is no key to mount,
rotate, or leak:

```yaml
spec:
  provider:
    gcpsm:
      projectID: ${project_id}
```

Why the store of record is the cloud's managed service rather than OpenBao —
cost, lifecycle, and the bootstrap circularity — is recorded in
[ADR-0025]({{< relref "/docs/decisions/0025-cloud-managed-secret-stores.md" >}});
the shared store name and the dash-grammar keys that let one `ExternalSecret`
work on both clouds are
[ADR-0023]({{< relref "/docs/decisions/0023-portable-secret-store-names.md" >}}).

This is the platform's concrete instance of the constitution's [Secrets
Management rule]({{< relref "/docs/reference/platform-constitution.md#32-secrets-management" >}}):
no hardcoded credentials in a manifest, HelmRelease, or Crossplane
composition — everything resolves through this one `ClusterSecretStore` at
reconcile time, refreshed on an interval (`refreshInterval: 1h` is typical)
rather than baked in once.

## Rotation

Nothing here rotates itself yet. The intermediate is a manual re-import into
`pki_private_issuer` when it approaches its `days` expiry; leaf certificates
rotate automatically through cert-manager's `renewBefore`. Treat the
Root/Intermediate chain's expiry the same way as any other operational
calendar item — there's no alert wired to it today.
