---
title: AWS
weight: 20
description: Deploy the platform on AWS — three sequential stages, about thirty minutes.
lastVerified: 2026-08-27
---

AWS is one of two implemented cloud lanes — see
[GCP]({{< relref "/docs/get-started/gcp/_index.md" >}}) for the other, and
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}) for
what each one runs. Every stage below is an OpenTofu stack orchestrated by
[Terramate](https://terramate.io/); each stack declares the ones it depends on
(`after` in its `stack.tm.hcl`), so Terramate always applies them in the right
order even when you run one command that spans several stages.

## Configure before deploying

**Every stack already has a `variables.tfvars` committed**, holding values that
deploy against the reference environment. You are editing a working
configuration, not authoring one — which also means the fastest way to see what
a stack expects is to read the file already sitting next to it.

1. Edit `opentofu/config.tm.hcl` — region, EKS cluster name, the Helm chart
   versions used by the bootstrap (`cilium_version`, `flux_operator_version`,
   `flux_instance_version`), and `openbao_url`.
2. Edit the `variables.tfvars` in each stack directory
   (`opentofu/aws/network/`, `opentofu/aws/openbao/cluster/`,
   `opentofu/aws/openbao/management/`, `opentofu/aws/eks/init/`,
   `opentofu/aws/eks/configure/`), replacing the reference values with yours —
   principally `cluster_name`, `env`, `private_domain_name` and
   `public_domain_name` — and above all `flux_sync_url` in
   `opentofu/aws/eks/configure/variables.tfvars`: the URL of *your* fork,
   which is what Flux actually syncs from.
3. Edit `opentofu/shared/tailscale/variables.tfvars` — `tailnet` and
   `admin_users` are the reference tailnet's identity, and this stack is the
   first thing the root deploy applies; point them at your own tailnet.
4. Export the one secret Terraform needs from the environment rather than a
   file:

   ```bash
   export TF_VAR_tailscale_api_key=<YOUR_TAILSCALE_API_KEY>
   ```

## Deploy

{{% steps %}}

### Stages 1 and 2 — Network, then OpenBao

```bash
cd opentofu
terramate script run deploy
```

No cloud flag: `TM_CLOUD` defaults to `aws`, so this builds the AWS lane and
skips GCP. Set `TM_CLOUD=aws,gcp` (or `all`) to build both in one run — see
[Commands]({{< relref "/docs/reference/commands.md" >}}).

**One command covers both stages** — there is no second command to run below.
Terramate resolves the dependency graph and starts with `shared/tailscale`, the
tailnet-wide singletons `network` declares in its `after` list, then applies
`network`, `openbao/cluster` and `openbao/management` in order. The same run
also applies `opentofu/shared/aws-gcp-federation` — only its `destroy` is
gated — which the GCP lane needs and which costs nothing idle here.

*Stage 1* creates the VPC across three availability zones, public and private
subnets, a Route53 private hosted zone, VPC endpoints, and the Tailscale subnet
router EC2 instance that gives you private access to everything built after this
point.

*Stage 2* creates the OpenBao cluster behind a Network Load Balancer, then configures
it. As committed, `opentofu/aws/openbao/cluster/variables.tfvars` sets
`mode = "dev"`: a single `t3.micro` on `file` storage, which is enough to
follow everything in these guides and is not highly available. Set
`mode = "ha"` for the five-node Raft cluster on SPOT instances — the same
configuration steps apply either way.

Either way, the cluster is initialized and auto-unsealed
via AWS KMS, its root token and recovery keys are written to two separate
AWS Secrets Manager entries, and a three-tier PKI (root → intermediate →
leaf) plus the cert-manager AppRole are provisioned — all driven by
`scripts/openbao-config.sh`, no manual `bao operator init`/`unseal` step
required.

### Stage 3 — Kubernetes (EKS)

```bash
cd opentofu/aws/eks/init
terramate script run deploy
```

A separate command because this stack runs a two-stage bootstrap internally:
first the EKS cluster comes up with the temporary VPC-CNI bootstrap addon,
then that gets replaced with Cilium (which also replaces kube-proxy) and the
Flux Operator + Instance are installed — the point at which the cluster
starts reconciling the rest of this repository from Git. A third internal
step recycles any node-group node whose ENIs predate Cilium, so it can pick
up prefix delegation (see `opentofu/aws/eks/init/workflows.tm.hcl`).

{{% /steps %}}

## Verify

The region and cluster name below are the reference values — use whatever you
set in `opentofu/config.tm.hcl`. The API endpoint is private, so the Tailscale
subnet router from Stage 1 must be up first (`tailscale status`).

```bash
aws eks update-kubeconfig --region eu-west-3 --name aws-0
kubectl get nodes
flux get all
```

Once Stage 3 finishes, Flux takes over: Security (External Secrets,
cert-manager, Kyverno), Infrastructure (Cilium policies, Gateway API,
Karpenter), Observability (VictoriaMetrics, VictoriaLogs, Grafana), and
Tooling (Harbor, Headlamp, Homepage) all reconcile without any further
command from you. See [Access]({{< relref "/docs/get-started/access.md" >}})
for how to reach the VPN, OpenBao, the cluster, and the dashboard, and
[Teardown]({{< relref "/docs/get-started/aws/teardown.md" >}}) when you are
done.
