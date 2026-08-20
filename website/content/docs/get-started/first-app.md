---
title: First Application
weight: 40
description: Deploy your first app onto the platform with one small YAML claim.
lastVerified: 2026-08-20
---

Applications on this platform are described with an `App` — a single
namespaced YAML document (a Crossplane *claim*) that says what to run and
what it needs, rather than hand-written Deployments, Services, and IAM. You
apply the claim; the platform expands it into all the underlying Kubernetes
objects, security hardening included.

## Deploy a web app

A web app needs an image and, if you want it reachable from outside the
cluster, a route:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: hello
  namespace: demo
spec:
  image:
    repository: ghcr.io/example/hello
    tag: "v1.0.0"
  service:
    port: 8080
  route:
    enabled: true
    hostname: hello          # becomes hello.priv.cloud.ogenki.io
```

Apply it:

```bash
kubectl apply -f hello.yaml
```

## Check its status

The App reports `Ready` once its underlying resources are actually
available — not just created:

```bash
kubectl get app hello -n demo
kubectl describe app hello -n demo
```

`kubectl describe` lists the resources the App created and any events. To see
those objects directly:

```bash
kubectl get deployment,service,httproute -l app.kubernetes.io/name=hello -n demo
```

## What that small claim created

- a **Deployment** running your container as non-root with a read-only root
  filesystem, a writable `/tmp`, and HTTP liveness (`/healthz`) and readiness
  (`/readyz`) probes on the service port;
- a **Service** (ClusterIP) exposing port 8080 as a named `http` port;
- a **ServiceAccount** dedicated to this app, ready to carry cloud
  permissions;
- an **HTTPRoute** wiring `hello.priv.cloud.ogenki.io` through the platform's
  private (Tailscale) gateway.

Drop `route` and you still get the Deployment, Service, and ServiceAccount —
just no external exposure, useful for internal-only services reached by
their in-cluster Service DNS name (`hello.demo.svc.cluster.local`).

This is the smallest possible claim. The same `App` kind also covers
background workers, scheduled jobs, databases, caching, autoscaling, and
zero-trust network policies — the same interface all the way from a bare
container image to a production-ready service, with no rewrite in between.
