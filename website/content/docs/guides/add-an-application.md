---
title: Add an application
weight: 20
description: From an image to a running, routed, monitored application — via the wizard or by hand.
lastVerified: 2026-08-30
---

Two paths, same result: an `App` claim committed to Git and reconciled by
Flux. The wizard writes the YAML for you; writing it by hand gives you the
full field set immediately.

## Which path

**Use the App Wizard** if you want the common shape without learning the API
first, or if you want the rendered output previewed before you commit. It
produces a pull request against this repository.

**Write the YAML** if you already know what you need, if you are scripting it,
or if you want a field the wizard does not expose.

Neither path is privileged — the wizard produces exactly the claim you would
have written.

## Writing the claim

Start from the smallest thing that runs:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: myapp
  namespace: apps
spec:
  image:
    repository: ghcr.io/example/myapp
    tag: "1.4.2"
  service:
    port: 8080
```

Then add what you need — a route, a database, a cache, a bucket, autoscaling.
Each is an additional block, not a rewrite. The
[field reference]({{< relref "/docs/platform/developer-platform/app-field-reference.md" >}})
lists every field with its type and default.

Two conventions the platform depends on:

- **Name the claim plainly** (e.g. `myapp`) — do not prefix it yourself. The
  composition derives an `xplane-*` name for every managed resource it
  creates; the prefix is load-bearing for IAM scoping, and renaming one later
  is delete-and-create.
- **Do not wire connection strings yourself.** If you ask for a
  `sqlInstance` or `kvStore`, the composition injects `DATABASE_URL` and
  `REDIS_URL`. Setting them by hand fights the composition.

## Committing it

The claim goes under `apps/<stack>/<name>/`, with a `kustomization.yaml`
alongside it and the stack's kustomization updated to include the directory.
The `<stack>` must be declared in `apps/stacks.yaml`, wired into the
per-cluster parent — `apps/aws-0/kustomization.yaml`,
`apps/gcp-0/kustomization.yaml`, or both — and its namespace must already
exist under `namespaces/base/`. Flux picks it up on the next reconciliation
of the `apps` Kustomization.

## Verifying it reconciled

```bash
kubectl get app myapp -n apps
kubectl describe app myapp -n apps
```

`READY=True` means the composition's readiness checks passed — the Deployment
is Available, the Service has a ClusterIP, and any HTTPRoute was accepted by
its gateway. It is a stronger signal than "the pods are running".

If it does not go ready, work down the chain in
[Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}).

## Reading on

- [Deploy your first app]({{< relref "/docs/get-started/first-app.md" >}}) —
  the guided version of this page
- [The App composition]({{< relref "/docs/platform/developer-platform/app.md" >}})
  — what each field renders
- [App Wizard]({{< relref "/docs/platform/developer-platform/app-wizard.md" >}})
  — the assisted path, with a worked example
