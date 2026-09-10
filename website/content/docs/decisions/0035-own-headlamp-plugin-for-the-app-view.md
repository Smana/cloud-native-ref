---
title: An in-house Headlamp plugin gives the App abstraction its own view
linkTitle: 0035 · Headlamp App plugin
weight: 350
description: The platform's App claim gets a purpose-built Headlamp page — status, a graph of exactly its resources, pods and jump-off links — rather than Headlamp's generic custom-resource page or a third-party Crossplane plugin. The plugin is small because it knows one kind; a generic Crossplane browser would be larger and say less about this platform.
lastVerified: 2026-09-10
---

**Status**: Accepted
**Date**: 2026-09-09
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0012](0012-crossplane-and-opentofu.md) — the App abstraction this views;
[ADR-0032](0032-workforce-identity-federation-for-gke-rbac.md) — the per-user identity
the plugin runs as on GKE

---

## Context

A developer declares an application through the App Wizard, which opens a pull
request containing one `App` claim. After the merge the wizard has nothing more
to say: it reads Git, holds no cluster credentials, and its "My apps" list is a
directory listing. The question it cannot answer is the one that matters after
day one — is my app running, and if not, which of the twenty-odd resources the
composition rendered is unhappy?

Headlamp is already deployed on both clusters and authenticates the same people.
It can show any `App`: its page for a custom resource renders the YAML, the
conditions and the events. What it cannot do is show the *shape* of the app. An
`App` composes a Deployment, a Service, an HTTPRoute, network policies, scrape
configs and, for a database-backed app, a nested `SQLInstance` that composes
further resources of its own. Headlamp's Map can draw all of this, but a plugin
had no way to embed it, and the Map can only be deep-linked by object UID —
which the wizard, reading Git, does not know.

---

## Decision Drivers

- A link built from namespace and name only — the wizard must stay cluster-blind
- One page that answers "is it healthy", with the graph as its centre
- Small surface: the platform has exactly one abstraction to view
- Deployable through the existing GitOps path, on both clouds
- Nothing unlicensed in the platform's supply chain

---

## Considered Options

### Option 1: An in-house plugin with a purpose-built App page

Registers a route at `/c/main/apps/<namespace>/<name>`, resolves the App's
resource tree, and embeds Headlamp's own graph renderer scoped to it.

**Pros**:
- The URL is derivable from what the wizard knows
- The page can say App things: the route hostname, the composed inventory, the nested XR
- Embeds Headlamp's renderer, so the graph matches the rest of the UI
- ~600 lines, all of it about one kind

**Cons**:
- Code the platform owns and must maintain
- Requires Headlamp ≥ 0.45.0 (2026-08-20) for the renderer export
- The published plugin toolkit lags that export, needing a temporary runtime shim

### Option 2: Deep-link into the global Map

A much smaller plugin that resolves the App and redirects to `/map?node=<uid>`.

**Pros**:
- Works on Headlamp 0.44.0, no upgrade needed
- Barely any code

**Cons**:
- Lands on the generic Map with its source picker and cluster-wide filters
- No status header, no pods, no logs, no links — only the graph
- Still needs a plugin to turn a name into a UID, so it does not avoid ownership

### Option 3: The third-party Crossplane plugin

`builver/headlamp-plugin-crossplane` has XR detail pages and a Crossplane map
source, and ships as an init-container image like our other plugins.

**Pros**:
- No code to write
- Broader: providers, functions, compositions, managed resources

**Cons**:
- v0.1.0-rc4, a release candidate from a single author, zero stars, **no LICENSE file**
- Generic by design: no App semantics, no route URL, no logs, no links
- Its routes key on the XR plural and Crossplane's own naming, not on a name the wizard knows
- A dependency on an unlicensed project in a platform reference repository

---

## Decision Outcome

**Chosen option**: "Option 1 — an in-house plugin".

**Rationale**: The deciding constraint is the link. The wizard knows a
namespace and a name, and only a plugin route can turn those into a live view;
options 2 and 3 both still require plugin code to do it, so "no code" was never
really on the table. Given that, the difference between options 1 and 2 is one
page's worth of components on top of the same resolver, for a page that answers
the question instead of handing over a general-purpose graph. Option 3 was
rejected on licensing before its features were weighed.

---

## Consequences

### Positive

- One click from a declared app to its running state, on either cloud
- The graph is scoped to one app, so it is readable where the global Map is not
- Nested XRs are expanded, so a database-backed app shows its `SQLInstance`'s children too
- The global Map gains an "Apps" source as a side effect of the same resolver

### Negative

- Another component to maintain, and it tracks Headlamp's plugin API
- Headlamp is pinned to ≥ 0.45.0; a downgrade breaks the embedded graph (the page degrades to a Map link rather than erroring)
- A runtime-global shim until the plugin toolkit ships the `ResourceMap` export; documented at the point of use and deleted when it does

### Neutral

- The App Wizard grows a generic `links` configuration. It names no tool, so the open-source wizard stays deployment-agnostic and Headlamp is merely its first consumer.

---

## Implementation Notes

The plan's largest risk is now closed: the pinned plugin toolkit, roughly a year
older than the Headlamp release this targets, does export every registration the
design needs — route, sidebar entry, details-view header action, map source and
kind icon — so no part of the design had to change to accommodate it. The
renderer itself is still reached through a runtime global, which is the one
temporary shim here.

Source in `container-images/headlamp-plugin-app/`, published by the repo's
container-image workflow and loaded by a fourth init container on the Headlamp
HelmRelease, exactly like the Flux and cert-manager plugins. Jump-off links come
from an optional ConfigMap in `tooling`, substituted per cluster by Flux.

---

## References

- Design: `docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md`
- [kubernetes-sigs/headlamp#6992](https://github.com/kubernetes-sigs/headlamp/pull/6992) — GraphView exported to plugins in 0.45.0
- [builver/headlamp-plugin-crossplane](https://github.com/builver/headlamp-plugin-crossplane) — the rejected third-party option
