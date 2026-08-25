# GCP Private Ingress and external-dns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `gcp-0` private ingress — two Tailscale-backed Gateways serving `*.priv.gcp.ogenki.io` with TLS from the OpenBao PKI, and DNS records maintained automatically in the private Cloud DNS zone.

**Architecture:** Three cluster-side components. The tailscale-operator services `loadBalancerClass: tailscale`; the Gateway API layer is consumed **by file** from the existing cloud-neutral `infrastructure/base/gapi/`; external-dns runs the `google` provider with identity from a `GCPWorkloadIdentity` claim. Two new Flux Kustomizations enforce ordering with `dependsOn` plus health checks, because the components admit each other's resources through validating webhooks.

**Tech Stack:** Flux (Kustomize + Helm), Cilium Gateway API, Tailscale Kubernetes Operator 1.90.6, external-dns 1.21.1, Crossplane (`GCPWorkloadIdentity` from `crossplane-configuration-gcp:v0.2.0`), OpenTofu, GCP Cloud DNS + Secret Manager.

**Spec:** [`docs/superpowers/specs/2026-08-25-gcp-private-ingress-design.md`](../specs/2026-08-25-gcp-private-ingress-design.md)

## Global Constraints

- **Cluster names**: `aws-0` and `gcp-0`. Renamed in #1832; never write `mycluster-0`.
- **GCP project**: `ogenki-435905`. Project number `323586397743`. Region `europe-west4`, zone `europe-west4-a`.
- **Private domain**: `priv.gcp.ogenki.io` on GCP, `priv.aws.ogenki.io` on AWS. Always reach it through `${private_domain_name}`, never a literal.
- **DNS role**: `projects/ogenki-435905/roles/xplane_dns_editor` — already created and allowlisted in `crossplane_grantable_roles` (`opentofu/gcp/gke/init/iam.tf`). Do not create it.
- **No public certificates, no public Gateway.** Excluded by the spec. Never add `platform-public-gateway.yaml` to a GCP kustomization.
- **No `ProxyGroup`.** AWS runs egress proxies; GCP has no consumer. YAGNI.
- **By-file references across directories are correct here** — Flux and `scripts/flux-schema/render-bundle.py` both build with `--load-restrictor=LoadRestrictionsNone`. Do not "fix" them into directory references.
- **Namespaces**: tailscale-operator → `tailscale`; external-dns → `kube-system`; Gateways → `infrastructure`; External Secrets controller SA → `security/external-secrets`.
- **Evidence rule** (`.claude/rules/process.md`): no "done" without a fresh command run cited inline. `./scripts/validate-manifests.sh` must report `Invalid: 0, Skipped: 0`.
- **Standing user rule: never leave test infrastructure running.** Task 6 ends with a verified teardown.

---

### Task 1: Parameterise the Gateway Tailscale hostnames

Both Gateways hardcode a Tailscale hostname. Two clusters cannot claim the same one — Tailscale silently suffixes the loser, making its MagicDNS name unpredictable. This is the one task that touches AWS-consumed manifests.

**Files:**
- Modify: `infrastructure/base/gapi/platform-tailscale-general-gateway.yaml`
- Modify: `infrastructure/base/gapi/platform-tailscale-admin-gateway.yaml`

**Interfaces:**
- Consumes: `${cluster_name}` from both clusters' vars ConfigMaps (`eks-aws-0-vars`, `gke-gcp-0-vars`) — already present, no new variable.
- Produces: device hostnames `gateway-general-priv-aws-0`, `gateway-admin-priv-aws-0`, `gateway-general-priv-gcp-0`, `gateway-admin-priv-gcp-0`.

- [ ] **Step 1: Change the general Gateway's hostname**

In `infrastructure/base/gapi/platform-tailscale-general-gateway.yaml`, replace the `tailscale.com/hostname` line inside `spec.infrastructure.annotations`:

```yaml
  infrastructure:
    annotations:
      # Per-cluster, because the tailnet is SHARED between aws-0 and gcp-0 and a
      # Tailscale hostname is tailnet-unique. Two clusters claiming
      # "gateway-general-priv" does not error -- Tailscale suffixes the second
      # device, so its MagicDNS name silently stops being the one anything
      # expects.
      #
      # <role>-<visibility>-<cluster> rather than a suffix that is empty on AWS:
      # a scheme where one cloud is the unlabelled default is exactly what
      # ADR-0017 rejects for DNS names, and cluster names were renamed to aws-0 /
      # gcp-0 in #1832 for the same reason.
      tailscale.com/hostname: "gateway-general-priv-${cluster_name}"
      tailscale.com/tags: "tag:k8s"
      tailscale.com/funnel: "false"
```

- [ ] **Step 2: Change the admin Gateway's hostname**

In `infrastructure/base/gapi/platform-tailscale-admin-gateway.yaml`, apply the same change with the admin values (keep its existing `tailscale.com/tags: "tag:admin"` line unchanged):

```yaml
      tailscale.com/hostname: "gateway-admin-priv-${cluster_name}"
```

Add a one-line comment pointing at the general Gateway rather than repeating the paragraph:

```yaml
      # Per-cluster hostname -- see platform-tailscale-general-gateway.yaml for why.
```

- [ ] **Step 3: Verify both hostnames render per cluster**

Run:

```bash
kustomize build infrastructure/aws-0 --load-restrictor=LoadRestrictionsNone \
  | grep 'tailscale.com/hostname'
```

Expected: two lines, both still containing the literal `${cluster_name}` — kustomize does not substitute; Flux does. This step only proves the annotation survives the build.

Then prove substitution end-to-end through the repo's own renderer:

```bash
./scripts/validate-manifests.sh 2>&1 | grep -E "RENDER:|Invalid:"
grep -rn "gateway-general-priv" .bundle/ | head -4
```

Expected: `Invalid: 0, Skipped: 0`, and the rendered bundle shows `gateway-general-priv-foobar` (the fixture value of `cluster_name` in `scripts/flux-schema/render-bundle.py`), **not** a bare `${cluster_name}`. A literal `${...}` surviving into the bundle means the variable is not in the ConfigMap and Flux would render it unsubstituted while reporting success.

- [ ] **Step 4: Commit**

```bash
git add infrastructure/base/gapi/
git commit -m "refactor(gapi): per-cluster Tailscale hostnames on the private Gateways"
```

---

### Task 2: Bootstrap prerequisites — Tailscale OAuth client, IAM, and one documented procedure

The tailscale-operator authenticates with a Tailscale OAuth client. AWS reads one from AWS Secrets Manager; GCP gets **its own**, so compromising one cluster's operator does not force rotating the other's.

This task also pays down debt the spec flags: GCP now has three hand-created prerequisites (Cloud KMS key ring, the OpenTofu state bucket and its project, this OAuth client) documented in three unrelated files. Three undocumented steps is how a repository stops being reproducible.

**Files:**
- Create: `docs/gcp-bootstrap.md`
- Modify: `opentofu/gcp/gke/init/iam.tf`
- Modify: `opentofu/gcp/gke/init/variables.tf`

**Interfaces:**
- Consumes: `data.google_project.this.number` (already in `iam.tf`), `var.project_id`.
- Produces: GCP Secret Manager entry `tailscale-k8s-operator-oauth`, readable by the External Secrets controller principal.

- [ ] **Step 1: Create the OAuth client and store it**

In the Tailscale admin console (Settings → OAuth clients), create a client with scopes `devices:core` and `auth_keys` (write), tagged `tag:k8s-operator`. Then:

```bash
CLIENT_ID='<paste>'
CLIENT_SECRET='<paste>'
printf '{"client_id":"%s","client_secret":"%s"}' "$CLIENT_ID" "$CLIENT_SECRET" \
  | gcloud secrets create tailscale-k8s-operator-oauth \
      --project=ogenki-435905 --replication-policy=automatic --data-file=-
```

The JSON keys `client_id` and `client_secret` are what the chart's `operator-oauth` Secret requires; `dataFrom.extract` in Task 3 copies them verbatim, so do not rename them.

Verify:

```bash
gcloud secrets versions access latest --secret=tailscale-k8s-operator-oauth \
  --project=ogenki-435905 | jq -r 'keys | join(",")'
```

Expected: `client_id,client_secret`

- [ ] **Step 2: Add the External Secrets identity variables**

Append to `opentofu/gcp/gke/init/variables.tf`:

```hcl
variable "external_secrets_namespace" {
  description = "Namespace of the External Secrets controller's ServiceAccount. Part of the Workload Identity subject, so it must match the cluster exactly."
  type        = string
  default     = "security"
}

variable "external_secrets_service_account" {
  description = "Name of the External Secrets controller's ServiceAccount. Part of the Workload Identity subject; a mismatch produces a binding the API accepts and that never matches."
  type        = string
  default     = "external-secrets"
}

variable "tailscale_oauth_secret_name" {
  description = "GCP Secret Manager entry holding the Tailscale OAuth client for the Kubernetes operator. Created by hand -- see docs/gcp-bootstrap.md."
  type        = string
  default     = "tailscale-k8s-operator-oauth"
}
```

- [ ] **Step 3: Bind External Secrets to that one secret**

Append to `opentofu/gcp/gke/init/iam.tf`:

```hcl
# External Secrets' access to the Tailscale OAuth client.
#
# PER-SECRET, not through GCPWorkloadIdentity, for the same reason
# opentofu/gcp/openbao/management/iam.tf binds per secret: that composition
# renders ProjectIAMMember, which is PROJECT-scoped, so any secret-reading role
# granted through it can read every secret in the project by name -- including
# OpenBao's root token and the intermediate CA's private key.
#
# The subject duplicates the one in openbao/management deliberately rather than
# being shared: the two stacks have no dependency edge, and a remote-state read
# purely to avoid restating two strings would create one.
locals {
  # TRAP: `projects/` takes the project NUMBER while `workloadIdentityPools/`
  # takes the project ID. Reversed, the API ACCEPTS the binding and it silently
  # never matches.
  external_secrets_principal = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/${var.external_secrets_namespace}/sa/${var.external_secrets_service_account}",
  ])
}

resource "google_secret_manager_secret_iam_member" "external_secrets_tailscale_oauth" {
  project   = var.project_id
  secret_id = var.tailscale_oauth_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = local.external_secrets_principal
}
```

- [ ] **Step 4: Validate the stack**

```bash
cd opentofu/gcp/gke/init
tofu fmt && tofu init -backend=false -input=false >/dev/null && tofu validate
```

Expected: `Success! The configuration is valid` (warnings about a deprecated `kubernetes_config_map` are pre-existing and fine).

If `tofu init` fails with `invalid ref: "<sha>"`, that is transient GitHub throttling on module downloads — re-run it. It is not caused by this change.

- [ ] **Step 5: Write the consolidated bootstrap document**

Create `docs/gcp-bootstrap.md`:

```markdown
# GCP bootstrap prerequisites

Three things must exist before `terramate script run deploy` can build GCP, and
none of them is managed by OpenTofu. Each is deliberate — they are all
chicken-and-egg or destructive-to-recreate — but three of them scattered across
three files is how a repository quietly stops being reproducible. They are
collected here.

Run these once per GCP project.

## 1. OpenTofu state bucket (ADR-0018)

State lives in GCS, in a project that holds nothing else, so that deleting or
suspending the workload project cannot take the state describing it too.

```bash
gcloud projects create ogenki-tfstate --organization=<org-id>
gcloud billing projects link ogenki-tfstate --billing-account=<account-id>
gcloud services enable storage.googleapis.com --project=ogenki-tfstate
gcloud storage buckets create gs://ogenki-cloud-native-ref-tfstate \
  --project=ogenki-tfstate --location=europe-west4 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://ogenki-cloud-native-ref-tfstate --versioning
```

Versioning is the recovery path for a truncated state file and is painful to add
after the fact.

## 2. Cloud KMS key ring for OpenBao auto-unseal

Read as a data source by `opentofu/gcp/openbao/cluster/kms.tf`, never managed,
because **GCP cannot delete either a key ring or a crypto key.** A `tofu destroy`
of a managed one returns success while destroying only key VERSIONS, and a
rebuild then fails with `ALREADY_EXISTS`.

```bash
gcloud services enable cloudkms.googleapis.com --project=ogenki-435905
gcloud kms keyrings create openbao-dev --location=europe-west4 --project=ogenki-435905
gcloud kms keys create openbao-unseal --location=europe-west4 \
  --keyring=openbao-dev --purpose=encryption --project=ogenki-435905
```

It survives teardown by design and costs nothing idle. Do not treat it as a leak.

## 3. Tailscale OAuth client for the Kubernetes operator

Separate from the AWS cluster's client, so compromising one cluster's operator
does not force rotating the other's.

Create an OAuth client in the Tailscale admin console (Settings → OAuth clients)
with scopes `devices:core` and `auth_keys` (write), tagged `tag:k8s-operator`,
then:

```bash
printf '{"client_id":"%s","client_secret":"%s"}' "$CLIENT_ID" "$CLIENT_SECRET" \
  | gcloud secrets create tailscale-k8s-operator-oauth \
      --project=ogenki-435905 --replication-policy=automatic --data-file=-
```

The JSON keys are consumed verbatim by `dataFrom.extract` into the chart's
required `operator-oauth` Secret — do not rename them.

**Revoke this client on teardown** if the project is being decommissioned; it is
the one prerequisite that is a live credential rather than an empty container.

## What is NOT a prerequisite

The offline root CA and the GCP intermediate. Those come from the signing
ceremony in the [OpenBao design](superpowers/specs/2026-08-24-gcp-openbao-design.md)
and already live in Secret Manager (`openbao-priv-gcp-ca-chain`,
`openbao-priv-gcp-intermediate-ca`). The root's private key must never be in GCP.
```

- [ ] **Step 6: Link the document from CLAUDE.md**

In `CLAUDE.md`, under the `### Prerequisites` bullet list, add:

```markdown
- **GCP only:** three hand-created prerequisites — state bucket, Cloud KMS key ring, Tailscale OAuth client. See [`docs/gcp-bootstrap.md`](docs/gcp-bootstrap.md).
```

- [ ] **Step 7: Verify links and commit**

```bash
./scripts/validate-links.sh
git add docs/gcp-bootstrap.md CLAUDE.md opentofu/gcp/gke/init/
git commit -m "feat(gcp): Tailscale OAuth bootstrap secret, and one bootstrap doc"
```

Expected: `validate-links.sh` exit 0.

---

### Task 3: tailscale-operator on gcp-0

**Files:**
- Create: `security/gcp-0/tailscale-operator/kustomization.yaml`
- Create: `security/gcp-0/tailscale-operator/oauth-client-externalsecret.yaml`
- Create: `clusters/gcp-0/security/security-tailscale.yaml`

**Interfaces:**
- Consumes: `clustersecretstore` (ClusterSecretStore, from workstream 11); Secret Manager entry `tailscale-k8s-operator-oauth` (Task 2).
- Produces: a running operator that services `loadBalancerClass: tailscale`; Flux Kustomization named `security-tailscale`, which Task 4 depends on.

- [ ] **Step 1: Create the OAuth ExternalSecret**

`security/gcp-0/tailscale-operator/oauth-client-externalsecret.yaml`:

```yaml
# The Tailscale OAuth client the operator authenticates with.
#
# GCP has its OWN client, not a copy of the AWS one: compromising this cluster's
# operator should not force rotating the other cluster's. Created by hand --
# docs/gcp-bootstrap.md -- because it is issued by the Tailscale admin console.
#
# `dataFrom.extract` copies the JSON's keys verbatim, so the Secret ends up with
# client_id / client_secret, which is what the chart requires. The target NAME is
# also fixed by the chart and must stay `operator-oauth`.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tailscale-operator-oauth-client
spec:
  dataFrom:
    - extract:
        conversionStrategy: Default
        key: tailscale-k8s-operator-oauth
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: clustersecretstore
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
    name: operator-oauth
```

Note there is no `namespace:` in `metadata` — the kustomization sets it, matching the AWS tree.

- [ ] **Step 2: Create the kustomization**

`security/gcp-0/tailscale-operator/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: tailscale

# The chart and both ProxyClasses come from security/base BY FILE, not by
# directory. The base directory also carries oauth-client-externalsecret.yaml,
# whose `key: tailscale/k8s-operator/oauth-client` is an AWS Secrets Manager
# path -- pulling the directory would bring a store reference that cannot
# resolve here, and its target Secret name would collide with ours.
#
# Referencing the chart by file keeps a version bump landing on both clouds at
# once. Flux builds with LoadRestrictionsNone, as does
# scripts/flux-schema/render-bundle.py, so a cross-directory file reference is
# supported rather than tolerated.
#
# NO proxygroup.yaml. AWS runs `ts-proxies`, two EGRESS replicas; nothing on
# this cluster egresses through the tailnet. Add it when something does.
resources:
  - ../../base/tailscale-operator/helmrelease.yaml
  - ../../base/tailscale-operator/proxyclass-general.yaml
  - ../../base/tailscale-operator/proxyclass-admin.yaml
  - oauth-client-externalsecret.yaml
```

- [ ] **Step 3: Create the Flux Kustomization**

`clusters/gcp-0/security/security-tailscale.yaml`:

```yaml
# The Tailscale Kubernetes Operator.
#
# Its own Kustomization rather than part of `security`, because the Gateway API
# layer (infrastructure-gapi) must wait for it: without a running operator both
# Gateways' Services sit Pending forever with no error naming the cause, since
# nothing services loadBalancerClass: tailscale.
#
# dependsOn security-openbao rather than security: this needs External Secrets
# RUNNING (to sync the OAuth client), and security-openbao is already gated on
# that via security's HelmRelease health checks. Depending on the deepest edge
# that implies the others keeps this graph honest instead of listing all three.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: security-tailscale
  namespace: flux-system
spec:
  prune: true
  interval: 4m0s
  retryInterval: 30s
  timeout: 8m0s
  sourceRef:
    kind: ExternalArtifact
    name: security-artifact
  path: ./security/gcp-0/tailscale-operator
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: gke-gcp-0-vars
  dependsOn:
    - name: security-openbao
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: tailscale-operator
      namespace: tailscale
```

- [ ] **Step 4: Validate**

```bash
./scripts/validate-manifests.sh 2>&1 | grep -E "RENDER:|Invalid:"
kustomize build security/gcp-0/tailscale-operator --load-restrictor=LoadRestrictionsNone \
  | grep -E "^kind:|  name:|  namespace:"
```

Expected: `Invalid: 0, Skipped: 0`; and the build shows a HelmRelease `tailscale-operator`, two ProxyClasses (`general`, `admin`), and one ExternalSecret `tailscale-operator-oauth-client` — **all in namespace `tailscale`**, with no ProxyGroup and no second ExternalSecret.

- [ ] **Step 5: Commit**

```bash
git add security/gcp-0/tailscale-operator/ clusters/gcp-0/security/security-tailscale.yaml
git commit -m "feat(gcp): tailscale-operator on gcp-0"
```

---

### Task 4: Gateway API layer on gcp-0

**Files:**
- Create: `infrastructure/gcp-0/gapi/kustomization.yaml`
- Create: `clusters/gcp-0/infrastructure/gapi.yaml`

**Interfaces:**
- Consumes: `security-tailscale` (Task 3); the `openbao` ClusterIssuer from workstream 11; `${private_domain_name}` and `${cluster_name}` from `gke-gcp-0-vars`.
- Produces: Gateways `platform-tailscale-general` and `platform-tailscale-admin` in namespace `infrastructure`, both labelled `external-dns: enabled`, which Task 5's external-dns watches.

- [ ] **Step 1: Create the kustomization**

`infrastructure/gcp-0/gapi/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: infrastructure

# Six of the seven manifests in infrastructure/base/gapi are cloud-neutral and
# are used verbatim. Referenced BY FILE because the seventh is not:
#
#   platform-public-gateway.yaml carries
#   service.beta.kubernetes.io/aws-load-balancer-* annotations and
#   cert-manager.io/cluster-issuer: letsencrypt-prod. It is the PUBLIC path,
#   which this cluster deliberately does not build -- see the design's "What this
#   deliberately does NOT build". Adding it here would also require solving
#   DNS-01 against a public zone GCP does not have.
#
# platform-private-gateway-certificate.yaml needs no GCP variant at all: it asks
# the `openbao` ClusterIssuer for *.${private_domain_name}, and workstream 11
# verified that issuer end to end on this cluster.
#
# Using loadBalancerClass: tailscale rather than a GCP forwarding rule means the
# private gateways incur no cloud load-balancer charges.
resources:
  - ../../base/gapi/tailscale-gatewayclass.yaml
  - ../../base/gapi/tailscale-gatewayclass-config.yaml
  - ../../base/gapi/platform-tailscale-general-gateway.yaml
  - ../../base/gapi/platform-tailscale-admin-gateway.yaml
  - ../../base/gapi/platform-private-gateway-certificate.yaml
  - ../../base/gapi/allow-gateway-l7-proxy.yaml
```

- [ ] **Step 2: Create the Flux Kustomization**

`clusters/gcp-0/infrastructure/gapi.yaml`:

```yaml
# Gateway API layer: the GatewayClass, both Tailscale Gateways, the wildcard
# certificate and the L7-proxy network policy.
#
# TWO dependsOn edges, both load-bearing, and both learned the hard way in
# workstream 11:
#
#   - security-openbao, because the wildcard Certificate cannot be issued before
#     the `openbao` ClusterIssuer exists. It is also cert-manager's webhook that
#     admits the Certificate, and applying a resource in the same reconcile as
#     the chart that admits it fails with `no endpoints available` and then backs
#     off exponentially -- while Flux reports Ready.
#   - security-tailscale, because without the operator both Gateways' Services
#     sit Pending forever and nothing in their status names the reason.
#
# healthChecks on the Gateways rather than the Certificate: a Gateway going
# Programmed proves the whole chain -- the operator serviced the LoadBalancer,
# Cilium accepted the GatewayClass, and the TLS secret resolved.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-gapi
  namespace: flux-system
spec:
  prune: true
  interval: 4m0s
  retryInterval: 30s
  timeout: 10m0s
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  path: ./infrastructure/gcp-0/gapi
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: gke-gcp-0-vars
  dependsOn:
    - name: security-openbao
    - name: security-tailscale
  healthChecks:
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      name: platform-tailscale-general
      namespace: infrastructure
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      name: platform-tailscale-admin
      namespace: infrastructure
```

- [ ] **Step 3: Validate, and prove the public Gateway is absent**

```bash
./scripts/validate-manifests.sh 2>&1 | grep -E "RENDER:|Invalid:"
kustomize build infrastructure/gcp-0/gapi --load-restrictor=LoadRestrictionsNone \
  | grep -E "^kind:|^  name:"
```

Expected: `Invalid: 0, Skipped: 0`; exactly one `GatewayClass`, one `CiliumGatewayClassConfig`, two `Gateway`s, one `Certificate`, one `CiliumClusterwideNetworkPolicy` — and **no `platform-public` Gateway**.

Confirm no AWS-only annotation leaked in:

```bash
kustomize build infrastructure/gcp-0/gapi --load-restrictor=LoadRestrictionsNone \
  | grep -c "aws-load-balancer"
```

Expected: `0`

- [ ] **Step 4: Commit**

```bash
git add infrastructure/gcp-0/gapi/ clusters/gcp-0/infrastructure/gapi.yaml
git commit -m "feat(gcp): Tailscale Gateways and the private wildcard certificate"
```

---

### Task 5: external-dns with the google provider

**Files:**
- Create: `infrastructure/gcp-0/external-dns/kustomization.yaml`
- Create: `infrastructure/gcp-0/external-dns/helmrelease.yaml`
- Create: `infrastructure/gcp-0/external-dns/workloadidentity.yaml`
- Modify: `infrastructure/gcp-0/kustomization.yaml`

**Interfaces:**
- Consumes: `${private_domain_name}`, `${project_id}`, `${cluster_name}` from `gke-gcp-0-vars`; the custom role `projects/ogenki-435905/roles/xplane_dns_editor`; the Gateways from Task 4 (as watch targets).
- Produces: DNS records under `priv.gcp.ogenki.io` with a TXT registry owned by `gcp-0`.

- [ ] **Step 1: Create the GCPWorkloadIdentity claim**

`infrastructure/gcp-0/external-dns/workloadidentity.yaml`:

```yaml
# external-dns's Google identity.
#
# This is the GCPWorkloadIdentity composition's FIRST consumer, and the call is
# deliberately the opposite of workstream 11's. There, External Secrets needed
# exactly two named secrets, and this composition renders ProjectIAMMember --
# project-scoped -- which would have granted read of every secret in the project
# including the intermediate CA's private key. So it was bound per secret and
# this API was left without a consumer.
#
# external-dns's access genuinely IS project-shaped: it must discover which zone
# owns a name, which needs dns.managedZones.list ACROSS the project. A per-zone
# google_dns_managed_zone_iam_member cannot express that.
#
# xplane_dns_editor (opentofu/gcp/gke/init/iam.tf) holds record and change
# permissions plus read-only on zones -- no zone create or delete. It is
# allowlisted in crossplane_grantable_roles; a role outside that list fails at
# the provider with a message naming it.
#
# The claim lives in kube-system because the composition derives the
# ServiceAccount's namespace from the claim's own, and that is where external-dns
# runs. No annotation is added to the ServiceAccount: GKE Workload Identity binds
# by SUBJECT.
apiVersion: cloud.ogenki.io/v1alpha1
kind: GCPWorkloadIdentity
metadata:
  name: xplane-external-dns
  namespace: kube-system
spec:
  serviceAccount:
    name: external-dns
  roles:
    - "projects/${project_id}/roles/xplane_dns_editor"
```

- [ ] **Step 2: Create the HelmRelease patch**

`infrastructure/gcp-0/external-dns/helmrelease.yaml`:

```yaml
# GCP overrides for the shared external-dns release.
#
# provider: google, and ONE domain filter. AWS filters two zones because it owns
# a public one; this cluster has only the private Cloud DNS zone --
# cloud.ogenki.io is a Route53 zone this repository does not manage, and public
# certificates are out of scope by design.
#
# --google-zone-visibility=private stops it enumerating public zones it has no
# business in. domainFilters is a CLIENT-side filter and not a security
# boundary; the IAM role is.
#
# The base's `global.imageRegistry: public.ecr.aws` and its top-level `aws:`
# block are deliberately NOT touched. Verified against
# `helm show values external-dns/external-dns --version 1.21.1`: neither is a
# chart value -- `global` supports only `imagePullSecrets`, and there is no
# top-level `aws` key. Both are inert on both clouds. Overriding a setting that
# does nothing, and writing a comment explaining why, would be two lies for the
# price of one.
#
# GCP settings therefore go through extraArgs, because chart 1.21.1 has no
# `google:` values block either.
#
# txtOwnerId stays at the base's ${cluster_name}. The two clusters are now
# distinct (aws-0 / gcp-0), so their TXT registries cannot collide.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: external-dns
  namespace: kube-system
spec:
  values:
    provider:
      name: google
    domainFilters:
      - ${private_domain_name}
    extraArgs:
      - --google-project=${project_id}
      - --google-zone-visibility=private
      - --gateway-namespace=infrastructure
      - --gateway-label-filter=external-dns=enabled
      - --min-event-sync-interval=30s
```

- [ ] **Step 3: Create the kustomization**

`infrastructure/gcp-0/external-dns/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kube-system

# The chart release by file -- the base DIRECTORY is AWS-shaped in its values
# (provider aws, two domain filters, an ECR registry), which the patch below
# replaces rather than augments for the fields it names.
resources:
  - ../../base/external-dns/helmrelease.yaml
  - workloadidentity.yaml

patches:
  - path: helmrelease.yaml
    target:
      group: helm.toolkit.fluxcd.io
      kind: HelmRelease
      name: external-dns
```

- [ ] **Step 4: Wire it into the cluster's infrastructure tree**

In `infrastructure/gcp-0/kustomization.yaml`, add `external-dns` to `resources`:

```yaml
resources:
  - computeclass
  - external-dns
```

external-dns joins the existing `infrastructure` Kustomization rather than getting its own: it degrades gracefully when there is nothing to watch, so it needs no ordering edge. Its claim does need Crossplane, which `infrastructure` already sequences behind.

- [ ] **Step 5: Validate, including that the AWS provider is gone**

```bash
./scripts/validate-manifests.sh 2>&1 | grep -E "RENDER:|Invalid:"
kustomize build infrastructure/gcp-0 --load-restrictor=LoadRestrictionsNone \
  | grep -A 3 "provider:"
```

Expected: `Invalid: 0, Skipped: 0`, and the rendered values show `provider: {name: google}` with **no** `aws:` block and no `zoneType`.

Confirm the claim validates against the real XRD (this is what `skipMissingSchemas: false` buys):

```bash
grep -rn "GCPWorkloadIdentity" .bundle/ | head -2
```

Expected: a match — the claim is in the bundle, which means it passed gate 1 against the schema fetched from `crossplane-configuration-gcp:v0.2.0`, not skipped.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/gcp-0/
git commit -m "feat(gcp): external-dns on the google provider via GCPWorkloadIdentity"
```

---

### Task 6: Live verification, then teardown

Everything above is unverified configuration. This task is where it becomes true or false. **The standing rule is that no test infrastructure survives this task.**

**Files:**
- Create: `docs/superpowers/specs/2026-08-25-gcp-private-ingress-verification.md`

**Interfaces:**
- Consumes: every prior task.
- Produces: a verification document recording each success criterion with its command output.

- [ ] **Step 1: Deploy**

```bash
git push -u origin "$(git branch --show-current)"
cd opentofu/gcp/network && TM_GCP_ENABLED=true terramate script run \
  --disable-check-git-remote --disable-check-git-untracked --disable-check-git-uncommitted deploy
cd ../gke && TM_GCP_ENABLED=true TF_VAR_flux_git_ref="refs/heads/$(git branch --show-current)" \
  terramate script run --disable-check-git-remote --disable-check-git-untracked \
  --disable-check-git-uncommitted deploy
cd ../openbao/cluster && TM_GCP_ENABLED=true terramate script run \
  --disable-check-git-remote --disable-check-git-untracked --disable-check-git-uncommitted deploy
```

Then initialise OpenBao and deploy the management stack (the CA file is needed because OpenBao's certificate comes from the offline root):

```bash
cd ../management
export VAULT_CACERT="$PWD/.tls/ca.pem"
bash ../../../../scripts/openbao-config.sh ca --cloud gcp --project ogenki-435905 \
  --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem
bash ../../../../scripts/openbao-config.sh init --cloud gcp --project ogenki-435905 \
  --url https://bao.priv.gcp.ogenki.io:8200 \
  --root-token-secret-name openbao-priv-gcp-root-token \
  --recovery-keys-secret-name openbao-priv-gcp-recovery-keys
TM_GCP_ENABLED=true terramate script run --disable-check-git-remote \
  --disable-check-git-untracked --disable-check-git-uncommitted deploy
```

**Read the logs, not the exit codes.** Background and wrapped commands in this repository have reported success over real failures repeatedly.

- [ ] **Step 2: Wait for Flux and record criteria 1–3**

```bash
gcloud container clusters get-credentials gcp-0 --zone europe-west4-a --project ogenki-435905
kubectl wait --for=condition=Ready kustomization/infrastructure-gapi -n flux-system --timeout=900s
kubectl get gateway -n infrastructure
tailscale status | grep -E "gateway-(general|admin)-priv-gcp-0"
kubectl get certificate -n infrastructure private-gateway-certificate
```

Expected: both Gateways `PROGRAMMED=True` with a `100.x.y.z` address; both devices in `tailscale status`; the Certificate `READY=True`.

Then prove the certificate came from the right issuer:

```bash
kubectl get secret private-gateway-tls -n infrastructure \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject
```

Expected: `issuer=CN=Ogenki GCP Intermediate CA`, subject CN `*.priv.gcp.ogenki.io`.

- [ ] **Step 3: Criterion 4 — a real route, served over the tailnet**

```bash
kubectl create deployment probe --image=nginx:alpine -n apps
kubectl expose deployment probe --port=80 -n apps
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: probe
  namespace: apps
spec:
  parentRefs:
    - name: platform-tailscale-general
      namespace: infrastructure
  hostnames:
    - probe.priv.gcp.ogenki.io
  rules:
    - backendRefs:
        - name: probe
          port: 80
EOF
kubectl wait --for=condition=Accepted httproute/probe -n apps --timeout=120s
```

From a tailnet device:

```bash
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' \
  --cacert opentofu/gcp/openbao/management/.tls/ca.pem \
  https://probe.priv.gcp.ogenki.io/
```

Expected: `200 0` — HTTP 200 **and** `ssl_verify_result` 0, meaning the chain validated against the offline root. A 200 with a non-zero verify result means TLS was not actually trusted.

- [ ] **Step 4: Criteria 5–6 — the DNS record and its pruning**

```bash
gcloud dns record-sets list --zone=priv-gcp-ogenki-io --project=ogenki-435905 \
  --filter="name~probe" --format="value(name,type,rrdatas)"
```

Expected: an `A` record for `probe.priv.gcp.ogenki.io.` plus a `TXT` registry entry containing `external-dns/owner=gcp-0`.

Then delete the route and confirm `policy: sync` actually prunes:

```bash
kubectl delete httproute probe -n apps
sleep 120
gcloud dns record-sets list --zone=priv-gcp-ogenki-io --project=ogenki-435905 \
  --filter="name~probe" --format="value(name)"
```

Expected: empty. Creating records is the easy half; a registry that never prunes leaves a zone that slowly fills with dead names.

- [ ] **Step 5: Criterion 7 — the ACL split is real**

The two Gateways differ only by Tailscale tag, and the enforcement is outside Kubernetes.

Deploy a second probe on the ADMIN Gateway. It goes in `kube-system` because that
namespace is in the admin Gateway's `allowedRoutes` while `apps` is not — putting it in
`apps` gets the route rejected `NotAllowedByListeners`, which reads as a broken app rather
than a gateway ACL:

```bash
kubectl create deployment probe-admin --image=nginx:alpine -n kube-system
kubectl expose deployment probe-admin --port=80 -n kube-system
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: probe-admin
  namespace: kube-system
spec:
  parentRefs:
    - name: platform-tailscale-admin
      namespace: infrastructure
  hostnames:
    - probe-admin.priv.gcp.ogenki.io
  rules:
    - backendRefs:
        - name: probe-admin
          port: 80
EOF
kubectl wait --for=condition=Accepted httproute/probe-admin -n kube-system --timeout=120s
```

Then, from a tailnet device that is **not** in `group:admin`:

```bash
curl -sS -m 10 -o /dev/null -w 'general:%{http_code}\n' https://probe.priv.gcp.ogenki.io/ ; \
curl -sS -m 10 -o /dev/null -w 'admin:%{http_code}\n' https://probe-admin.priv.gcp.ogenki.io/ || echo "admin: unreachable (expected)"
```

Clean up both probes afterwards (`kubectl delete deployment,service,httproute probe-admin -n kube-system`).

Expected: the general hostname answers; the admin one times out or refuses. If both answer, `tagOwners` or the ACL is not doing what the design claims and that is a finding, not a nuisance.

If no non-admin device is available, record the criterion as **unverified** with that reason. Do not mark it passed by inspection.

- [ ] **Step 6: Write the verification document**

Create `docs/superpowers/specs/2026-08-25-gcp-private-ingress-verification.md` with one section per criterion, each quoting the command and its **actual** output. Record any criterion that could not be tested as unverified, with the reason. A verification document that reports only successes is not evidence.

- [ ] **Step 7: Tear down, and verify the teardown**

```bash
cd opentofu/gcp
TM_GCP_ENABLED=true TM_DESTROY_CONFIRMED=true terramate script run --reverse \
  --disable-check-git-remote --disable-check-git-untracked --disable-check-git-uncommitted destroy
```

Then confirm against the API rather than the exit code — a teardown in this repository has already reported success while destroying nothing:

```bash
gcloud compute instances list --project=ogenki-435905
gcloud container clusters list --project=ogenki-435905
gcloud compute forwarding-rules list --project=ogenki-435905
gcloud compute addresses list --project=ogenki-435905
gcloud compute disks list --project=ogenki-435905
gcloud dns record-sets list --zone=priv-gcp-ogenki-io --project=ogenki-435905 \
  --format="value(name,type)"
tailscale status | grep -c "gcp-0"
```

Expected: every list empty except the zone's own `NS` and `SOA` records, and 0 tailnet devices matching `gcp-0`.

Two known non-leaks: the **Cloud KMS key ring** survives by design (GCP cannot delete one), and **Secret Manager entries** for the ceremony material and the OAuth client persist deliberately. Two known real leaks to sweep by hand: unattached `pvc-*` **disks** from `flux-system/source-controller` (`gcloud compute disks delete <name> --zone=europe-west4-a`), and **stale Tailscale devices** — the operator's devices should deregister on teardown, but subnet routers from previous rebuilds have accumulated.

- [ ] **Step 8: Commit and open the PR**

```bash
git add docs/superpowers/specs/2026-08-25-gcp-private-ingress-verification.md
git commit -m "docs(gcp): verification of private ingress on gcp-0"
git push
gh pr create --title "feat(gcp): private ingress and external-dns on gcp-0" --base main
```

---

## Self-review

**Spec coverage.** Every section of the design maps to a task: tailscale-operator → 3; Gateway API layer → 4; external-dns + `GCPWorkloadIdentity` → 5; the hostname rename → 1; the Flux ordering → 3 and 4; the manual OAuth client and the accumulating-prerequisites risk → 2; all eight success criteria → 6. The design's excluded scope (public certificates, `ProxyGroup`) is restated as a Global Constraint so a task cannot quietly re-add it.

**Placeholders.** None. Every YAML and command is complete and runnable; no step says "configure appropriately".

**Consistency.** Names used across tasks match what defines them: Kustomizations `security-tailscale` (3) → depended on by `infrastructure-gapi` (4); `operator-oauth` is the chart's required Secret name in 2 and 3; `xplane-external-dns` in `kube-system` matches external-dns's chart ServiceAccount; `${cluster_name}` in 1 is the same variable `txtOwnerId` uses in 5; `tailscale-k8s-operator-oauth` is identical in Task 2's `gcloud`, its OpenTofu variable default, and Task 3's `remoteRef`.

**One gap accepted deliberately.** Task 2 restates the External Secrets Workload Identity subject that `opentofu/gcp/openbao/management/iam.tf` also builds. Factoring it out would mean a `terraform_remote_state` edge between two stacks that otherwise have none — a worse coupling than two duplicated strings. The comment in Task 2 Step 3 says so.
