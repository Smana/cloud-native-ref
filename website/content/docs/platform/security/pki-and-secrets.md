---
title: PKI & Secrets
weight: 20
description: The three-tier PKI chain OpenBao issues from, how cert-manager and External Secrets pull from it, and how the chain rotates.
lastVerified: 2026-08-27
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
The Root CA private key is **present in the live `pki_private_issuer`
mount**, not held offline. `opentofu/aws/openbao/management/pki.tf`'s
`vault_pki_secret_backend_root_sign_intermediate` resource signs the
Intermediate's CSR *inside* OpenBao — keeping the root offline would mean
the CSR leaves OpenBao, gets signed elsewhere, and comes back, a manual step
incompatible with `terramate script run deploy`
(`opentofu/aws/openbao/management/README.md`). This is an accepted trade-off
**for this reference platform**; do not carry it into a deployment where the
root CA matters.
{{< /callout >}}

### Building the chain

The root and intermediate CAs are generated once, outside Terraform, with
`openssl` — EC keys (`secp384r1` for the CAs, `prime256v1` for OpenBao's own
leaf) rather than RSA:

```bash
# Root CA
openssl ecparam -genkey -name secp384r1 -out root-ca-key.pem
openssl req -x509 -new -nodes -key root-ca-key.pem -sha384 -days 3653 -out root-ca.pem

# Intermediate CA — CSR, then sign it with the root
openssl ecparam -genkey -name secp384r1 -out intermediate-ca-key.pem
openssl req -new -key intermediate-ca-key.pem -out intermediate-ca.csr
openssl x509 -req -in intermediate-ca.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out intermediate-ca.pem -days 1827 -sha384 \
  -extfile intermediate-ca.cnf -extensions v3_req
```

The intermediate's certificate and private key (`bundle`/`ca` in the JSON
shape below) are what `opentofu/aws/openbao/management/pki.tf` imports into the
`pki_private_issuer` mount — `vault_pki_secret_backend_config_ca`, followed
by a CSR/sign/set-signed sequence that makes OpenBao the active issuer for
that intermediate. The root material itself is read from AWS Secrets
Manager, not committed to Git:

```hcl
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.aws_secretsmanager_secret_version.root_ca.secret_string).bundle
}
```

OpenBao's own server certificate (the one terminating TLS on
`bao.priv.aws.ogenki.io:8200`) is a leaf signed the same way, generated
once before the cluster exists and stored in Secrets Manager for
`opentofu/aws/openbao/cluster/` to consume at bootstrap. Two details worth
carrying forward if you regenerate it:

- The key is EC P-256, matching the EC P-384 CAs above, and `openssl` writes
  key files world-readable by default — `chmod 600` it, since this key
  terminates TLS for every OpenBao client.
- The SAN list has **no IP address**, only `DNS:bao.priv.aws.ogenki.io`.
  That's why a client connecting to a Raft peer by private IP address
  (rather than through the NLB's DNS name) cannot verify TLS against it.

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
  --root-ca-secret-name certificates/priv.aws.ogenki.io/root-ca \
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

Each cloud has its own offline root — [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}})
— so trusting `aws-0` does nothing for `gcp-0`. Import both if you use both.

Nothing else on your machine needs the file afterwards. The OpenBao management
stack fetches its own copy into a gitignored `.tls/` directory at apply time —
that one exists so the Vault provider can verify the server at plan time, not for
your browser.

## cert-manager: issuing from the PKI

A `ClusterIssuer` authenticates to OpenBao with the `cert-manager` AppRole
and signs from `pki_private_issuer/sign/ogenki`. Both the CA bundle and the
AppRole `SecretID` are synced from AWS Secrets Manager by External Secrets
Operator rather than pasted into the manifest — rotating the intermediate no
longer means hand-editing a `ClusterIssuer`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao
  namespace: security
spec:
  vault:
    server: https://bao.priv.aws.ogenki.io:8200
    path: pki_private_issuer/sign/ogenki
    caBundleSecretRef:
      name: openbao-ca
      key: ca.crt
    auth:
      appRole:
        path: approle
        roleId: ${cert_manager_approle_id}
        secretRef:
          name: cert-manager-openbao-approle
          key: cert_manager_approle_secret
```

Both referenced secrets are `ExternalSecret` objects
(`security/base/cert-manager/`) pulling from the same AWS Secrets Manager
entries the OpenTofu management stack writes to — one for the CA chain
(`certificates/priv.aws.ogenki.io/root-ca`), one for the AppRole
credential (`openbao-cloud-native-ref-approles-cert-manager`, the portable
dash grammar of [ADR-0023]({{< relref "/docs/decisions/0023-portable-secret-store-names.md" >}});
the CA-chain key keeps its slash shape as that ADR's documented exception).
Neither the
PKI mount nor the AppRole needs a `namespace:` field on the issuer — both
live in OpenBao's root namespace (see
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
secret store* — the AppRole `SecretID`s above, the OpenBao admin password,
the snapshot job's credentials. One `ClusterSecretStore` backs every
`ExternalSecret` in the cluster:

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
