---
title: Verify the cluster
weight: 25
description: Authenticate to aws-0 and check every layer yourself, from Flux down to the browser.
lastVerified: 2026-08-29
---

The deploy reporting success only means OpenTofu finished. Flux then reconciles
the platform on its own, and that is where a bootstrap actually succeeds or
quietly stalls. Work down the layers — each step tells you which one broke.

The region and cluster name below are the reference values; use whatever you set
in `opentofu/config.tm.hcl`.

## 1. Authenticate

The EKS API endpoint is **private**, so the Tailscale subnet router built in
stage 1 has to be up before `kubectl` can reach anything:

```bash
tailscale status | head -3
aws eks update-kubeconfig --region eu-west-3 --name aws-0
kubectl get nodes
```

```
NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-0-26-202.eu-west-3.compute.internal   Ready    <none>   58m   v1.36.1-eks-a3a0722
ip-10-0-26-214.eu-west-3.compute.internal   Ready    <none>   58m   v1.36.1-eks-a3a0722
```

Nodes run **Bottlerocket**. More will appear as Karpenter provisions them —
two is the managed node group, not the whole cluster.

{{< callout type="info" >}}
`Unable to connect to the server: dial tcp ... i/o timeout` means the tailnet,
not the cluster. Check `tailscale status` shows the `ip-10-0-*` subnet router as
`active`, and that a stale endpoint is not cached in `~/.kube/config` from a
previous build.
{{< /callout >}}

## 2. GitOps layer

Flux is the thing that turns an empty cluster into the platform:

```bash
flux get kustomizations
```

29 Kustomizations, and on a healthy cluster every one reads `True` except the
LLM umbrella:

```
llm-platform    True (suspended)   waiting to be reconciled
```

That one is **suspended on purpose** — see
[the LLM platform gate](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md#self-hosted-llm-platform-opt-in).
A suspended Kustomization is the expected steady state here, not a failure.

{{< callout type="warning" >}}
**Read the failure, not the cascade.** Kustomizations form a dependency graph, so
one broken component reports as a dozen `dependency 'flux-system/X' is not ready`
messages that name innocent parties. Find the one that is *not* a dependency
message and start there — then look at events in its namespace, because the true
error is often one level below Flux:

```bash
flux get kustomizations | grep -v True
kubectl get events -n <namespace> --sort-by=.lastTimestamp | tail -20
```

A from-scratch bootstrap on 2026-08-29 stalled at 16 of 29 with every message
pointing at `security-openbao`. The actual error was an ExternalSecret asking for
a key that did not exist, visible only in `security` namespace events.
{{< /callout >}}

## 3. Secrets

External Secrets pulls from AWS Secrets Manager; cert-manager authenticates to
OpenBao with an AppRole delivered the same way:

```bash
kubectl get externalsecret -A
kubectl get clusterissuer
```

Every ExternalSecret should read `SecretSynced`, and three ClusterIssuers should
be `True`:

```
letsencrypt-prod      True
letsencrypt-staging   True
openbao               True
```

`SecretSyncedError` with *"Secret does not exist"* usually means the **key** is
wrong rather than the secret missing — compare it against what OpenTofu wrote
(`cert_manager_approle_secret_name` in `opentofu/config.tm.hcl`).

## 4. Certificates and networking

Cilium is the GatewayClass implementation, so Gateway API health is Cilium
health:

```bash
kubectl get gatewayclass
kubectl get gateway -A
kubectl get certificate -A
```

Two GatewayClasses, both `ACCEPTED=True`, and every Gateway `PROGRAMMED=True`:

```
NAME               CONTROLLER                     ACCEPTED
cilium             io.cilium/gateway-controller   True
cilium-tailscale   io.cilium/gateway-controller   True
```

```
NAMESPACE        NAME                         CLASS              PROGRAMMED
infrastructure   platform-public              cilium             True
infrastructure   platform-tailscale-admin     cilium-tailscale   True
infrastructure   platform-tailscale-general   cilium-tailscale   True
security         zitadel                      cilium             True
```

{{< callout type="warning" >}}
A GatewayClass stuck at `ACCEPTED=Unknown` with *"Waiting for controller"* is the
cilium-operator startup probe, not a broken Gateway. The operator checks for the
Gateway API CRDs **once, at startup**, and silently disables its Gateway
controller if any are missing. Confirm and fix:

```bash
kubectl logs -n kube-system -l io.cilium/app=operator | grep "Required GatewayAPI resources"
kubectl rollout restart -n kube-system deployment/cilium-operator
```
{{< /callout >}}

## 5. Databases

Three CloudNativePG clusters, all reporting healthy — and, importantly, all
**archiving**:

```bash
kubectl get sqlinstance -A
kubectl get cluster.postgresql.cnpg.io -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ARCHIVING:.status.conditions[?(@.type=="ContinuousArchiving")].status'
```

```
NS         NAME                                ARCHIVING
apps       xplane-image-gallery-cnpg-cluster   True
security   xplane-zitadel-cnpg-cluster         True
tooling    xplane-harbor-cnpg-cluster          True
```

{{< callout type="warning" >}}
**Check `ContinuousArchiving`, not just `Ready`.** A cluster whose destination WAL
archive was not cleared before the rebuild starts, reports `Ready`, and turns
Flux green — with no backups at all. See
[Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}).
{{< /callout >}}

## 6. Browse it

Everything private resolves under `*.priv.aws.ogenki.io` over the tailnet, with
certificates issued by the OpenBao PKI:

| Service | URL |
|---|---|
| Grafana | `https://grafana.priv.aws.ogenki.io` |
| Harbor | `https://harbor.priv.aws.ogenki.io` |
| Headlamp | `https://headlamp.priv.aws.ogenki.io` |
| Flux UI | `https://flux-ui-aws-0.priv.aws.ogenki.io` |
| VictoriaMetrics | `https://vm.priv.aws.ogenki.io` |
| VictoriaLogs | `https://vl.priv.aws.ogenki.io` |
| VictoriaTraces | `https://vt.priv.aws.ogenki.io` |
| Hubble UI | `https://hubble-ui-aws-0.priv.aws.ogenki.io` |
| App Wizard | `https://app-wizard.priv.aws.ogenki.io` |
| Image gallery | `https://image-gallery.priv.aws.ogenki.io` |

Hubble UI is on the **admin** Gateway (`tag:admin`, `group:admin` only);
everything else is on the general one. A 403 on Hubble while Grafana works is a
tailnet ACL result, not a broken route.

Single sign-on goes through ZITADEL — see
[Authentication]({{< relref "/docs/platform/security/authentication.md" >}}).

## 7. Observability is actually receiving data

A Grafana that loads proves nothing; check that data arrives:

```bash
kubectl get vmagent,vmalertmanager -n observability
kubectl logs -n observability -l app.kubernetes.io/name=vector --tail=5
```

Then query VictoriaLogs directly:

```bash
echo '{kubernetes.pod_namespace="flux-system"} | limit 5' \
  | vlogscli -datasource.url='https://vl.priv.aws.ogenki.io/select/logsql/query'
```

Event-driven components (Karpenter, cert-manager, Flux) need a 6–12h window
before they look alive — an empty 1h panel is usually the range, not the wiring.

## When you are done

[Teardown]({{< relref "/docs/get-started/aws/teardown.md" >}}) — and read it
before you start, not after. The cluster bills from the first apply.

## Related

- [Access]({{< relref "/docs/get-started/access.md" >}}) — reaching the VPN,
  OpenBao, the cluster and the dashboards
- [Verify gcp-0]({{< relref "/docs/get-started/gcp/verify.md" >}}) — the same
  walkthrough for the GCP lane
