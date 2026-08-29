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

```bash
cd opentofu
terramate script run deploy
```

**That is the whole deploy.** One command, from `opentofu/`, for all three
stages — that is what Terramate is for. It resolves the dependency graph and
applies every stack in order; there is no second command, and no stage you have
to drive by hand.

No cloud flag either: `TM_CLOUD` defaults to `aws`, so this builds the AWS lane
and skips GCP. Set `TM_CLOUD=aws,gcp` (or `all`) to build both clouds in the same
run — see [Commands]({{< relref "/docs/reference/commands.md" >}}).

What that one command does, in order:

**`shared/tailscale`** first — the tailnet-wide singletons `network` declares in
its `after` list. The same run also applies `shared/aws-gcp-federation`, which
belongs to the `shared` lane rather than either cloud: the GCP lane needs it and
it costs nothing idle here.

**Stage 1 — the network.** A VPC across three availability zones, public and
private subnets, a Route53 private hosted zone, VPC endpoints, and the Tailscale
subnet router EC2 instance that gives you private access to everything built
after this point.

**Stage 2 — OpenBao.** The cluster behind a Network Load Balancer, then its
configuration. As committed, `opentofu/aws/openbao/cluster/variables.tfvars` sets
`mode = "dev"`: a single `t3.micro` on `file` storage, enough to follow these
guides and not highly available. Set `mode = "ha"` for the five-node Raft cluster
on spot instances — the same configuration steps apply either way.

Either way the cluster is initialized and auto-unsealed via AWS KMS, its root
token and recovery keys are written to two separate AWS Secrets Manager entries,
and a three-tier PKI (root → intermediate → leaf) plus the cert-manager AppRole
are provisioned — all driven by `scripts/openbao-config.sh`, with no manual
`bao operator init` / `unseal` step.

**Stage 3 — Kubernetes.** `aws/eks/init` runs a two-stage bootstrap internally:
the EKS cluster comes up with the temporary VPC-CNI bootstrap addon, then that is
replaced with Cilium (which also replaces kube-proxy) and the Flux Operator and
Instance are installed — the point at which the cluster starts reconciling the
rest of this repository from Git. A third internal step recycles any node-group
node whose ENIs predate Cilium so it can pick up prefix delegation (see
`opentofu/aws/eks/init/workflows.tm.hcl`).

{{< callout type="info" >}}
`aws/eks/configure` is applied twice — once by `eks/init`'s stage 2, which shells
into it, and once as its own stack when Terramate reaches it. The second apply is
a no-op, so this is waste rather than breakage, but it is why the run reports one
more stack than you might expect. GKE does the same thing.
{{< /callout >}}

### Deploying one stack on its own

Rarely needed, and never required by the flow above — but each stack's script
also runs from its own directory, which is useful when re-running a single stage
after a failure:

```bash
cd opentofu/aws/eks/init
terramate script run deploy          # just the Kubernetes stage
```

## Verify

The API endpoint is private, so the Tailscale subnet router from stage 1 must be
up first (`tailscale status`):

```bash
aws eks update-kubeconfig --region eu-west-3 --name aws-0
kubectl get nodes
flux get kustomizations
```

Once the deploy finishes, Flux takes over and reconciles the rest without any
further command from you: Security (External Secrets, cert-manager, Kyverno),
Infrastructure (Cilium policies, Gateway API, Karpenter), Observability
(VictoriaMetrics, VictoriaLogs, Grafana) and Tooling (Harbor, Headlamp,
Homepage).

**That is where a bootstrap actually succeeds or quietly stalls**, so there is a
page for checking it layer by layer:
[Verify the cluster]({{< relref "/docs/get-started/aws/verify.md" >}}).

ZITADEL comes up with **nothing configured in it**, so Google login does not work
until you run the setup steps in
[Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}) — the same
steps on both clouds, with different values.

See also [Access]({{< relref "/docs/get-started/access.md" >}}) for reaching the
VPN, OpenBao, the cluster and the dashboards, and
[Teardown]({{< relref "/docs/get-started/aws/teardown.md" >}}) when you are
done.
