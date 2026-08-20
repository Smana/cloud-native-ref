---
title: AWS
weight: 10
description: Deploy the platform on AWS — three sequential stages, about thirty minutes.
lastVerified: 2026-08-20
---

AWS is the only cloud this platform runs on today. Every stage below is an
OpenTofu stack orchestrated by [Terramate](https://terramate.io/); each stack
declares the ones it depends on (`after` in its `stack.tm.hcl`), so Terramate
always applies them in the right order even when you run one command that
spans several stages.

## Configure before deploying

1. Edit `opentofu/config.tm.hcl` — region, EKS cluster name, the Helm chart
   versions used by the bootstrap (`cilium_version`, `flux_operator_version`,
   `flux_instance_version`), `flux_sync_repository_url` (point it at your own
   fork), and `openbao_url`.
2. Create a `variables.tfvars` in each stack directory
   (`opentofu/network/`, `opentofu/openbao/cluster/`,
   `opentofu/openbao/management/`, `opentofu/eks/init/`) with your
   environment-specific values.
3. Export the one secret Terraform needs from the environment rather than a
   file:

   ```bash
   export TF_VAR_tailscale_api_key=<YOUR_TAILSCALE_API_KEY>
   ```

## Deploy

{{% steps %}}

### Stage 1 — Network

```bash
cd opentofu
terramate script run deploy
```

Creates the VPC across three availability zones, public and private subnets,
a Route53 private hosted zone, VPC endpoints, and the Tailscale subnet router
EC2 instance that gives you private access to everything built after this
point.

### Stage 2 — OpenBao

Terramate continues straight into this stage as part of the same command
above — `openbao/cluster` depends on `network`, and `openbao/management`
depends on `openbao/cluster`.

Creates a 5-node HA OpenBao cluster on SPOT instances behind a Network Load
Balancer, then configures it: the cluster is initialized and auto-unsealed
via AWS KMS, its root token and recovery keys are written to two separate
AWS Secrets Manager entries, and a three-tier PKI (root → intermediate →
leaf) plus the cert-manager AppRole are provisioned — all driven by
`scripts/openbao-config.sh`, no manual `bao operator init`/`unseal` step
required.

### Stage 3 — Kubernetes (EKS)

```bash
cd opentofu/eks/init
terramate script run deploy
```

A separate command because this stack runs a two-stage bootstrap internally:
first the EKS cluster comes up with the temporary VPC-CNI bootstrap addon,
then that gets replaced with Cilium (which also replaces kube-proxy) and the
Flux Operator + Instance are installed — the point at which the cluster
starts reconciling the rest of this repository from Git. A third internal
step recycles any node-group node whose ENIs predate Cilium, so it can pick
up prefix delegation (see `opentofu/eks/init/workflows.tm.hcl`).

{{% /steps %}}

## Verify

```bash
aws eks update-kubeconfig --region eu-west-3 --name mycluster-0
kubectl get nodes
flux get all
```

Once Stage 3 finishes, Flux takes over: Security (External Secrets,
cert-manager, Kyverno), Infrastructure (Cilium policies, Gateway API,
Karpenter), Observability (VictoriaMetrics, VictoriaLogs, Grafana), and
Tooling (Harbor, Headlamp, Homepage) all reconcile without any further
command from you. See [Access]({{< relref "/docs/get-started/aws/access.md" >}})
for how to reach the VPN, OpenBao, the cluster, and the dashboard, and
[Teardown]({{< relref "/docs/get-started/aws/teardown.md" >}}) when you are
done.
