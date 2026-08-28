---
title: Troubleshooting
weight: 40
description: The failures that actually happen here — silent Gateway API breakage, network policy traps, claim rejections, and cascading dependencies.
lastVerified: 2026-08-27
---

Generic Kubernetes advice is available everywhere. This page carries the
failures specific to *this* platform, most of which have cost real debugging
time and several of which fail silently.

## Start here on any timeout

**Check the network policy first.** Default-deny is the norm here, so a
missing egress rule is the most common cause of a connection that hangs
rather than refuses.

```bash
kubectl get ciliumnetworkpolicy -n <ns>
hubble observe --pod <ns>/<pod> --verdict DROPPED --last 50
```

## Gateways stuck "Waiting for controller"

The most confusing failure in the platform, because nothing crashes.

**cilium-operator probes for the Gateway API CRDs once, at startup.** If any
are missing it permanently disables its Gateway API controller — no crash, no
alert, no retry. The symptoms cascade: `GatewayClass` shows
`ACCEPTED=Unknown`, Gateways never become programmed, HTTPRoutes have no
`status.parents`, and every `App` claim that owns a route sits `READY=False`.

Confirm:

```bash
kubectl logs -n kube-system -l io.cilium/app=operator | grep "Required GatewayAPI resources"
```

Recover:

```bash
kubectl rollout restart -n kube-system deployment/cilium-operator
```

Both clouds install these CRDs from `opentofu/shared/modules/gateway-api-crds`,
which applies the entire experimental-channel bundle — so a CRD Cilium wants
cannot be missing because someone forgot to list it. If the fix is a *newer*
Gateway API release, bump the two pins together: `gateway_api_version` in
`opentofu/config.tm.hcl`'s `globals` — one value for both clouds — and the
`ref.tag` in `flux/sources/gitrepo-gateway-api.yaml`.
`./scripts/validate-doc-claims.sh` fails when they disagree, so a partial bump
does not reach a cluster. Flux applies the full CRD
directory too, but only *after* Cilium is already running — which is why the
operator can start before the CRD exists.

{{< callout type="warning" >}}
The module keys its manifests with `for_each` on the manifest self-link, not
`count`. Keep it that way: a `count`-indexed list makes OpenTofu destroy and
recreate live CRDs whenever the set is reordered, and destroying a Gateway API
CRD deletes every Gateway and HTTPRoute of that kind on the cluster.
{{< /callout >}}

## CiliumNetworkPolicy traps

Four failure modes that all present as "the policy looks right but traffic is
dropped".

**DNS L7 inspection is mandatory for `toFQDNs`.** The kube-dns egress rule
must include `toPorts.rules.dns.matchPattern: "*"`. Without it Cilium proxies
the query but never sees the response IPs, so the `toFQDNs` allowlist has no
addresses to match and every follow-up TCP connection is silently denied —
while DNS itself keeps working, which is what makes it confusing.

**`matchPattern: "*"` does not span dots.** It is a single-segment glob:
`*.huggingface.co` matches `cdn.huggingface.co` but **not**
`cas-bridge.xet.huggingface.co`. CDN topology fans out quickly, so `toFQDNs`
becomes a maintenance chase.

**`toEntities: world` excludes link-local addresses.** And `toCIDR` alone does
not match host-network endpoints. The EKS Pod Identity Agent at
`169.254.170.23:80` runs on the node's host network, so Cilium classifies the
destination as the `host` entity and a `toCIDR: 169.254.170.23/32` rule
silently fails. Use `toEntities: ["host"]` scoped to TCP 80. The symptom is an
AWS SDK reporting `Connect timeout on endpoint URL: 'http://169.254.170.23/v1/credentials'`.

**Diagnostic order:** `hubble observe --verdict DROPPED` → reverse-IP the
dropped address with `cilium fqdn cache list -o json` on that node's agent →
check `rules.dns` on the kube-dns rule → check glob depth → check link-local.

## A Flux dependency failure cascades

One real error produces a dozen alarming messages. A Kustomization
health-checking a namespaced resource whose namespace does not exist reports
`namespaces "X" not found`, and everything depending on it reports
`dependency … not ready`.

Fix the root, not the cascade. `flux get kustomizations` and look for the one
whose message is not "dependency not ready".

## Flux source sharding

This repository shards Flux controllers. A `GitRepository` or
`HelmRepository` placed under an application directory inherits
`sharding.fluxcd.io/key=apps`, and the default-shard HelmChart then cannot
find it — the source reports `Ready` while the consumer reports
`source not found`.

**Sources live under `flux-sources`**, which carries no shard label.

## App claim rejected at apply time

CEL validation rejects invalid claims at the API server, and the message
names the field.

| Message | Meaning |
|---|---|
| `route.hostname is required when route is enabled` | Set `route.hostname` |
| `schedule is required when type is 'cron'` | Add `spec.schedule` |
| `schedule is only valid when type is 'cron'` | Remove `schedule`, or set `type: cron` |
| `route is only valid when type is 'web'` | Routes are web-only |
| `gateway is only valid when type is 'web'` | Gateways are web-only |
| `autoscaling is not valid when type is 'cron'` | Cron cannot autoscale |
| `pdb is not valid when type is 'cron'` | Cron cannot have a PDB |
| `autoscaling.minReplicas must be <= maxReplicas` | Fix the ordering |
| `persistence.size and persistence.mountPath are required when persistence is enabled` | Set both |
| `autoscaling is incompatible with ReadWriteOnce persistence (multi-attach)` | Use `ReadWriteMany`, or drop autoscaling |
| `container name 'main' is reserved for the primary container` | Rename the sidecar or init container |
| `sidecars names must be unique` / `initContainers names must be unique` | Give each a distinct name |
| `sqlInstance.backup.bucketName is required when backup schedule is set` | Add `backup.bucketName` |

## App stuck not ready

An `App` reports `Ready` only when its underlying resources genuinely are.
Work down the chain:

```bash
kubectl describe app <name> -n <ns>
kubectl get deployment,cronjob -l app.kubernetes.io/name=<name> -n <ns>
kubectl get pods -l app.kubernetes.io/name=<name> -n <ns>
kubectl logs <pod> -n <ns>          # -c <container> for a sidecar or init container
```

Then the surrounding resources:

```bash
kubectl get externalsecret -n <ns>          # secrets syncing?
kubectl get httproute,gateway -n <ns>       # route accepted?
kubectl get ciliumnetworkpolicy -n <ns>     # policy in place?
kubectl get sqlinstance,kvstore -n <ns>     # data services ready?
```

## Pods failing to start

**`ImagePullBackOff`** — check `image.repository` and `image.tag`; for a
private registry confirm `imagePullSecrets` names a docker-registry Secret in
the *same* namespace; use `Always` for mutable tags and `IfNotPresent` for
pinned ones.

**`CrashLoopBackOff` or never becoming ready** — `readOnlyRootFilesystem` is
on by default, so an application that writes outside `/tmp` needs a volume via
`persistence` or `extraVolumes`. The default probe port is `service.port` and
the default paths are `/healthz` and `/readyz`; override the probe `path` or
`type` if yours differ. For slow boots add a `startup` probe rather than
inflating `initialDelaySeconds`.

## Crossplane

**`<Kind>/<name> namespace not specified`** — managed resources are namespaced
in provider-aws v2; add `metadata.namespace`.

**`no matches for kind <Kind>`** — the CRD is not activated. Provider packages
ship many CRDs but only those listed in
`infrastructure/base/crossplane/providers-aws/activation-policy.yaml` are
installed.

**XR reconcile loops on `failed waiting for … Informer to sync`** — the
Crossplane service account lacks RBAC for a third-party Kind. Check with
`kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane list <plural> -A`
first; if that returns `yes`, restart the controller.

## OpenBao

**`bao status` hangs against 127.0.0.1** — that is a core deadlock, not a VPN
problem. See
[OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}) for the 2.6
line's known issue and the serialisation that works around it.

## Reading on

- [Networking]({{< relref "/docs/platform/networking/_index.md" >}}) — the
  datapath and gateway model
- [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}}) — the dependency
  graph behind cascading failures
- [Developer platform]({{< relref "/docs/platform/developer-platform/_index.md" >}})
  — what each `App` field renders
