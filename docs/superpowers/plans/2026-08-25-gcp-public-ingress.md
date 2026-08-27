# GCP Public Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `gcp-0` serves names under `cloud.ogenki.io` publicly, with a Let's Encrypt certificate obtained via DNS-01 against Route53 — using **no static AWS credentials**.

**Architecture:** An AWS IAM OIDC provider trusts the GKE cluster's token issuer, and one role — assumable only by two named ServiceAccounts — grants record changes on exactly one hosted zone. cert-manager and a second external-dns instance on `gcp-0` assume it with a projected ServiceAccount token. Public traffic terminates on a Cilium Gateway behind a GCP passthrough Network LB.

**Tech Stack:** OpenTofu (AWS provider), Terramate, cert-manager v1.21.1 (`route53.auth.kubernetes`), external-dns 1.21.1 (`provider: aws`), Cilium Gateway API, Flux.

**Spec:** [`docs/superpowers/specs/2026-08-25-gcp-public-ingress-design.md`](../specs/2026-08-25-gcp-public-ingress-design.md)

## Global Constraints

- **Clusters:** `aws-0`, `gcp-0`. Never write `mycluster-0`.
- **GCP:** project `ogenki-435905`, number `323586397743`, region `europe-west4`, zone `europe-west4-a`.
- **Public zone:** `cloud.ogenki.io`, Route53 hosted zone `Z002027037R5RFCG05YY6`. **Not managed by this repo** — a `data` lookup only. Never add a resource that creates, deletes or reconfigures it.
- **No static AWS credentials on GCP.** No access key, no Secret, nothing in GCP Secret Manager for this path. If a step seems to need one, stop and raise it.
- **IAM scope:** record changes on that one zone; no zone management. Consistent with the constitution's "no deletion permissions for stateful services".
- **One Gateway implementation.** `gatewayClassName: cilium`. Never introduce GKE's managed Gateway controller — ADR-0005's reasoning.
- **`allowedRoutes` ships with no application namespace.** Adding a public service must be a deliberate edit to the Gateway.
- **Evidence rule** (`.claude/rules/process.md`): no "done" without a fresh command run cited inline. `./scripts/validate-manifests.sh` must report `Invalid: 0, Skipped: 0`.
- **Standing user rule: never leave test infrastructure running.** Task 5 ends with a verified teardown.
- **This touches PRODUCTION DNS.** Every prior GCP task used throwaway resources; this writes records into the live `cloud.ogenki.io` zone that `aws-0` also uses. Never delete a record you did not create.

---

### Task 1: AWS IAM federation for GKE

**Files:**
- Create: `opentofu/shared/aws-gcp-federation/{backend,providers,versions,variables,main,outputs}.tf`
- Create: `opentofu/shared/aws-gcp-federation/{variables.tfvars,stack.tm.hcl,workflows.tm.hcl,.trivyignore.yaml}`
- Create: `website/content/docs/decisions/0019-cross-cloud-dns-federation.md`
- Modify: `website/content/docs/decisions/_index.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: output `route53_role_arn` — the ARN Tasks 2 and 4 put in `spec.acme.solvers[].dns01.route53.role` and external-dns's `AWS_ROLE_ARN`.

- [ ] **Step 1: Record the issuer URL as an assumption — the gate moved to Task 5**

This task originally verified GKE's OIDC discovery endpoint before writing any
IAM. It cannot: the endpoint is served per-cluster, and `gcp-0` does not exist
between deploys — this platform tears down after every verification. Confirmed
2026-08-25: `curl .../clusters/gcp-0/.well-known/openid-configuration` → HTTP 404
`Requested entity was not found`, and `gcloud container clusters list` → `[]`.

**Write the code on the documented assumption**, which `main.tf`'s own comment
already states: the issuer is a deterministic string built from project,
location and cluster name, and does not require the cluster to exist.

**The verification now lives in Task 5 Step 1**, positioned after the GKE deploy
and before the federation stack is applied. That ordering is not cosmetic:

`data "tls_certificate"` fetches the TLS certificate of the **host**
(`container.googleapis.com`), which succeeds for any URL on that host — including
one whose cluster path 404s. So a wrong project, location or cluster name
produces an `aws_iam_openid_connect_provider` that applies cleanly and points at
nothing. Nothing fails until cert-manager presents a token and gets an opaque
`AccessDenied` with no mention of the issuer.

Add that reasoning as a comment above `data "tls_certificate" "gke_oidc"` in
Step 4, so the next reader knows why the apply succeeding proves less than it
appears to.

- [ ] **Step 2: Create the stack scaffolding**

`opentofu/shared/aws-gcp-federation/backend.tf`:

```hcl
# S3, like opentofu/shared/tailscale: this stack's resources live in AWS and
# its state belongs with the other shared state. ADR-0018 moved GCP stacks to
# GCS because they manage GCP; this one manages AWS IAM.
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/shared/aws-gcp-federation/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
```

`opentofu/shared/aws-gcp-federation/providers.tf`:

```hcl
provider "aws" {
  region = var.aws_region
}
```

`opentofu/shared/aws-gcp-federation/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 3: Write the variables**

`opentofu/shared/aws-gcp-federation/variables.tf`:

```hcl
variable "aws_region" {
  description = "AWS region for the provider. Route53 is global, but the SDK needs a region to compute credential scope."
  type        = string
  default     = "eu-west-3"
}

variable "gcp_project_id" {
  description = "GCP project holding the GKE cluster whose tokens AWS will trust"
  type        = string
  default     = "ogenki-435905"
}

variable "gcp_cluster_location" {
  description = "GKE cluster location (zone). Part of the OIDC issuer URL."
  type        = string
  default     = "europe-west4-a"
}

variable "gcp_cluster_name" {
  description = "GKE cluster name. Part of the OIDC issuer URL, which is why renaming the cluster invalidates this federation -- see the note in main.tf."
  type        = string
  default     = "gcp-0"
}

variable "public_domain_name" {
  description = "Public zone the federated role may change records in. Looked up, never managed here."
  type        = string
  default     = "cloud.ogenki.io"
}

variable "trusted_service_accounts" {
  description = "Kubernetes ServiceAccounts allowed to assume the role, as `<namespace>/<name>`. Each becomes one `system:serviceaccount:<ns>:<sa>` subject in the trust policy. Keep this list minimal -- it is the entire membership of the cross-cloud trust."
  type        = list(string)
  default = [
    "security/cert-manager",
    "kube-system/external-dns-public",
  ]
}
```

`opentofu/shared/aws-gcp-federation/variables.tfvars`:

```hcl
# Everything is on its defaults in variables.tf, which carry the project's real
# values. Present and TRACKED because a stack whose tfvars is gitignored cannot
# be deployed from a clean checkout -- see the defect fixed in #1833.
gcp_project_id = "ogenki-435905"
```

- [ ] **Step 4: Write the IAM**

`opentofu/shared/aws-gcp-federation/main.tf`:

```hcl
# Cross-cloud identity federation: AWS trusts GKE-issued ServiceAccount tokens.
#
# This is the ONLY place in the platform where a workload authenticates to the
# other cloud, and it does so with NO material at rest -- no access key, no
# secret in GCP Secret Manager, nothing to rotate. cert-manager and external-dns
# on gcp-0 present a projected ServiceAccount token; AWS STS validates it against
# the OIDC provider below and returns short-lived credentials.
#
# WHY THIS LIVES IN shared/ RATHER THAN aws/: these are AWS resources that exist
# solely to couple the two clouds, which is what shared/ already means here --
# opentofu/shared/tailscale holds the tailnet for the same reason. Filing it
# under aws/ would present a federation point as AWS's own concern and hide it
# from anyone reading the GCP tree.

locals {
  # Deterministic from project/location/name -- it does NOT require the cluster
  # to exist, which is what keeps this stack independent of the GCP stacks and
  # free of a cross-cloud remote-state read.
  #
  # It also means a cluster REBUILD does not break the federation: same project,
  # location and name produce the same issuer, and AWS re-fetches the JWKS from
  # the discovery endpoint, so rotated signing keys are handled. What DOES break
  # it is renaming the cluster, moving it to another zone, or moving projects --
  # all of which change this URL and require the provider to be recreated.
  oidc_issuer = "https://container.googleapis.com/v1/projects/${var.gcp_project_id}/locations/${var.gcp_cluster_location}/clusters/${var.gcp_cluster_name}"
}

# LOOKUP, never a resource. The zone is not managed by this repository -- see
# opentofu/aws/eks/configure/data.tf, which reads it the same way.
data "aws_route53_zone" "public" {
  name         = var.public_domain_name
  private_zone = false
}

data "tls_certificate" "gke_oidc" {
  url = "${local.oidc_issuer}/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "gke" {
  url             = local.oidc_issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.gke_oidc.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gke.arn]
    }

    # The audience cert-manager requests by default, and what external-dns is
    # configured with. Without this the role would accept a token minted for
    # ANY audience, which is the classic confused-deputy shape.
    condition {
      test     = "StringEquals"
      variable = "${replace(local.oidc_issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The membership of the trust: only these ServiceAccounts, by exact subject.
    condition {
      test     = "StringEquals"
      variable = "${replace(local.oidc_issuer, "https://", "")}:sub"
      values   = [for sa in var.trusted_service_accounts : "system:serviceaccount:${split("/", sa)[0]}:${split("/", sa)[1]}"]
    }
  }
}

resource "aws_iam_role" "route53" {
  name               = "gcp-0-route53-dns"
  description        = "Assumed by cert-manager and external-dns on GKE cluster gcp-0 to manage records in ${var.public_domain_name}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "route53" {
  # Record changes in ONE zone. Not zone creation, not deletion, not
  # reconfiguration -- the zone is a stateful shared resource this repo does not
  # own, and the constitution forbids deletion permissions on those.
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.public.zone_id}"]
  }

  # GetChange is how ACME polls for propagation. It takes a change ID, not a
  # zone, so it cannot be scoped further -- this is an AWS API limitation, not
  # an oversight.
  statement {
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["*"]
  }

  # external-dns resolves a domain filter to a zone ID at startup. Read-only,
  # and unavoidable for the zone-discovery path.
  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZonesByName", "route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "route53" {
  name   = "route53-records"
  role   = aws_iam_role.route53.id
  policy = data.aws_iam_policy_document.route53.json
}
```

Add `tls` to `required_providers` in `versions.tf`:

```hcl
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
```

`opentofu/shared/aws-gcp-federation/outputs.tf`:

```hcl
output "route53_role_arn" {
  description = "ARN the ClusterIssuer's route53 solver and external-dns-public assume"
  value       = aws_iam_role.route53.arn
}

output "oidc_issuer" {
  description = "The GKE issuer AWS trusts. Renaming or moving the cluster changes this and invalidates the provider."
  value       = local.oidc_issuer
}

output "public_zone_id" {
  description = "Hosted zone the role may change records in"
  value       = data.aws_route53_zone.public.zone_id
}
```

- [ ] **Step 5: Terramate wiring**

`opentofu/shared/aws-gcp-federation/stack.tm.hcl`:

```hcl
stack {
  name        = "Shared AWS-GCP DNS federation"
  description = "AWS IAM OIDC provider and role letting GKE workloads manage records in the public Route53 zone. Owned by neither cloud"
  id          = "b4e6a1c2-9f83-4d17-8a52-3c7e0d914f6b"

  # No `after`. The OIDC issuer URL is derived from project/location/name, not
  # read from the cluster, so this stack does not need GKE to exist -- which is
  # deliberate: an ordering edge here would make an AWS stack depend on a GCP one.

  tags = [
    "shared",
    "aws",
    "dns",
  ]
}
```

`opentofu/shared/aws-gcp-federation/workflows.tm.hcl` — copy the shape of `opentofu/shared/tailscale/workflows.tm.hcl` verbatim, changing only the stack name in each script's `name`/`description`. Read that file first; do not invent a different shape.

- [ ] **Step 6: Write ADR-0019**

Create `website/content/docs/decisions/0019-cross-cloud-dns-federation.md` following the shape of `0018-per-cloud-opentofu-state.md`: front matter (`title`, `linkTitle: 0019 · Cross-cloud DNS federation`, `weight: 190`, `description`, `lastVerified: 2026-08-25`), Status/Date/Deciders, Context, Decision Drivers, Considered Options, Decision Outcome, Consequences, Implementation Notes, References.

The four options and their rationale are already written in the design's *Options considered* and the Tailscale Funnel paragraph — carry the reasoning across, do not re-derive it. The ADR exists because the repo requires one when a technology choice has a named rejected alternative, and this has three.

Add a row to `website/content/docs/decisions/_index.md` immediately after 0018:

```markdown
| [0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}}) | Cross-cloud DNS federation — GKE workloads assume an AWS role for Route53 | Accepted | 2026-08-25 |
```

- [ ] **Step 7: Validate**

```bash
cd opentofu/shared/aws-gcp-federation
tofu fmt && tofu init -backend=false -input=false >/dev/null && tofu validate
trivy config --exit-code=1 --ignorefile=../../../.trivyignore.yaml .
cd ../../.. && ./scripts/validate-links.sh
```

Expected: `Success! The configuration is valid`, trivy exit 0, links exit 0.

- [ ] **Step 8: Commit**

```bash
git add opentofu/shared/aws-gcp-federation/ website/content/docs/decisions/
git commit -m "feat(shared): AWS IAM federation for GKE workloads to manage public DNS"
```

---

### Task 2: Federated ClusterIssuer and public certificate

**Files:**
- Create: `security/gcp-0/cert-manager-public/{kustomization,letsencrypt-clusterissuer,rbac}.yaml`
- Create: `clusters/gcp-0/security/security-public-certs.yaml`

**Interfaces:**
- Consumes: `route53_role_arn` from Task 1; the `cert-manager` ServiceAccount in `security` (installed by the existing `security` Kustomization).
- Produces: ClusterIssuer `letsencrypt-prod`, which Task 3's Certificate references.

- [ ] **Step 1: RBAC for token creation**

cert-manager must be allowed to mint a bound token for its own ServiceAccount. Without this the solver fails with a `serviceaccounts/token is forbidden` error that does not mention AWS at all.

`security/gcp-0/cert-manager-public/rbac.yaml`:

```yaml
# cert-manager requests a PROJECTED ServiceAccount token for itself and presents
# it to AWS STS. Creating that token is a privileged verb it does not have by
# default, so it must be granted explicitly -- narrowly, on one ServiceAccount.
#
# Symptom when missing: the Certificate stays pending and cert-manager logs
# `serviceaccounts "cert-manager" is forbidden: ... cannot create resource
# "serviceaccounts/token"`, which says nothing about Route53 and sends you
# looking in the wrong cloud.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cert-manager-token-creator
  namespace: security
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    resourceNames: ["cert-manager"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cert-manager-token-creator
  namespace: security
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cert-manager-token-creator
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: security
```

- [ ] **Step 2: The ClusterIssuer**

`security/gcp-0/cert-manager-public/letsencrypt-clusterissuer.yaml`:

```yaml
# Public certificates for gcp-0, solved against Route53 with NO static AWS
# credentials.
#
# `auth.kubernetes` makes cert-manager assume the role using a bound
# ServiceAccount token as the web identity (AssumeRoleWithWebIdentity). There is
# no access key here, no secretRef, and nothing in GCP Secret Manager -- the
# token IS the credential, and AWS validates it against the OIDC provider in
# opentofu/shared/aws-gcp-federation.
#
# The AWS cluster's copy of this issuer (security/base/cert-manager/
# le-clusterissuer-prod.yaml) uses ambient EKS Pod Identity credentials instead,
# which is why this is a GCP-specific file rather than a shared one.
#
# hostedZoneID is pinned so the solver does not need to list zones to find the
# right one, and cannot wander into another.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: smainklh@gmail.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: ogenki-issuer-account-key
    solvers:
      - selector:
          dnsZones:
            - "${public_domain_name}"
        dns01:
          route53:
            # NOT ${region}: on gcp-0 that key holds a GCP region
            # (europe-west4), and cert-manager feeds this straight into the AWS
            # SDK's shared config -- which backs the STS client doing the
            # AssumeRoleWithWebIdentity. A GCP value here resolves a regional STS
            # endpoint that does not exist, and the token exchange fails before
            # Route53 is reached. CI cannot catch it: render-bundle.py's fixture
            # sets `region` to an AWS region, so the rendered bundle looks fine.
            region: ${route53_region}
            hostedZoneID: ${route53_public_zone_id}
            role: ${route53_role_arn}
            auth:
              kubernetes:
                serviceAccountRef:
                  name: cert-manager
```

- [ ] **Step 3: The kustomization**

`security/gcp-0/cert-manager-public/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: security

# Separate from security/gcp-0/openbao/, which holds the PRIVATE issuer. Two
# issuers, two trust chains, two failure modes: the openbao ClusterIssuer signs
# *.priv.gcp.ogenki.io from an offline root, this one gets publicly-trusted
# certificates from Let's Encrypt. Keeping them apart means a Route53 outage
# cannot make the private path look broken.
resources:
  - rbac.yaml
  - letsencrypt-clusterissuer.yaml
```

- [ ] **Step 4: The Flux Kustomization**

`clusters/gcp-0/security/security-public-certs.yaml`:

```yaml
# The public certificate issuer.
#
# dependsOn security (not security-openbao): this needs cert-manager RUNNING,
# which security's healthChecks already gate on. It has no relationship to the
# private PKI -- deliberately, since the two issuers exist to fail independently.
#
# No healthCheck on the ClusterIssuer. cert-manager marks an ACME issuer Ready
# only after it has registered an account with Let's Encrypt, which is a live
# network call to a rate-limited third party. Gating a Kustomization on that
# would make an unrelated LE outage look like a GitOps failure. Task 3's
# Certificate is where issuance is actually proven.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: security-public-certs
  namespace: flux-system
spec:
  prune: true
  interval: 4m0s
  retryInterval: 30s
  timeout: 8m0s
  sourceRef:
    kind: ExternalArtifact
    name: security-artifact
  path: ./security/gcp-0/cert-manager-public
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: gke-gcp-0-vars
  dependsOn:
    - name: security
```

- [ ] **Step 5: Add the new variables to the GCP vars ConfigMap**

The manifests above reference `${public_domain_name}`, `${route53_public_zone_id}` and `${route53_role_arn}`, none of which exist in `gke-gcp-0-vars` today. In `opentofu/gcp/gke/configure/kubernetes.tf`, add them to the ConfigMap's `data` block:

```hcl
      # Public DNS, for the federated Route53 path (workstream 12). These are
      # AWS values in a GCP ConfigMap on purpose: cloud.ogenki.io is a single
      # cloud-agnostic public zone that BOTH clusters write to, which is what
      # ADR-0017 and ADR-0019 decided.
      public_domain_name     = var.public_domain_name
      route53_public_zone_id = var.route53_public_zone_id
      route53_role_arn       = var.route53_role_arn
```

Add the three matching variables to `opentofu/gcp/gke/configure/variables.tf` (no defaults for `route53_role_arn` and `route53_public_zone_id` — they come from Task 1's outputs and a wrong value fails at issuance with a confusing AWS error), and set them in `opentofu/gcp/gke/configure/variables.tfvars`.

**The new substitution wiring is exactly what `scripts/flux-schema/check-substitution.py` guards.** It will fail the build if a Kustomization renders these without `postBuild` — which is the point.

Also add the three to `FIXTURE_VARS` in `scripts/flux-schema/render-bundle.py`, or CI renders literal `${...}` into the bundle:

```python
    "public_domain_name": "cluster.local",
    "route53_public_zone_id": "Z0123456789",
    "route53_role_arn": "arn:aws:iam::123456789012:role/gcp-0-route53-dns",
```

`public_domain_name` and `route53_public_zone_id` already exist in `FIXTURE_VARS`; add only what is missing.

- [ ] **Step 6: Validate**

```bash
./scripts/validate-manifests.sh 2>&1 | grep -E "==> \[|Invalid:"
kustomize build security/gcp-0/cert-manager-public --load-restrictor=LoadRestrictionsNone \
  | grep -E "^kind:|role:|serviceAccountRef"
```

Expected: `Invalid: 0, Skipped: 0`; the build shows a Role, a RoleBinding and a ClusterIssuer, with `role:` and `serviceAccountRef` present and **no** `accessKeyID` or `secretAccessKeySecretRef` anywhere.

- [ ] **Step 7: Commit**

```bash
git add security/gcp-0/cert-manager-public/ clusters/gcp-0/security/security-public-certs.yaml \
        opentofu/gcp/gke/configure/ scripts/flux-schema/render-bundle.py
git commit -m "feat(gcp): federated letsencrypt-prod ClusterIssuer for gcp-0"
```

---

### Task 3: Public Gateway

**Files:**
- Create: `infrastructure/gcp-0/gapi-public/{kustomization,platform-public-gateway,certificate}.yaml`
- Create: `clusters/gcp-0/infrastructure/gapi-public.yaml`

**Interfaces:**
- Consumes: ClusterIssuer `letsencrypt-prod` (Task 2).
- Produces: Gateway `platform-public` in `infrastructure`, labelled `external-dns: enabled`, which Task 4's external-dns watches.

- [ ] **Step 1: The Gateway**

`infrastructure/gcp-0/gapi-public/platform-public-gateway.yaml`:

```yaml
# The one publicly-reachable entry point on gcp-0.
#
# NOT reused from infrastructure/base/gapi/platform-public-gateway.yaml: that
# file carries service.beta.kubernetes.io/aws-load-balancer-* annotations and an
# allowedRoutes list naming `runlore`, which runs on aws-0. GCP gets its own.
#
# Unlike the private Gateways -- which use loadBalancerClass: tailscale and cost
# no cloud load-balancer charges -- this provisions a real GCP forwarding rule
# and IS BILLABLE. That is inherent to being publicly reachable, and it is why
# teardown checks for forwarding rules and reserved addresses specifically.
#
# allowedRoutes lists NO application namespace. Adding a public service is a
# deliberate edit to this file, not a side effect of deploying something -- the
# same posture as the AWS public Gateway, whose single consumer matches exactly
# one path and method.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-public
  labels:
    external-dns: enabled  # required by external-dns's --gateway-label-filter
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      hostname: "probe.${public_domain_name}"   # per-hostname, never a wildcard
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchExpressions:
              - key: kubernetes.io/metadata.name
                operator: In
                # Intentionally empty of application namespaces. A public
                # service is added here explicitly, with review.
                values:
                  - infrastructure
      tls:
        mode: Terminate
        certificateRefs:
          - name: platform-public-tls
```

- [ ] **Step 2: The certificate**

> **Superseded 2026-08-25.** The repo no longer ships a standalone Certificate here. Wildcards were
> dropped — one key covering every service under the subdomain is too much blast radius for one
> leaked Secret — so the Gateway carries `cert-manager.io/cluster-issuer` plus per-listener
> `certificateRefs`, and cert-manager's gateway-shim issues one certificate per hostname. The block
> below is kept for the `duration`/`renewBefore` values, which moved to the Gateway's
> `cert-manager.io/duration` and `cert-manager.io/renew-before` annotations.

`infrastructure/gcp-0/gapi-public/certificate.yaml`:

```yaml
# Wildcard for the public zone, from Let's Encrypt via the federated Route53
# solver. A wildcard needs DNS-01 -- HTTP-01 cannot satisfy it -- which is the
# whole reason this workstream needed a DNS story at all.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: platform-public-certificate
spec:
  secretName: platform-public-tls
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  commonName: "probe.${public_domain_name}"
  dnsNames:
    - "probe.${public_domain_name}"
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
    group: cert-manager.io
```

- [ ] **Step 3: The kustomization**

`infrastructure/gcp-0/gapi-public/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: infrastructure

# Separate from infrastructure/gcp-0/gapi/, which holds the PRIVATE Tailscale
# gateways. Different GatewayClass (cilium vs cilium-tailscale), different trust
# chain, different exposure, different failure modes -- and a public Gateway is
# the one thing on this cluster an attacker can reach without the tailnet.
resources:
  - platform-public-gateway.yaml
  - certificate.yaml
```

- [ ] **Step 4: The Flux Kustomization**

`clusters/gcp-0/infrastructure/gapi-public.yaml`:

```yaml
# Public Gateway and its Let's Encrypt certificate.
#
# dependsOn security-public-certs, because the Certificate here names the
# ClusterIssuer that Kustomization creates.
#
# BOTH healthChecks and healthCheckExprs are required -- they are not
# alternatives. The bare `healthChecks` entry SELECTS the Gateway but asserts
# only that it EXISTS: Gateway API v1 has no Ready condition and no top-level
# observedGeneration, so kstatus reports Current the moment it is created.
# `healthCheckExprs` below is what actually WAITS, on the `Programmed` condition
# Cilium sets once the Gateway is genuinely serving. Flux evaluates those
# expressions only for resources named in `healthChecks`, so dropping the entry
# would leave them never evaluated and this Kustomization health-checking
# nothing at all -- worse than the workstream 10 defect it guards against, and
# invisible, because the 15m timeout would silently stop meaning anything.
# See clusters/gcp-0/infrastructure/gapi.yaml for the same form.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-gapi-public
  namespace: flux-system
spec:
  prune: true
  interval: 4m0s
  retryInterval: 30s
  timeout: 15m0s
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  path: ./infrastructure/gcp-0/gapi-public
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: gke-gcp-0-vars
  dependsOn:
    - name: security-public-certs
  healthChecks:
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      name: platform-public
      namespace: infrastructure
  healthCheckExprs:
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      failed: status.conditions.filter(c, c.type == 'Programmed').all(c, c.status == 'False')
      current: status.conditions.filter(c, c.type == 'Programmed').all(c, c.status == 'True')
```

`timeout: 15m0s` is longer than the private Gateway's 10m on purpose: a first ACME issuance includes account registration and DNS-01 propagation, which routinely takes several minutes.

- [ ] **Step 5: Validate**

```bash
./scripts/validate-manifests.sh 2>&1 | grep -E "==> \[|Invalid:"
kustomize build infrastructure/gcp-0/gapi-public --load-restrictor=LoadRestrictionsNone \
  | grep -cE "aws-load-balancer|platform-tailscale"
```

Expected: `Invalid: 0, Skipped: 0`, and the grep returns `0` — no AWS annotation and no confusion with the private gateways.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/gcp-0/gapi-public/ clusters/gcp-0/infrastructure/gapi-public.yaml
git commit -m "feat(gcp): public Gateway and Let's Encrypt wildcard certificate"
```

---

### Task 4: external-dns for the public zone

**Files:**
- Create: `infrastructure/gcp-0/external-dns-public/{kustomization,helmrelease,serviceaccount,rbac}.yaml`
- Modify: `infrastructure/gcp-0/kustomization.yaml`

**Interfaces:**
- Consumes: `route53_role_arn` (Task 1); the Gateway from Task 3 as its watch target.
- Produces: A and TXT records under `cloud.ogenki.io` owned by `gcp-0-public`.

- [ ] **Step 1: Why a second instance, in the kustomization comment**

`infrastructure/gcp-0/external-dns-public/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kube-system

# A SECOND external-dns on this cluster, and it has to be.
#
# external-dns takes ONE --provider per instance. The existing deployment
# (infrastructure/gcp-0/external-dns/) is provider: google, filtered to the
# private Cloud DNS zone; it cannot also write Route53. So the public zone needs
# its own controller, its own ServiceAccount and its own identity.
#
# The two must never fight over a record. They are separated three ways:
# different providers, non-overlapping domainFilters (private vs public zone),
# and distinct txtOwnerId. aws-0's external-dns writes this same public zone, so
# its owner ID must differ too -- hence `gcp-0-public` rather than ${cluster_name},
# which would collide with nothing today but reads as if it might.
resources:
  - serviceaccount.yaml
  - rbac.yaml
  - helmrelease.yaml
```

- [ ] **Step 2: ServiceAccount and RBAC**

`infrastructure/gcp-0/external-dns-public/serviceaccount.yaml`:

```yaml
# Named external-dns-public, distinct from the private instance's
# `external-dns`. The name is load-bearing: it appears verbatim in the AWS trust
# policy's `sub` condition (opentofu/shared/aws-gcp-federation), so renaming it
# here without renaming it there produces a role that silently refuses the token.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns-public
  namespace: kube-system
```

`infrastructure/gcp-0/external-dns-public/rbac.yaml`:

```yaml
# The chart normally creates these; it is disabled below because the chart's
# ServiceAccount would not carry the projected-token volume this needs.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns-public
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "pods", "nodes"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways", "httproutes", "grpcroutes", "tlsroutes", "tcproutes", "udproutes"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-public
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns-public
subjects:
  - kind: ServiceAccount
    name: external-dns-public
    namespace: kube-system
```

- [ ] **Step 3: The HelmRelease**

`infrastructure/gcp-0/external-dns-public/helmrelease.yaml`:

```yaml
# external-dns for the PUBLIC zone, authenticating to AWS with a projected
# ServiceAccount token -- no access key anywhere.
#
# The AWS SDK's web-identity path is driven by three things: AWS_ROLE_ARN,
# AWS_WEB_IDENTITY_TOKEN_FILE, and a token actually present at that path. The
# chart does not project a token for an arbitrary audience, so the volume is
# declared explicitly below. `audience: sts.amazonaws.com` MUST match the
# client_id_list on the OIDC provider and the `aud` condition in the trust
# policy; a mismatch fails with AccessDenied and no explanation.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: external-dns-public
  namespace: kube-system
spec:
  releaseName: external-dns-public
  driftDetection:
    mode: enabled
  chart:
    spec:
      chart: external-dns
      sourceRef:
        kind: HelmRepository
        name: external-dns
        namespace: kube-system
      version: "1.21.1"
  interval: 10m0s
  install:
    remediation:
      retries: 3
  values:
    fullnameOverride: external-dns-public

    serviceAccount:
      create: false
      name: external-dns-public

    rbac:
      create: false

    provider:
      name: aws

    domainFilters:
      - ${public_domain_name}

    txtOwnerId: gcp-0-public

    policy: sync
    logFormat: json
    logLevel: info

    sources:
      - gateway-httproute

    extraArgs:
      - --gateway-namespace=infrastructure
      - --gateway-label-filter=external-dns=enabled
      - --min-event-sync-interval=30s
      - --aws-zone-type=public

    env:
      - name: AWS_REGION
        # NOT ${region} -- see Task 2. That key holds gcp-0's GCP region.
        value: ${route53_region}
      - name: AWS_ROLE_ARN
        value: ${route53_role_arn}
      - name: AWS_WEB_IDENTITY_TOKEN_FILE
        value: /var/run/secrets/aws/token

    extraVolumes:
      - name: aws-token
        projected:
          sources:
            - serviceAccountToken:
                path: token
                expirationSeconds: 3600
                audience: sts.amazonaws.com

    extraVolumeMounts:
      - name: aws-token
        mountPath: /var/run/secrets/aws
        readOnly: true

    resources:
      limits:
        memory: 150Mi
      requests:
        cpu: 100m
        memory: 150Mi
```

`AWS_REGION` uses `${route53_region}`, the dedicated AWS-region key Task 2's fix added — **not** `${region}`, which on this cluster holds `europe-west4`.

An earlier draft of this plan used `${region}` here and defended it: Route53 is global, the SDK only needs a region for credential scope, so any valid region works. That reasoning is wrong in the same way it was wrong in Task 2. The region does not only scope Route53 — it configures the shared AWS SDK config, which is what resolves the **STS** endpoint for the `AssumeRoleWithWebIdentity` this whole design depends on. A GCP region there points the token exchange at a host that does not exist, and it fails before Route53 is reached. Neither CI gate can catch it, because the render fixture is AWS-shaped for both clusters.

- [ ] **Step 4: Wire it in**

Add `external-dns-public` to `resources` in `infrastructure/gcp-0/kustomization.yaml`, alongside the existing `computeclass` and `external-dns`.

- [ ] **Step 5: Validate**

```bash
./scripts/validate-manifests.sh 2>&1 | grep -E "==> \[|Invalid:"
kustomize build infrastructure/gcp-0 --load-restrictor=LoadRestrictionsNone \
  | grep -E "txtOwnerId|AWS_ROLE_ARN|provider:" -A1 | head -20
```

Expected: `Invalid: 0, Skipped: 0`, and **two** external-dns releases render — one `provider: google` with the private domain filter, one `provider: aws` with the public one and `txtOwnerId: gcp-0-public`.

Note that Task 4 is also the first real exercise of the per-overlay chart rendering fixed in #1835: before that change, two HelmReleases resolving to `kube-system/external-dns*` in one overlay would have collided.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/gcp-0/external-dns-public/ infrastructure/gcp-0/kustomization.yaml
git commit -m "feat(gcp): external-dns for the public Route53 zone via federated identity"
```

---

### Task 5: Live verification, then teardown

**Files:**
- Create: `docs/superpowers/specs/2026-08-25-gcp-public-ingress-verification.md`
- Modify: `docs/gcp-bootstrap.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a verification document with each success criterion and its command output.

**This task writes to PRODUCTION DNS.** `cloud.ogenki.io` is a live zone that `aws-0` also uses. Never delete a record you did not create, and check `external-dns/owner` on the TXT registry before removing anything.

- [ ] **Step 1: Deploy, with the OIDC gate in the middle**

Order matters here. The federation stack is applied **after** the cluster exists
and **after** its discovery endpoint is verified — see Task 1 Step 1 for why an
unverified issuer produces an OIDC provider that applies cleanly and works never.

```bash
git push -u origin "$(git branch --show-current)"

# 1. GCP network
cd opentofu/gcp/network && TM_GCP_ENABLED=true terramate script run \
  --disable-check-git-remote --disable-check-git-untracked --disable-check-git-uncommitted deploy

# 2. GKE, tracking this branch
cd ../gke && TM_GCP_ENABLED=true TF_VAR_flux_git_ref="refs/heads/$(git branch --show-current)" \
  terramate script run --disable-check-git-remote --disable-check-git-untracked \
  --disable-check-git-uncommitted deploy
```

**Now the gate.** Do not proceed until this passes:

```bash
ISSUER="https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0"
curl -sS "${ISSUER}/.well-known/openid-configuration" | jq -r '.issuer, .jwks_uri'
```

Expected: `issuer` echoes `$ISSUER` **exactly**, and `jwks_uri` is an https URL.

A 404, or an `issuer` that differs by even a character, means the trust policy
will never match a real token. **Stop and report** — do not apply the federation
stack, and do not "fix" it by editing the trust policy to match whatever came
back without understanding why it differs.

```bash
# 3. Only now, the federation
cd ../../shared/aws-gcp-federation && terramate script run \
  --disable-check-git-remote --disable-check-git-untracked --disable-check-git-uncommitted deploy
tofu output -raw route53_role_arn
```

Confirm that ARN equals `arn:aws:iam::396740644681:role/gcp-0-route53-dns`, the
value Tasks 2 and 4 hardcode. If it differs, the manifests point at a role that
does not exist and issuance will fail with `AccessDenied`.

Credentials needed in the shell, both of which have cost a wasted round trip
before: AWS (`aws sts get-caller-identity` must succeed) and
`TF_VAR_tailscale_api_key`.

The OpenBao stacks are **not** required — nothing here uses the private PKI.
Skip them to save time and cost.

**Read the logs, not the exit codes.** Background and wrapped commands in this
repository have reported success over real failures repeatedly.

- [ ] **Step 2: Criteria 1 and 3 — the trust boundary**

```bash
# 3. No AWS credential material anywhere on the cluster.
kubectl get secrets -A -o json | jq -r '.items[] | select(
  (.data // {}) | keys[] | test("aws.?access.?key|aws.?secret";"i")) | "\(.metadata.namespace)/\(.metadata.name)"'
```

Expected: no output.

```bash
# 1. The role refuses a token from a ServiceAccount that is not on the list.
kubectl create serviceaccount intruder -n default
TOKEN=$(kubectl create token intruder -n default --audience sts.amazonaws.com --duration 600s)
aws sts assume-role-with-web-identity \
  --role-arn "$(cd opentofu/shared/aws-gcp-federation && tofu output -raw route53_role_arn)" \
  --role-session-name intruder --web-identity-token "$TOKEN" 2>&1 | tail -3
kubectl delete serviceaccount intruder -n default
```

Expected: `AccessDenied` / `Not authorized to perform sts:AssumeRoleWithWebIdentity`. A success here means the `sub` condition is wrong and the trust is open to every ServiceAccount in the cluster — **stop and fix before going further**.

- [ ] **Step 3: Criteria 2 and 4 — issuance and the Gateway**

```bash
kubectl wait --for=condition=Ready kustomization/infrastructure-gapi-public -n flux-system --timeout=900s
kubectl get certificate -n infrastructure platform-public-certificate
kubectl get gateway -n infrastructure platform-public
```

Expected: Certificate `READY=True`; Gateway `PROGRAMMED=True` with a public IPv4 address.

Prove the chain is *publicly* trusted, not the platform's private root:

```bash
kubectl get secret platform-public-tls -n infrastructure \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject
```

Expected: issuer is a Let's Encrypt intermediate (`CN=R1x`/`E1x`, `O=Let's Encrypt`), **not** `CN=Ogenki`.

If the Certificate is stuck, the two most likely causes and how to tell them apart:

```bash
kubectl describe certificaterequest -n infrastructure | tail -20   # ACME/DNS-01 detail
kubectl logs -n security deploy/cert-manager --tail=40 | grep -iE "assume|route53|forbidden"
```

`serviceaccounts/token is forbidden` means Task 2's RBAC is missing. `AccessDenied` from STS means the trust policy's `sub` or `aud` does not match.

- [ ] **Step 4: Criterion 5 — the public record**

```bash
kubectl create deployment probe --image=nginx:alpine -n infrastructure
kubectl expose deployment probe --port=80 -n infrastructure
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: probe-public
  namespace: infrastructure
spec:
  parentRefs:
    - name: platform-public
      namespace: infrastructure
  hostnames:
    - probe.gcp.cloud.ogenki.io
  rules:
    - backendRefs:
        - name: probe
          port: 80
EOF
kubectl get httproute probe-public -n infrastructure \
  -o jsonpath='{range .status.parents[*]}{range .conditions[*]}{.type}={.status} {end}{end}'
```

Expected: `Accepted=True ResolvedRefs=True`. Do **not** use `kubectl wait --for=condition=Accepted` on an HTTPRoute — it times out on a healthy route, because the conditions live under `status.parents[]`, not at the top level.

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z002027037R5RFCG05YY6 \
  --query "ResourceRecordSets[?contains(Name,'probe.gcp')]" --output json | jq -r '.[] | "\(.Name) \(.Type) \(.ResourceRecords[0].Value)"'
```

Expected: an `A` record pointing at the Gateway's public IP, and a TXT registry entry containing `external-dns/owner=gcp-0-public`.

- [ ] **Step 5: Criterion 6 — reachable from the public internet**

The decisive test. It must run **without `--cacert`**, so the system trust store validates, and ideally from off the tailnet.

```bash
curl -sS -m 25 -o /dev/null -w 'http=%{http_code} ssl_verify=%{ssl_verify_result}\n' \
  https://probe.gcp.cloud.ogenki.io/
```

Expected: `http=200 ssl_verify=0`.

To prove it is genuinely public rather than reachable only via the tailnet, repeat it from a network with no Tailscale — a phone on mobile data, or:

```bash
tailscale down && curl -sS -m 25 -o /dev/null -w '%{http_code}\n' https://probe.gcp.cloud.ogenki.io/ ; tailscale up
```

If neither is possible, record criterion 6 as **partially verified** with the reason, exactly as workstream 10 did for its ACL criterion. Do not claim a public path was proven from inside the tailnet.

- [ ] **Step 6: Criterion 7 — pruning, and no collateral damage**

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z002027037R5RFCG05YY6 \
  --query "length(ResourceRecordSets)" --output text    # note this number
kubectl delete httproute probe-public -n infrastructure
sleep 120
aws route53 list-resource-record-sets --hosted-zone-id Z002027037R5RFCG05YY6 \
  --query "ResourceRecordSets[?contains(Name,'probe.gcp')]" --output text
```

Expected: empty. Then confirm the record count returned to its pre-probe value and that `aws-0`'s records (`runlore.cloud.ogenki.io` and its TXT) are still present and still owned by `aws-0` — the two external-dns instances writing one zone is the riskiest part of this design, and this is the check that it behaved.

- [ ] **Step 7: Write the verification document and update the bootstrap doc**

Create `docs/superpowers/specs/2026-08-25-gcp-public-ingress-verification.md` with one section per criterion, quoting the command and its **actual** output. Record anything untested as unverified with the reason.

Add a short section to `docs/gcp-bootstrap.md` noting that public ingress requires the `opentofu/shared/aws-gcp-federation` stack to be applied, and that renaming or moving the GKE cluster invalidates the OIDC provider.

- [ ] **Step 8: Tear down and verify**

**Order matters: reclaim DNS BEFORE destroying the cluster.** Task 4's review
(O1) established why. `policy: sync` only reclaims records while external-dns is
*running*. A wholesale destroy kills the controller before the Gateway and
HTTPRoutes are gone, so the `gcp-0-public`-owned A **and** TXT records survive in
the shared production zone. They are harmless to `aws-0` — different owner ID —
but they outlive the cluster, and a later gcp-0 rebuild would silently **adopt**
them by owner ID rather than flag them as strays. This repo has form here: an EKS
rebuild once left 62 orphaned EBS volumes.

So delete the routes first and let external-dns do its own cleanup:

```bash
# 1. Delete the routes; external-dns is still running and will reclaim the records.
kubectl delete httproute --all -n infrastructure
kubectl delete deployment,service probe -n infrastructure

# 2. Wait for the reclaim, then confirm it actually happened.
sleep 90
aws route53 list-resource-record-sets --hosted-zone-id Z002027037R5RFCG05YY6 \
  --query "ResourceRecordSets[?contains(to_string(ResourceRecords[].Value|[0]), 'gcp-0-public')]" \
  --output text
```

Expected: empty. If anything remains, delete it explicitly by change-batch before
proceeding — do not destroy the cluster while records it owns are still live, or
nothing will be able to reclaim them afterwards.

```bash
# 3. Only now, destroy.
cd opentofu/gcp && TM_GCP_ENABLED=true TM_DESTROY_CONFIRMED=true terramate script run --reverse \
  --disable-check-git-remote --disable-check-git-untracked --disable-check-git-uncommitted destroy
```

Then confirm against the API rather than the exit code:

```bash
gcloud compute forwarding-rules list --project=ogenki-435905
gcloud compute addresses list --project=ogenki-435905
gcloud compute instances list --project=ogenki-435905
gcloud container clusters list --project=ogenki-435905
aws route53 list-resource-record-sets --hosted-zone-id Z002027037R5RFCG05YY6 \
  --query "ResourceRecordSets[?contains(Name,'gcp')]" --output text
```

Expected: all empty. Read each listing — `gcloud compute instances list` exits 0
with a warning when nothing matches, so its exit code is not evidence. **The forwarding rule and address are the two that cost money** and are exactly what a public Gateway leaves behind.

**Leave `opentofu/shared/aws-gcp-federation` applied.** It is an IAM role and an OIDC provider — free, and destroying it would mean re-registering the provider on every rebuild. It is the same reasoning as the Cloud KMS key ring: a deliberate survivor, not a leak. Say so in the verification document.

- [ ] **Step 9: Commit and open the PR**

```bash
git add docs/
git commit -m "docs(gcp): verification of public ingress on gcp-0"
git push
gh pr create --title "feat(gcp): public ingress on gcp-0 via cross-cloud DNS federation" --base main
```

---

## Self-review

**Spec coverage.** Every section of the design maps to a task: the AWS IAM federation and ADR → 1; the ClusterIssuer → 2; the public Gateway and LB → 3; the second external-dns → 4; all eight success criteria → 5. The design's exclusions (GKE Gateway controller, Tailscale Funnel, cross-cloud load balancing, a permanent public consumer) are restated as Global Constraints so a task cannot re-add them.

**Placeholders.** None. Every manifest and command is complete and runnable.

**Consistency.** `route53_role_arn` is produced by Task 1's output and consumed verbatim in Task 2's ClusterIssuer and Task 4's `AWS_ROLE_ARN`. The ServiceAccount names in Task 1's `trusted_service_accounts` (`security/cert-manager`, `kube-system/external-dns-public`) match exactly what Tasks 2 and 4 create — a mismatch there produces a role that silently refuses the token, which is why both files carry a comment saying so. `sts.amazonaws.com` is the audience in the OIDC `client_id_list`, the trust policy's `aud` condition, and the projected volume. Kustomization `security-public-certs` (Task 2) is what `infrastructure-gapi-public` (Task 3) depends on.

**One thing deliberately left to implementation.** Task 1 Step 1 verifies the GKE OIDC discovery endpoint before any IAM is written. If GKE does not serve it at the expected URL, the design's central mechanism does not exist and the plan must stop rather than work around it — so it is a verification step, not an assumption baked into later tasks.
