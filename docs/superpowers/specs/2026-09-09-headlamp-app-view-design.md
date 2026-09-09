# One click from the App Wizard to a Headlamp view of the running app

**Status:** design approved, implementation not started
**Date:** 2026-09-09
**Repos:** `Smana/cloud-native-ref` (plugin, wiring, records) and `Smana/app-wizard` (links, cards)

## Problem

The App Wizard is a Git view. Its "My apps" list is built by walking
`apps/<stack>/<app>/app.yaml` in the repository, and it holds no cluster
credentials by design ("its blast radius is one Git repository"). So the list
answers *what did I declare* and nothing about *what is running*: no Ready
condition, no pods, no route, no database. Today a row is inert — the only
actions are Edit and Decommission.

Headlamp is already deployed on both clusters, authenticates the same humans,
and has a Map view that draws resources and their relationships. But there is
no path from one to the other, and Headlamp knows nothing about an `App`: the
built-in page for a custom resource shows YAML, conditions and events, and the
Map cannot be deep-linked by name (only by object UID, which the wizard does
not know).

## Summary

Add a Headlamp plugin, owned here, that renders a dedicated **App page** —
status header, a graph scoped to that app's resource tree, composed resources,
pods with logs, events, and jump-off links — reachable at a URL built from
namespace and name alone. Teach the wizard a generic `links` configuration so
each app card can open that URL on the chosen cluster. The wizard stays
cluster-blind; Headlamp does all the live work.

## What we found

- **Headlamp 0.45.0 (2026-08-20) is the first release that lets a plugin embed
  the Map renderer on its own page.** `GraphView` and `KubeIcon` are exported
  through `pluginLib.ResourceMap` (kubernetes-sigs/headlamp #6992). Props:
  `height`, `defaultNodeSelection`, `defaultSources`, `defaultRelations`,
  `defaultFilters`. Passing an explicit `defaultSources` array — including an
  empty one — skips built-in source discovery; sources registered by plugins
  are always appended; duplicate node ids across sources are deduplicated.
  `defaultFilters` supports `namespace` and `hasErrors` only. We run chart
  0.44.0, so the bump is a prerequisite.
- **The published plugin toolkit (`@kinvolk/headlamp-plugin` 0.14.0,
  2026-05-12) predates that export.** Its type stubs and its externals map do
  not know `ResourceMap`. The plugin reads the renderer from Headlamp's runtime
  global (`window.pluginLib.ResourceMap`) with a local type declaration until a
  toolkit release carries it.
- **The in-cluster context is named `main`** on both clusters: Headlamp derives
  the name from the kubeadm ConfigMap, which neither EKS nor GKE has, and falls
  back to the default. Plugin routes registered with the default
  `useClusterURL: true` therefore live under `/c/main/...`.
- **An `App` is a Crossplane v2 namespaced XR** (`scope: Namespaced`, no
  `claimNames`). Its children are listed in `spec.crossplane.resourceRefs` as
  `{apiVersion, kind, name}` — no namespace, no UID. Composed resources carry
  the `crossplane.io/composite=<name>` label and an ownerReference to the XR.
  Three children are themselves XRs (`SQLInstance`, `KVStore`, `EPI`) with
  their own `resourceRefs`. The full set the composition can render:
  Deployment, Service, ServiceAccount, HTTPRoute, CiliumNetworkPolicy,
  HorizontalPodAutoscaler, PodDisruptionBudget, PersistentVolumeClaim, CronJob,
  ExternalSecret, VMServiceScrape, VMRule, SQLInstance, KVStore, EPI,
  GCPWorkloadIdentity, Bucket, BucketVersioning.
- **The wizard has nothing to hang a link on.** `AppList.tsx` is a table
  (`ui/src/form/AppList.tsx`), the `AppSummary` on the wire is five strings
  (stack, name, namespace, image, type), the only outbound links in the SPA are
  the two GitHub PR anchors, and the config surface has no `links` key. The
  claim GVK is already served on `/api/schema` but never reaches the list.
  `wizard.yaml` is decoded strictly, so a new key needs a struct field first.
- **Both clusters run the same stacks.** `apps/aws-0` and `apps/gcp-0` both
  include `platform` and `demo`, so `podinfo` and `app-wizard` exist on both;
  a link must name its cluster.
- **A third-party plugin exists and was rejected.**
  `builver/headlamp-plugin-crossplane` (v0.1.0-rc4, June 2026) has XR detail
  pages and a Crossplane map source. It is a release candidate from a single
  author with zero stars and no LICENSE file, and it is generic: no route URL,
  no logs, no Grafana, no App semantics. Recorded in ADR-0035.
- **Humans are cluster-admin on both clusters.** On aws-0 Headlamp forwards
  the user's ZITADEL token and the only mapped group, `admin`, is
  cluster-admin. On gcp-0 oauth2-proxy and the token-exchange proxy turn the
  same login into a federated Google token, the API server resolves it to the
  workforce `admin` principalSet, and `security/gcp-0/rbac/admin.yaml` binds
  that to cluster-admin. The `view` ClusterRole in
  `tooling/gcp-0/headlamp/headlamp-proxy-auth.yaml` binds Headlamp's own
  ServiceAccount, not the person. So nothing blocks reads today; a future
  read-only group will need `get/list/watch` on `apps.cloud.ogenki.io` and the
  composed kinds, which `view` alone may not cover.

## Goals

1. From the wizard's app list, one click opens Headlamp on the App page for
   that app, on the chosen cluster, in a new tab.
2. The App page shows, without leaving it: Ready/Synced, the scoped graph,
   every composed resource with a status, the app's pods and their logs, events,
   and jump-off links to Grafana, VictoriaLogs and the source in GitHub.
3. The global Map gains App nodes with edges to their direct children.
4. The wizard stays cluster-blind and learns nothing Headlamp-specific: the
   feature is a generic `links` list with URL templates.
5. Both clusters get the plugin from the shared Headlamp base.

## Non-goals

- Cluster access or live status inside the wizard.
- Editing, restarting or deleting anything from the App page.
- Headlamp Projects (they group by namespace, which maps to a stack, not an app).
- New Grafana dashboards. Jump-offs point at dashboards that already exist.
- A generic Crossplane browser. The plugin knows one kind, `App`; nested XRs are
  walked because the App owns them, not because the plugin understands them.

## Decisions taken during brainstorming

| Decision | Chosen | Over | Why |
|---|---|---|---|
| Landing view | Own plugin, dedicated App page with embedded graph | (B) redirect into the global Map; (C) third-party Crossplane plugin | User wants a custom view with the graph as the floor; (B) is the generic Map UI; (C) is an unlicensed release candidate with no App semantics |
| Wizard cluster access | Stays blind | SA token + RBAC + egress to the API server | A link needs only namespace and name; live truth belongs to Headlamp; blast radius unchanged |
| Wizard list | Cards with an open action | Table plus a row button | The user asked for cards; the W3 UX batch already planned card-style pickers |
| Link config | Generic `links: [{label, url}]` with `{namespace}`, `{name}`, `{stack}` | A `headlamp` key | The wizard is open source and generic; Headlamp is one consumer |
| Plugin home | `container-images/headlamp-plugin-app/` here | The wizard repo; a new repo | It is App-XRD specific, and the image build workflow already exists |
| Jump-off links | Optional ConfigMap in `tooling` read by the plugin | Plugin settings (per-user localStorage); build-time constants | GitOps-managed, per-cluster via Flux postBuild, absent means hidden |

## Target architecture

```
App Wizard (Git view)                     Headlamp (live view, per cluster)
┌──────────────────────────┐              ┌───────────────────────────────────┐
│ My apps — cards          │  new tab     │ /c/main/apps/<ns>/<name>          │
│  [podinfo]  [app-wizard] │ ───────────▶ │  header: Ready · Synced · image   │
│   Open ▾  Edit  Decomm.  │              │  graph: App ─ Deployment ─ RS ─ Pod│
│                          │              │         └ Service ─ HTTPRoute ...  │
│ links from wizard.yaml:  │              │  composed resources · pods+logs    │
│  Headlamp (aws-0)        │              │  events · links (ConfigMap)        │
│  Headlamp (gcp-0)        │              └───────────────────────────────────┘
└──────────────────────────┘
```

### The plugin: `container-images/headlamp-plugin-app/`

**Registrations**

| Call | What |
|---|---|
| `registerSidebarEntry` | "Apps", icon `mdi:apps`, url `/apps` |
| `registerRoute('/apps')` | List of every `App` the user can see: name (link to the App page), namespace, Ready, Synced, image, age. Built on `ResourceListView` over an `App` KubeObject class (`cloud.ogenki.io/v1alpha1`, plural `apps`, namespaced) |
| `registerRoute('/apps/:namespace/:name')` | The App page |
| `registerDetailsViewHeaderAction` | On Headlamp's built-in page for an `App` CR: "Open App view" |
| `registerKindIcon('App')` | So App nodes are recognisable in every Map |
| `registerMapSource` | One source, "Apps", for the global Map: App nodes plus edges to direct children |

**The App page** (top to bottom)

1. Header: name, namespace, `Ready` and `Synced` chips from `status.conditions`,
   image from `spec.image`, route hostname from `spec.route` when enabled.
2. Graph: `GraphView` at roughly 60vh with `defaultSources: []` (built-ins
   excluded, plugin sources appended), `defaultNodeSelection` = the App's UID,
   `defaultFilters: [{type: 'namespace', namespaces: {ns}}]`. The plugin's
   page-scoped source supplies the whole tree, so only this app is drawn.
3. Composed resources: one row per node of the tree except pods — kind, name,
   status, age; the name links to Headlamp's own page for that object.
4. Pods: the pods owned by the app's Deployments and CronJobs, with the
   `WorkloadLogs` component exported in 0.45.0 for inline logs.
5. Events: for the App object and its Deployment.
6. Links: rendered from the ConfigMap, hidden when it is absent or forbidden.

**Tree resolver** — `buildAppTree(app, fetch)`, a pure function over an
injected fetcher so it is unit-testable.

- Breadth-first over `spec.crossplane.resourceRefs`. Each ref's plural and
  scope come from API discovery (`GET /apis/<group>/<version>`, or `/api/v1`
  for core), cached per apiVersion for the page's lifetime. Namespaced refs are
  fetched in the App's namespace.
- A fetched object that carries `spec.crossplane.resourceRefs` is a nested XR
  and is expanded the same way. Managed resources are leaves.
- Deployments and CronJobs pull their ReplicaSets, Jobs and Pods by
  ownerReference from namespace-scoped lists (`useList` on the built-in
  classes), so the workload chain is drawn without built-in Map sources.
- Node id = `metadata.uid`. Edges: parent → child, ids `<parent>-<child>`.
- Node status: `Ready` condition for XRs and managed resources; `Available`
  for Deployments; `Accepted` on any parent for HTTPRoutes; phase for Pods;
  `success` for kinds with no condition semantics.
- Cycles and duplicates: a visited set keyed by uid.
- The same resolver at depth one, over every App in the current namespace
  filter, feeds the global "Apps" map source, whose child nodes then merge with
  Headlamp's own by uid.

**Refresh.** Built-in classes come through Headlamp's `useList`/`useGet` hooks,
which are live. Objects fetched through `ApiProxy` are re-read on a fixed
interval (10 s) while the page is mounted.

**Configuration.** An optional ConfigMap `headlamp-plugin-app` in `tooling`
with one key, `links.yaml`, holding a list of `{label, url}` where `url` may
use `{namespace}` and `{name}`. Values are Flux-substituted per cluster
(`${private_domain_name}`), so the same manifest serves both clouds. The
GitHub entry uses a code-search URL keyed on the App name, because the App
object does not know its stack directory.

**Packaging.** `package.json` name `headlamp-plugin-app`, toolkit
`@kinvolk/headlamp-plugin` 0.14.0 as a devDependency, `headlamp-plugin build`.
The Dockerfile mirrors the official plugins: a node build stage, then a
minimal image exposing `/plugins/headlamp-plugin-app/{main.js,package.json}`
so the existing init-container command (`cp -r /plugins/* /build/plugins/`)
needs no change. The image tag is derived by the build workflow from
`ARG HEADLAMP_PLUGIN_APP_VERSION=v0.1.0` in the Dockerfile — the convention
`token-exchange-proxy` documents — so the HelmRelease pins
`ghcr.io/smana/headlamp-plugin-app:v0.1.0`.

**Tests** (vitest via `headlamp-plugin test`): the resolver on a fixture App
whose refs include a Deployment, a Service, an HTTPRoute and a nested
`SQLInstance` with its own refs — expected node set, edge set, BFS order,
visited-set behaviour on a duplicate ref; the discovery cache (one call per
apiVersion); status mapping per kind; link templating including URL-encoding.
`headlamp-plugin lint` and `tsc` gate the build.

### The wizard: `Smana/app-wizard`, released as v0.3.0

**Config.** Top-level `links` in `wizard.yaml`, file-only like
`branding.theme`:

```yaml
links:
  - label: Headlamp (aws-0)
    url: https://headlamp.priv.aws.ogenki.io/c/main/apps/{namespace}/{name}
  - label: Headlamp (gcp-0)
    url: https://headlamp.priv.gcp.ogenki.io/c/main/apps/{namespace}/{name}
```

Validation at load, in the strict style the loader already uses: `label` and
`url` non-empty, `url` an absolute `http(s)` URL, placeholders limited to
`{namespace}`, `{name}`, `{stack}`. An unknown placeholder fails startup with
the offending entry named. Absent `links` is the default and changes nothing.

**API.** The branding payload (`GET /api/branding`, already unauthenticated,
already fetched on boot, already failure-tolerant in the client) gains
`links: [{label, url}]` with the templates unexpanded. The client expands them
per app with URL-encoded values.

**UI.** `AppList` becomes a responsive card grid. Each card shows name, stack
badge, namespace, type, image, and keeps Edit and Decommission. With one link
the card's open action opens it in a new tab (`noopener`); with several, a
small menu of labels; with none, the card is inert — today's behaviour. Refresh
and the decommission flow are unchanged.

**Tests.** Config: parse, each validation rule, absent key. Branding handler:
links present in the payload. `AppList`: zero, one and two links; the expanded
URL for a given app; the menu labels.

**Docs.** `docs/configuration.md` gains a `links` section; `examples/wizard.yaml`
gains a commented entry.

### Platform wiring in cloud-native-ref

- `tooling/base/headlamp/helmrelease.yaml`: chart `0.44.0` → `0.45.0` (values
  diff between the two is one new optional key; the gcp-0 proxy-auth patch is
  unaffected), plus a fourth init container, `app-plugin`, identical in shape to
  the Flux one and pinned to `ghcr.io/smana/headlamp-plugin-app:v0.1.0`.
- `tooling/base/headlamp/configmap-plugin-app.yaml`: the links ConfigMap.
- `apps/platform/app-wizard/app.yaml`: image tag → `v0.3.0`.
  `apps/platform/app-wizard/wizard.yaml`: the two `links` above.

## Stages

1. **Wizard bug fixes** (`Smana/app-wizard`, no design needed): the inventory
   ignores `layout` (`internal/appstore/appstore.go`) and the removal PR body
   hardcodes `apps/%s/%s/` (`internal/pr/pr.go`). Found during this review.
2. **Wizard links + cards** (`Smana/app-wizard`) → tag `v0.3.0`, image
   published by its own CI.
3. **Headlamp 0.45.0** (cloud-native-ref): a version bump PR on its own, so the
   chart change is bisectable.
4. **Plugin source** (cloud-native-ref): `container-images/headlamp-plugin-app/`
   with tests, plus ADR-0035, this spec, and the docs. Merging to `main`
   publishes the image; PR builds do not push.
5. **Wiring** (cloud-native-ref): the init container pin, the ConfigMap, the
   wizard pin and links. Separate from 4 because the pin must reference an
   image that exists.

## Records and documentation

- **ADR-0035** — own Headlamp plugin for the App view, over the third-party
  Crossplane plugin and over Headlamp's built-in pages plus a Map deep link.
- The GitOps page that lists Headlamp plugins
  (`website/content/docs/platform/gitops/_index.md`) gains the App plugin.
- The App Wizard page
  (`website/content/docs/platform/developer-platform/app-wizard.md`) gains a
  short "From a card to the running app" section with the two-cluster link
  behaviour.
- A doc claim in `.doc-claims.yaml` ties the sentence "requires Headlamp
  0.45.0 or later" to the chart version in the HelmRelease.
- `container-images/README.md` directory listing gains the plugin.

## Security considerations

- The wizard's blast radius is unchanged: no new credentials, no new egress,
  no cluster access. Links are static templates from a platform-reviewed file.
- The plugin runs in the user's browser with the user's Headlamp identity; it
  reads, never writes. Every request goes through Headlamp's API proxy under
  the user's RBAC. Reading the ConfigMap needs `get` on configmaps in
  `tooling`, which `view` grants.
- The init container follows the existing plugin pattern: pinned tag,
  `allowPrivilegeEscalation: false`, an emptyDir. The image is built by the
  repo's own workflow and scanned by Trivy.
- Opened links use `noopener`; templated values are URL-encoded.

## Risks and items to verify on a live cluster

| Risk | Check | Fallback |
|---|---|---|
| `GraphView` props or behaviour differ from the 0.45.0 source read here | First implementation step: render an empty `GraphView` from the plugin on aws-0 | Stage the page with the redirect-into-Map variant (same skeleton, no embedded graph) |
| Runtime-global access breaks on a toolkit release that adds the export | The local type declaration is deleted when `@kinvolk/headlamp-plugin` ≥ 0.15 lands; Renovate flags the bump | None needed |
| A future non-admin group cannot read Apps or composed kinds | When such a group is added: `kubectl auth can-i list apps.cloud.ogenki.io --as=<principal> --as-group=<group>` | A ClusterRole aggregating those reads into `view` |
| Discovery per apiVersion is slow on a large tree | Measure page load for `complete` on aws-0 | Pre-seed the cache with the kinds the composition renders |
| The wizard lists an app whose PR is not merged | The App page says "not found in this cluster — is the PR merged?" and links back to the list | — |
| Two Headlamp instances, one plugin build | The plugin has no cluster-specific code; all per-cluster values are in the ConfigMap | — |

## Success criteria

1. On aws-0, clicking `podinfo`'s card in the wizard opens
   `https://headlamp.priv.aws.ogenki.io/c/main/apps/demo/podinfo` in a new tab.
2. That page renders the graph with the App node selected, and the node count
   equals the number of entries in `spec.crossplane.resourceRefs` (recursively)
   plus the ReplicaSets and Pods owned by its workloads.
3. The composed-resources table lists every `resourceRefs` entry with a
   non-empty status, and each name links to a Headlamp page that loads.
4. The global Map shows the "Apps" source with App nodes and edges to their
   direct children.
5. `flux get hr headlamp -n tooling` is Ready at chart 0.45.0 on both clusters,
   and the plugin appears under Settings → Plugins.
6. With two `links` configured, a card shows a two-entry menu; with `links`
   absent, the existing wizard tests pass unchanged.
7. `./scripts/validate-manifests.sh` exits 0 with `Invalid: 0, Skipped: 0`;
   `./scripts/validate-links.sh` and `./scripts/validate-doc-claims.sh` exit 0.
8. On gcp-0 the App page loads for `demo/podinfo` through oauth2-proxy and the
   token exchange, with the same graph and tables as on aws-0.

## Out of scope, restated

Wizard cluster access, write actions from Headlamp, Headlamp Projects, new
dashboards, a generic Crossplane browser.
