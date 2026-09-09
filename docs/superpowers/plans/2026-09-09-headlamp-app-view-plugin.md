# Headlamp App View — Plugin and Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Headlamp plugin, owned in this repo, that renders a dedicated page for one `App` claim — status, the resource graph scoped to that app, composed resources, pods, events and jump-off links — reachable at a URL the App Wizard builds from namespace and name alone.

**Architecture:** Headlamp 0.45.0 exports its Map renderer to plugins. The plugin registers a route at `/apps/:namespace/:name`, resolves the App's resource tree by walking `spec.crossplane.resourceRefs` (recursing into nested XRs, then attaching owned ReplicaSets/Jobs/Pods), and feeds that tree to an embedded `GraphView` with built-in sources switched off. The same resolver at depth one supplies an "Apps" source to the global Map. Jump-off links come from an optional ConfigMap so they are GitOps-managed and per-cluster.

**Tech Stack:** TypeScript + React 18 via `@kinvolk/headlamp-plugin` 0.14.0 (Vitest for tests), Docker multi-stage init-container image, Flux HelmRelease, Kustomize.

**Spec:** `docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md`. This plan implements its "The plugin", "Platform wiring" and "Records and documentation" sections, plus stages 3, 4 and 5.

**Companion plan:** `docs/superpowers/plans/2026-09-09-headlamp-app-view-wizard.md` (the `Smana/app-wizard` side). Task 7 here depends on its v0.3.0 release.

## Global Constraints

- **Headlamp ≥ 0.45.0 is a hard requirement.** `pluginLib.ResourceMap` (the `GraphView` export) landed in 0.45.0, released 2026-08-20. The repo pins chart 0.44.0 today; Task 1 bumps it and must merge before Task 6 can be verified live.
- **Plugin toolkit `@kinvolk/headlamp-plugin` 0.14.0 predates that export.** Its externals map does not know `ResourceMap`, so a bare import resolves to `undefined` at runtime. The plugin reads `window.pluginLib.ResourceMap` with a local type declaration. Delete that shim when a toolkit ≥ 0.15 ships the export.
- **In-cluster context name is `main`** on both EKS and GKE, so plugin routes registered with the default `useClusterURL: true` live at `/c/main/<path>`. The wizard links must use exactly that.
- **`/apps` does not collide** with any built-in Headlamp route in 0.45.0 (verified against `frontend/src/lib/router/index.tsx`).
- **The plugin reads, never writes.** Every request goes through Headlamp's API proxy under the viewer's own RBAC. No `create`, `patch`, `delete`, no `exec`.
- **Image tags:** the build workflow derives the semver tag from `ARG HEADLAMP_PLUGIN_APP_VERSION=` in the Dockerfile (`.github/workflows/build-container-images.yml`, the `app-version` step, uppercased image name). Keep it in step with `VERSION` in `build.sh`. The HelmRelease pins that exact tag, never `latest`.
- **PR builds do not push.** A pin can only reference an image built from `main`, which is why the plugin source (Task 5) and the wiring (Task 7) are separate PRs.
- **Evidence before "done":** `./scripts/validate-manifests.sh` must exit 0 reporting `Invalid: 0, Skipped: 0`; `./scripts/validate-links.sh` and `./scripts/validate-doc-claims.sh` must exit 0. Cite the output.
- Commit messages and PR bodies in English, conventional prefixes, no co-author trailers.
- Work in the existing worktree: `/home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view`, branch `worktree-headlamp-app-view`, which already holds the design spec and both plans.

---

## File structure

| File | Responsibility |
|---|---|
| `tooling/base/headlamp/helmrelease.yaml` | Chart 0.45.0; a fourth init container copies the plugin |
| `tooling/base/headlamp/configmap-plugin-app.yaml` (new) | `links.json` — the jump-off link templates, Flux-substituted per cluster |
| `tooling/base/headlamp/kustomization.yaml` | Adds the ConfigMap |
| `container-images/headlamp-plugin-app/Dockerfile` (new) | Node build (lint + tsc + tests) → minimal init-container image |
| `container-images/headlamp-plugin-app/build.sh`, `README.md` (new) | Local build, docs — matching `token-exchange-proxy` |
| `container-images/headlamp-plugin-app/package.json`, `tsconfig.json` (new) | Toolkit wiring |
| `.../src/headlamp-plugin.d.ts` (new) | Toolkit types + the `pluginLib.ResourceMap` runtime shim |
| `.../src/app.ts` (new) | The `App` KubeObject class and the shared TypeScript types |
| `.../src/tree.ts` + `tree.test.ts` (new) | `buildAppTree`, `attachOwned` — pure, over an injected client |
| `.../src/status.ts` + `status.test.ts` (new) | `nodeStatus` — kind-aware health |
| `.../src/links.ts` + `links.test.ts` (new) | `parseLinks`, `expandLink` |
| `.../src/client.ts` (new) | `ApiProxy`-backed `ApiClient` with the per-apiVersion discovery cache |
| `.../src/useAppTree.ts` (new) | React hook: tree + pods + refresh interval |
| `.../src/mapSource.tsx` (new) | The "Apps" `GraphSource` for the global Map |
| `.../src/AppsListPage.tsx`, `AppPage.tsx` (new) | The two pages |
| `.../src/index.tsx` (new) | Every `register*` call, in one place |
| `website/content/docs/decisions/0035-own-headlamp-plugin-for-the-app-view.md` (new) | ADR |
| `website/content/docs/decisions/_index.md` | ADR index row |
| `website/content/docs/platform/gitops/_index.md` | Plugin list |
| `website/content/docs/platform/developer-platform/app-wizard.md` | "From a card to the running app" |
| `.doc-claims.yaml` | `headlamp-chart-version` claim |
| `container-images/README.md` | Directory listing |
| `apps/platform/app-wizard/{app.yaml,wizard.yaml}` | v0.3.0 pin + the two links |

---

### Task 1: Headlamp 0.45.0

**Files:**
- Modify: `tooling/base/headlamp/helmrelease.yaml:12` (chart version)
- Test: `./scripts/validate-manifests.sh`

**Interfaces:**
- Produces: a cluster running Headlamp 0.45.0, where `window.pluginLib.ResourceMap` exists. Every later task depends on it.

- [ ] **Step 1: Confirm the values contract did not change**

```bash
cd /home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view
helm show values headlamp --repo https://kubernetes-sigs.github.io/headlamp/ --version 0.44.0 > /tmp/hl-44.yaml
helm show values headlamp --repo https://kubernetes-sigs.github.io/headlamp/ --version 0.45.0 > /tmp/hl-45.yaml
diff /tmp/hl-44.yaml /tmp/hl-45.yaml
```

Expected: only the two added `clusterInventory` keys (`namespaces`, and its comment). Nothing this repo sets is touched — `config.oidc.externalSecret`, `config.extraArgs`, `initContainers`, `volumes`, `clusterRoleBinding`, `unsafeUseServiceAccountToken` all keep their shape. If anything else differs, stop and reconcile before continuing.

- [ ] **Step 2: Bump the chart**

In `tooling/base/headlamp/helmrelease.yaml`, `spec.chart.spec.version`:

```yaml
      version: "0.45.0"
```

- [ ] **Step 3: Validate**

Run: `./scripts/validate-manifests.sh`
Expected: exit 0, report line `Invalid: 0, Skipped: 0`.

- [ ] **Step 4: Commit and open the PR**

```bash
git add tooling/base/headlamp/helmrelease.yaml
git commit -m "chore(headlamp): chart 0.44.0 -> 0.45.0

0.45.0 exports the resource map's GraphView and KubeIcon through pluginLib, so
a plugin can embed the graph on its own page instead of deep-linking into the
global map. Prerequisite for the App view plugin. The values diff between the
two charts is two added optional clusterInventory keys; nothing this repo sets
changed shape."
git push -u origin worktree-headlamp-app-view
gh pr create --base main --title "chore(headlamp): chart 0.45.0" --body "Prerequisite for the App view plugin — 0.45.0 is the first release that lets a plugin embed the resource map's GraphView on its own page (kubernetes-sigs/headlamp#6992).

Values diff 0.44.0 → 0.45.0 is two added optional \`clusterInventory\` keys. The gcp-0 proxy-auth patch and the three plugin init containers are unaffected.

Design: \`docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md\`"
```

- [ ] **Step 5: Merge and confirm on the cluster**

After CI is green and the PR merges:

```bash
flux reconcile kustomization tooling --with-source
kubectl get hr headlamp -n tooling -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"  chart="}{.status.history[0].chartVersion}{"\n"}'
```

Expected: `True  chart=0.45.0`. Then open `https://headlamp.priv.aws.ogenki.io`, and in the browser console run `Object.keys(window.pluginLib.ResourceMap)`.
Expected: an array containing `GraphView` and `KubeIcon`. This is the fact the whole plan rests on; if it is missing, stop.

> The spec's design doc and both plans are already committed on this branch. Push them with this PR or ahead of it — they are documentation and gate nothing.

---

### Task 2: Plugin scaffold that builds and ships

**Files:**
- Create: `container-images/headlamp-plugin-app/{package.json,tsconfig.json,Dockerfile,build.sh,README.md,.gitignore}`, `container-images/headlamp-plugin-app/src/{index.tsx,headlamp-plugin.d.ts}`
- Test: the image build itself

**Interfaces:**
- Produces: an npm project where `npm run lint`, `npm run tsc`, `npm test` and `npm run build` work, and an image whose `/plugins/headlamp-plugin-app/` holds `main.js` + `package.json`.
- Consumed by: every later plugin task.

- [ ] **Step 1: Scaffold the project**

```bash
cd /home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view
mkdir -p container-images/headlamp-plugin-app/src
cd container-images/headlamp-plugin-app
```

`package.json`:

```json
{
  "name": "headlamp-plugin-app",
  "version": "0.1.0",
  "description": "A Headlamp view for one cloud.ogenki.io App claim: status, resource graph, composed resources, pods and events.",
  "private": true,
  "scripts": {
    "start": "headlamp-plugin start",
    "build": "headlamp-plugin build",
    "format": "headlamp-plugin format",
    "lint": "headlamp-plugin lint",
    "tsc": "headlamp-plugin tsc",
    "test": "headlamp-plugin test"
  },
  "keywords": ["headlamp", "headlamp-plugin", "kubernetes", "crossplane"],
  "prettier": "@headlamp-k8s/eslint-config/prettier-config",
  "eslintConfig": {
    "extends": ["@headlamp-k8s", "prettier", "plugin:jsx-a11y/recommended"]
  },
  "overrides": {
    "typescript": "5.6.2"
  },
  "devDependencies": {
    "@kinvolk/headlamp-plugin": "^0.14.0"
  }
}
```

`tsconfig.json`:

```json
{
  "extends": "./node_modules/@kinvolk/headlamp-plugin/config/plugins-tsconfig.json",
  "include": ["./src/**/*"]
}
```

`.gitignore`:

```
node_modules/
dist/
```

- [ ] **Step 2: Write the type shim**

`src/headlamp-plugin.d.ts`:

```ts
/// <reference types="@kinvolk/headlamp-plugin" />

// Headlamp 0.45.0 exports the resource map's renderer to plugins through
// pluginLib.ResourceMap (kubernetes-sigs/headlamp#6992). The published plugin
// toolkit (0.14.0, May 2026) predates that: its externals map does not know
// the module, so `import { GraphView } from '@kinvolk/headlamp-plugin/lib/...'`
// compiles and then resolves to undefined at runtime.
//
// Until a toolkit >= 0.15 ships the export, we read the runtime global and
// declare its shape here. DELETE THIS BLOCK, and import normally, on the first
// toolkit release that carries ResourceMap.
declare global {
  interface Window {
    pluginLib: {
      ResourceMap: {
        GraphView: React.ComponentType<{
          height?: string;
          defaultNodeSelection?: string;
          defaultSources?: unknown[];
          defaultRelations?: unknown[];
          defaultFilters?: Array<
            { type: 'hasErrors' } | { type: 'namespace'; namespaces: Set<string> }
          >;
        }>;
        KubeIcon: React.ComponentType<{ kind: string; width?: string; height?: string }>;
      };
    };
  }
}

export {};
```

- [ ] **Step 3: Write a placeholder entry point**

`src/index.tsx`:

```tsx
// Registrations for the App view plugin. Every register* call lives here; the
// pages and the map source are imported from their own modules.
import { registerSidebarEntry } from '@kinvolk/headlamp-plugin/lib';

registerSidebarEntry({
  name: 'ogenki-apps',
  label: 'Apps',
  icon: 'mdi:apps',
  url: '/apps',
});
```

- [ ] **Step 4: Install and build**

```bash
npm install
npm run lint && npm run tsc && npm run build
ls -l dist/main.js
```

Expected: `lint` and `tsc` clean, `dist/main.js` written. (`npm test` has no test files yet; it is exercised from Task 3 onward.)

- [ ] **Step 4b: Check which registration functions this toolkit actually exposes**

The toolkit is a year-old pin relative to the Headlamp we run, so confirm the four
registrations this plan uses exist in its type definitions before building on them:

```bash
grep -rhoE "export declare function register[A-Za-z]+" node_modules/@kinvolk/headlamp-plugin/types/plugin/registry.d.ts | sort -u
```

Expected: the list contains `registerRoute`, `registerSidebarEntry`,
`registerDetailsViewHeaderAction`, `registerMapSource` and `registerKindIcon`.
(If the `types/` path differs, find it with
`ls node_modules/@kinvolk/headlamp-plugin` and grep the declaration files there.)

**If `registerKindIcon` is missing**, it is the one optional registration in this
plan: drop that single call from Task 5 step 5 and note it in the plugin README.
App nodes then draw with Headlamp's default icon. **If `registerMapSource` is
missing**, stop — the "Apps" map source cannot be built with this toolkit, and
the toolkit pin needs raising before Task 5.

- [ ] **Step 5: Write the Dockerfile**

`Dockerfile`:

```dockerfile
# This ARG is what makes CI publish the tag the HelmRelease pins.
# .github/workflows/build-container-images.yml derives a version tag from
# `ARG <IMAGE_NAME_UPPERCASED>_VERSION=` in this file; with no such ARG the
# workflow only ever produces `latest` and `<branch>-<sha>`, so the pinned
# `:v0.1.0` reference in tooling/base/headlamp/helmrelease.yaml would never
# resolve and the init container would ImagePullBackOff. Keep this in step
# with VERSION in build.sh.
ARG HEADLAMP_PLUGIN_APP_VERSION=v0.1.0

# Build stage. The gates run here on purpose: this repo's container build
# workflow is the only CI that ever looks at this directory, and it runs on
# pull requests (building without pushing). A broken plugin therefore fails the
# PR rather than shipping.
FROM node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run lint && npm run tsc && npm test && npm run build

# Runtime: an init container whose only job is to copy the built plugin into
# the shared plugins volume before Headlamp starts. Headlamp's chart mounts
# that volume at /build/plugins and the existing init containers all run
# `cp -r /plugins/* /build/plugins/`, so the layout below is what they expect.
FROM alpine:3
COPY --from=build /src/dist/main.js /plugins/headlamp-plugin-app/main.js
COPY --from=build /src/package.json /plugins/headlamp-plugin-app/package.json
```

`build.sh`:

```bash
#!/bin/bash
set -e

# Configuration — keep VERSION in step with ARG HEADLAMP_PLUGIN_APP_VERSION in
# the Dockerfile; CI derives the published semver tag from the ARG.
VERSION="v0.1.0"
REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/smana}"
IMAGE_NAME="headlamp-plugin-app"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"

echo "Building ${FULL_IMAGE}..."

# Local build targets the host platform only; CI builds amd64 + arm64 via
# buildx and pushes the multi-arch manifest.
docker build --platform linux/amd64 -t "${FULL_IMAGE}" -t "${REGISTRY}/${IMAGE_NAME}:latest" .

echo ""
echo "✅ Build successful."
echo ""
echo "To verify the image carries the plugin:"
echo "  docker run --rm ${FULL_IMAGE} ls -l /plugins/headlamp-plugin-app/"
echo "  # expect main.js and package.json"
```

Then `chmod +x build.sh`.

- [ ] **Step 6: Build the image and verify its contents**

```bash
./build.sh
docker run --rm ghcr.io/smana/headlamp-plugin-app:v0.1.0 ls -l /plugins/headlamp-plugin-app/
```

Expected: the build succeeds (lint, tsc, test and build all run inside it) and the listing shows `main.js` and `package.json`.

- [ ] **Step 7: Write the README**

`README.md`:

```markdown
# headlamp-plugin-app

A [Headlamp](https://headlamp.dev) plugin that gives one `App`
(`cloud.ogenki.io/v1alpha1`, a Crossplane v2 namespaced composite resource) a
page of its own: Ready/Synced status, the resource graph scoped to that app,
its composed resources, its pods and events, and links out to Grafana,
VictoriaLogs and the source in Git.

It exists so a card in the [App Wizard](https://app-wizard.priv.aws.ogenki.io)
can open a live view of the app it declares. The wizard holds no cluster
credentials; the link is the whole bridge.

## Routes

| Path | Page |
|------|------|
| `/c/main/apps` | Every App the viewer can see |
| `/c/main/apps/<namespace>/<name>` | One App — this is the URL the wizard builds |

`main` is Headlamp's in-cluster context name on both clusters.

## Requirements

**Headlamp ≥ 0.45.0.** The embedded graph uses `pluginLib.ResourceMap.GraphView`,
first exported in that release.

## Configuration

Optional ConfigMap `headlamp-plugin-app` in the `tooling` namespace, key
`links.json`: a JSON array of `{"label": "...", "url": "..."}` whose URL may use
`{namespace}` and `{name}`. Absent or unreadable ⇒ the links section is hidden.
It is rendered from `tooling/base/headlamp/configmap-plugin-app.yaml`, with
`${private_domain_name}` substituted per cluster by Flux.

## Development

```bash
npm install
npm test          # vitest, via the plugin toolkit
npm run lint      # eslint + prettier
npm run tsc       # type-check
npm run build     # -> dist/main.js
npm start         # watch mode against a local Headlamp
```

The image is an init container: it carries `/plugins/headlamp-plugin-app/` and
the Headlamp chart's init containers copy that into the shared plugins volume.
```

- [ ] **Step 8: Commit**

```bash
cd /home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view
git add container-images/headlamp-plugin-app
git commit -m "feat(headlamp-plugin-app): scaffold the plugin and its init-container image"
```

---

### Task 3: The resource tree, resolved

**Files:**
- Create: `container-images/headlamp-plugin-app/src/app.ts`, `src/tree.ts`, `src/tree.test.ts`
- Test: `container-images/headlamp-plugin-app/src/tree.test.ts`

**Interfaces:**
- Produces:
  ```ts
  // app.ts
  export interface KubeJSON {
    apiVersion: string; kind: string;
    metadata: { name: string; namespace?: string; uid: string; creationTimestamp?: string;
                ownerReferences?: Array<{ uid: string; kind: string; name: string }>; };
    spec?: Record<string, unknown>; status?: Record<string, unknown>;
  }
  export interface ResourceRef { apiVersion: string; kind: string; name: string; namespace?: string }
  export function resourceRefs(obj: KubeJSON): ResourceRef[]
  // tree.ts
  export interface ApiResourceInfo { kind: string; name: string; namespaced: boolean }
  export interface ApiClient {
    discover(apiVersion: string): Promise<ApiResourceInfo[]>;
    getObject(apiVersion: string, plural: string, namespace: string | undefined, name: string): Promise<KubeJSON | null>;
  }
  export interface TreeNode { id: string; object: KubeJSON; depth: number }
  export interface TreeEdge { id: string; source: string; target: string }
  export interface AppTree { nodes: TreeNode[]; edges: TreeEdge[]; unresolved: ResourceRef[] }
  export function buildAppTree(root: KubeJSON, client: ApiClient, maxDepth?: number): Promise<AppTree>
  export function attachOwned(tree: AppTree, candidates: KubeJSON[]): AppTree
  ```
- Consumed by: Tasks 5 (map source) and 6 (the page).

- [ ] **Step 1: Write the failing tests**

`src/tree.test.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import type { KubeJSON } from './app';
import { attachOwned, buildAppTree, type ApiClient, type ApiResourceInfo } from './tree';

function obj(
  kind: string,
  name: string,
  uid: string,
  extra: Partial<KubeJSON> = {},
  apiVersion = 'cloud.ogenki.io/v1alpha1',
): KubeJSON {
  return {
    apiVersion,
    kind,
    metadata: { name, namespace: 'demo', uid, ...(extra.metadata ?? {}) },
    spec: extra.spec,
    status: extra.status,
  } as KubeJSON;
}

function refs(...items: Array<[string, string, string]>) {
  return { crossplane: { resourceRefs: items.map(([apiVersion, kind, name]) => ({ apiVersion, kind, name })) } };
}

// The App and one nested XR (SQLInstance) that has refs of its own.
const app = obj('App', 'podinfo', 'uid-app', {
  spec: refs(
    ['apps/v1', 'Deployment', 'xplane-podinfo'],
    ['v1', 'Service', 'xplane-podinfo'],
    ['cloud.ogenki.io/v1alpha1', 'SQLInstance', 'xplane-podinfo-db'],
  ),
});
const deployment = obj('Deployment', 'xplane-podinfo', 'uid-deploy', {}, 'apps/v1');
const service = obj('Service', 'xplane-podinfo', 'uid-svc', {}, 'v1');
const sql = obj('SQLInstance', 'xplane-podinfo-db', 'uid-sql', {
  spec: refs(['postgresql.sql.crossplane.io/v1alpha1', 'Database', 'xplane-podinfo-db']),
});
const database = obj('Database', 'xplane-podinfo-db', 'uid-db', {}, 'postgresql.sql.crossplane.io/v1alpha1');

const catalog: Record<string, ApiResourceInfo[]> = {
  'cloud.ogenki.io/v1alpha1': [
    { kind: 'App', name: 'apps', namespaced: true },
    { kind: 'SQLInstance', name: 'sqlinstances', namespaced: true },
  ],
  'apps/v1': [{ kind: 'Deployment', name: 'deployments', namespaced: true }],
  v1: [{ kind: 'Service', name: 'services', namespaced: true }],
  'postgresql.sql.crossplane.io/v1alpha1': [{ kind: 'Database', name: 'databases', namespaced: false }],
};
const store: Record<string, KubeJSON> = {
  'deployments/xplane-podinfo': deployment,
  'services/xplane-podinfo': service,
  'sqlinstances/xplane-podinfo-db': sql,
  'databases/xplane-podinfo-db': database,
};

function fakeClient(overrides: Partial<ApiClient> = {}): ApiClient {
  return {
    discover: vi.fn(async (apiVersion: string) => catalog[apiVersion] ?? []),
    getObject: vi.fn(async (_av, plural, _ns, name) => store[`${plural}/${name}`] ?? null),
    ...overrides,
  };
}

describe('buildAppTree', () => {
  it('walks resourceRefs and recurses into a nested XR', async () => {
    const tree = await buildAppTree(app, fakeClient());

    expect(tree.nodes.map(n => n.id).sort()).toEqual(
      ['uid-app', 'uid-db', 'uid-deploy', 'uid-sql', 'uid-svc'].sort(),
    );
    expect(tree.nodes.find(n => n.id === 'uid-app')!.depth).toBe(0);
    expect(tree.nodes.find(n => n.id === 'uid-sql')!.depth).toBe(1);
    expect(tree.nodes.find(n => n.id === 'uid-db')!.depth).toBe(2);
    expect(tree.edges).toContainEqual({ id: 'uid-app-uid-sql', source: 'uid-app', target: 'uid-sql' });
    expect(tree.edges).toContainEqual({ id: 'uid-sql-uid-db', source: 'uid-sql', target: 'uid-db' });
    expect(tree.unresolved).toEqual([]);
  });

  it('discovers each apiVersion at most once', async () => {
    const client = fakeClient();
    await buildAppTree(app, client);
    const seen = (client.discover as ReturnType<typeof vi.fn>).mock.calls.map(c => c[0]);
    expect(new Set(seen).size).toBe(seen.length);
  });

  it('resolves a cluster-scoped ref with no namespace', async () => {
    const client = fakeClient();
    await buildAppTree(app, client);
    const call = (client.getObject as ReturnType<typeof vi.fn>).mock.calls.find(c => c[1] === 'databases');
    expect(call![2]).toBeUndefined();
  });

  it('records a ref it cannot resolve and still returns the rest', async () => {
    const orphan = obj('App', 'x', 'uid-x', { spec: refs(['v1', 'Service', 'missing']) });
    const tree = await buildAppTree(orphan, fakeClient());
    expect(tree.nodes.map(n => n.id)).toEqual(['uid-x']);
    expect(tree.unresolved).toEqual([{ apiVersion: 'v1', kind: 'Service', name: 'missing' }]);
  });

  it('records a ref whose kind is not in discovery', async () => {
    const weird = obj('App', 'x', 'uid-x', { spec: refs(['nope.example.com/v1', 'Ghost', 'g']) });
    const tree = await buildAppTree(weird, fakeClient());
    expect(tree.unresolved).toHaveLength(1);
    expect(tree.nodes).toHaveLength(1);
  });

  it('visits a repeated ref once', async () => {
    const dup = obj('App', 'x', 'uid-x', {
      spec: refs(['v1', 'Service', 'xplane-podinfo'], ['v1', 'Service', 'xplane-podinfo']),
    });
    const tree = await buildAppTree(dup, fakeClient());
    expect(tree.nodes.filter(n => n.id === 'uid-svc')).toHaveLength(1);
    expect(tree.edges).toHaveLength(1);
  });

  it('stops at maxDepth', async () => {
    const tree = await buildAppTree(app, fakeClient(), 1);
    expect(tree.nodes.map(n => n.id).sort()).toEqual(['uid-app', 'uid-deploy', 'uid-sql', 'uid-svc'].sort());
  });
});

describe('attachOwned', () => {
  it('adds transitively owned objects with their edges', async () => {
    const tree = await buildAppTree(app, fakeClient());
    const rs = obj('ReplicaSet', 'xplane-podinfo-abc', 'uid-rs', {
      metadata: { name: 'xplane-podinfo-abc', namespace: 'demo', uid: 'uid-rs', ownerReferences: [{ uid: 'uid-deploy', kind: 'Deployment', name: 'xplane-podinfo' }] },
    } as Partial<KubeJSON>, 'apps/v1');
    const pod = obj('Pod', 'xplane-podinfo-abc-1', 'uid-pod', {
      metadata: { name: 'xplane-podinfo-abc-1', namespace: 'demo', uid: 'uid-pod', ownerReferences: [{ uid: 'uid-rs', kind: 'ReplicaSet', name: 'xplane-podinfo-abc' }] },
    } as Partial<KubeJSON>, 'v1');
    const unrelated = obj('Pod', 'other', 'uid-other', {}, 'v1');

    const withPods = attachOwned(tree, [pod, rs, unrelated]);

    expect(withPods.nodes.map(n => n.id)).toContain('uid-rs');
    expect(withPods.nodes.map(n => n.id)).toContain('uid-pod');
    expect(withPods.nodes.map(n => n.id)).not.toContain('uid-other');
    expect(withPods.edges).toContainEqual({ id: 'uid-deploy-uid-rs', source: 'uid-deploy', target: 'uid-rs' });
    expect(withPods.edges).toContainEqual({ id: 'uid-rs-uid-pod', source: 'uid-rs', target: 'uid-pod' });
  });

  it('is order-independent and never duplicates a node', async () => {
    const tree = await buildAppTree(app, fakeClient());
    const rs = obj('ReplicaSet', 'rs', 'uid-rs', {
      metadata: { name: 'rs', namespace: 'demo', uid: 'uid-rs', ownerReferences: [{ uid: 'uid-deploy', kind: 'Deployment', name: 'xplane-podinfo' }] },
    } as Partial<KubeJSON>, 'apps/v1');
    const a = attachOwned(tree, [rs, rs]);
    expect(a.nodes.filter(n => n.id === 'uid-rs')).toHaveLength(1);
    expect(a.edges.filter(e => e.id === 'uid-deploy-uid-rs')).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run to confirm they fail**

Run: `cd container-images/headlamp-plugin-app && npm test`
Expected: FAIL — cannot resolve `./tree` / `./app`.

- [ ] **Step 3: Write `src/app.ts`**

```ts
// Shared shapes. `App` is a Crossplane v2 namespaced composite resource: its
// children are listed in spec.crossplane.resourceRefs by apiVersion, kind and
// name — no namespace, no uid — which is why resolving the tree needs API
// discovery rather than a simple lookup.
import { KubeObject } from '@kinvolk/headlamp-plugin/lib/K8s/cluster';

export interface KubeJSON {
  apiVersion: string;
  kind: string;
  metadata: {
    name: string;
    namespace?: string;
    uid: string;
    creationTimestamp?: string;
    labels?: Record<string, string>;
    ownerReferences?: Array<{ uid: string; kind: string; name: string }>;
  };
  spec?: Record<string, any>;
  status?: Record<string, any>;
}

export interface ResourceRef {
  apiVersion: string;
  kind: string;
  name: string;
  namespace?: string;
}

export const APP_API_VERSION = 'cloud.ogenki.io/v1alpha1';
export const APP_KIND = 'App';

/** The App claim, as a Headlamp KubeObject so useList/useGet work on it. */
export class AppResource extends KubeObject<KubeJSON> {
  static apiVersion = APP_API_VERSION;
  static apiName = 'apps';
  static kind = APP_KIND;
  static isNamespaced = true;
}

/**
 * The composed-resource references of a composite resource. Crossplane v2 puts
 * them under spec.crossplane.resourceRefs; v1 put them at spec.resourceRefs.
 * Both are read so a nested XR from an older composition still expands.
 */
export function resourceRefs(obj: KubeJSON): ResourceRef[] {
  const raw = obj.spec?.crossplane?.resourceRefs ?? obj.spec?.resourceRefs;
  if (!Array.isArray(raw)) return [];
  return raw
    .filter(r => r && typeof r.apiVersion === 'string' && typeof r.kind === 'string' && typeof r.name === 'string')
    .map(r => ({ apiVersion: r.apiVersion, kind: r.kind, name: r.name, namespace: r.namespace }));
}
```

- [ ] **Step 4: Write `src/tree.ts`**

```ts
// Resolving an App into a graph. Breadth-first over resourceRefs: each ref
// names an apiVersion and a kind, so the plural and the scope come from API
// discovery (cached per apiVersion). A resolved object that carries refs of its
// own is a nested XR — SQLInstance, KVStore, EPI — and is expanded the same way.
import { resourceRefs, type KubeJSON, type ResourceRef } from './app';

export interface ApiResourceInfo {
  kind: string;
  /** The plural resource name used in the URL path. */
  name: string;
  namespaced: boolean;
}

export interface ApiClient {
  discover(apiVersion: string): Promise<ApiResourceInfo[]>;
  getObject(
    apiVersion: string,
    plural: string,
    namespace: string | undefined,
    name: string,
  ): Promise<KubeJSON | null>;
}

export interface TreeNode {
  id: string;
  object: KubeJSON;
  depth: number;
}

export interface TreeEdge {
  id: string;
  source: string;
  target: string;
}

export interface AppTree {
  nodes: TreeNode[];
  edges: TreeEdge[];
  /** Refs that could not be fetched — absent, forbidden, or an unknown kind. */
  unresolved: ResourceRef[];
}

/** Guards a pathological composition; nothing here nests more than 2 deep. */
const DEFAULT_MAX_DEPTH = 6;

export async function buildAppTree(
  root: KubeJSON,
  client: ApiClient,
  maxDepth: number = DEFAULT_MAX_DEPTH,
): Promise<AppTree> {
  const nodes: TreeNode[] = [{ id: root.metadata.uid, object: root, depth: 0 }];
  const edges: TreeEdge[] = [];
  const unresolved: ResourceRef[] = [];
  const seen = new Set<string>([root.metadata.uid]);

  // One discovery call per apiVersion, whatever the tree's shape.
  const discovered = new Map<string, Promise<ApiResourceInfo[]>>();
  const infoFor = async (apiVersion: string, kind: string): Promise<ApiResourceInfo | undefined> => {
    let p = discovered.get(apiVersion);
    if (!p) {
      p = client.discover(apiVersion).catch(() => [] as ApiResourceInfo[]);
      discovered.set(apiVersion, p);
    }
    return (await p).find(r => r.kind === kind);
  };

  let frontier: TreeNode[] = nodes.slice();
  for (let depth = 1; depth <= maxDepth && frontier.length > 0; depth++) {
    const next: TreeNode[] = [];
    for (const parent of frontier) {
      for (const ref of resourceRefs(parent.object)) {
        const info = await infoFor(ref.apiVersion, ref.kind);
        if (!info) {
          unresolved.push(ref);
          continue;
        }
        const namespace = info.namespaced
          ? (ref.namespace ?? parent.object.metadata.namespace)
          : undefined;
        let child: KubeJSON | null = null;
        try {
          child = await client.getObject(ref.apiVersion, info.name, namespace, ref.name);
        } catch {
          child = null;
        }
        if (!child?.metadata?.uid) {
          unresolved.push(ref);
          continue;
        }
        const id = child.metadata.uid;
        if (!seen.has(id)) {
          seen.add(id);
          const node = { id, object: child, depth };
          nodes.push(node);
          next.push(node);
        }
        const edgeId = `${parent.id}-${id}`;
        if (!edges.some(e => e.id === edgeId)) {
          edges.push({ id: edgeId, source: parent.id, target: id });
        }
      }
    }
    frontier = next;
  }

  return { nodes, edges, unresolved };
}

/**
 * Adds the objects that are transitively owned by something already in the
 * tree: Deployment → ReplicaSet → Pod, CronJob → Job → Pod. Candidates are
 * whole-namespace listings, so most of them belong to other apps and are
 * dropped. Repeated until nothing new attaches, which is what makes the result
 * independent of the order candidates arrive in.
 */
export function attachOwned(tree: AppTree, candidates: KubeJSON[]): AppTree {
  const nodes = tree.nodes.slice();
  const edges = tree.edges.slice();
  const byId = new Map(nodes.map(n => [n.id, n]));
  const edgeIds = new Set(edges.map(e => e.id));

  let added = true;
  while (added) {
    added = false;
    for (const c of candidates) {
      const uid = c.metadata?.uid;
      if (!uid) continue;
      for (const owner of c.metadata.ownerReferences ?? []) {
        const parent = byId.get(owner.uid);
        if (!parent) continue;
        if (!byId.has(uid)) {
          const node = { id: uid, object: c, depth: parent.depth + 1 };
          nodes.push(node);
          byId.set(uid, node);
          added = true;
        }
        const edgeId = `${owner.uid}-${uid}`;
        if (!edgeIds.has(edgeId)) {
          edges.push({ id: edgeId, source: owner.uid, target: uid });
          edgeIds.add(edgeId);
          added = true;
        }
      }
    }
  }

  return { nodes, edges, unresolved: tree.unresolved };
}
```

- [ ] **Step 5: Run the tests**

Run: `npm test`
Expected: PASS — 9 tests across the two describes.

- [ ] **Step 6: Lint and type-check**

Run: `npm run lint && npm run tsc`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
cd /home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view
git add container-images/headlamp-plugin-app/src
git commit -m "feat(headlamp-plugin-app): resolve an App into a node/edge tree

Breadth-first over spec.crossplane.resourceRefs, recursing into nested XRs and
caching API discovery per apiVersion, then attaching transitively owned
ReplicaSets, Jobs and Pods by ownerReference."
```

---

### Task 4: Status and links

**Files:**
- Create: `container-images/headlamp-plugin-app/src/status.ts`, `src/status.test.ts`, `src/links.ts`, `src/links.test.ts`
- Test: both new test files

**Interfaces:**
- Produces:
  ```ts
  export type NodeStatus = 'success' | 'warning' | 'error';
  export function nodeStatus(obj: KubeJSON): NodeStatus            // status.ts
  export function conditionOf(obj: KubeJSON, type: string): { status: string; reason?: string; message?: string } | undefined
  export interface LinkTemplate { label: string; url: string }     // links.ts
  export function parseLinks(raw: string | undefined): LinkTemplate[]
  export function expandLink(url: string, app: { namespace: string; name: string }): string
  ```
- Consumed by: Tasks 5 and 6.

- [ ] **Step 1: Write the failing status tests**

`src/status.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import type { KubeJSON } from './app';
import { conditionOf, nodeStatus } from './status';

function withConditions(kind: string, conditions: any[], apiVersion = 'cloud.ogenki.io/v1alpha1'): KubeJSON {
  return { apiVersion, kind, metadata: { name: 'x', namespace: 'demo', uid: 'u' }, status: { conditions } } as KubeJSON;
}

describe('nodeStatus', () => {
  it('reads Ready on a composite or managed resource', () => {
    expect(nodeStatus(withConditions('SQLInstance', [{ type: 'Ready', status: 'True' }]))).toBe('success');
    expect(nodeStatus(withConditions('SQLInstance', [{ type: 'Ready', status: 'False' }]))).toBe('error');
    expect(nodeStatus(withConditions('SQLInstance', [{ type: 'Ready', status: 'Unknown' }]))).toBe('warning');
  });

  it('reads Available on a Deployment', () => {
    expect(nodeStatus(withConditions('Deployment', [{ type: 'Available', status: 'True' }], 'apps/v1'))).toBe('success');
    expect(nodeStatus(withConditions('Deployment', [{ type: 'Available', status: 'False' }], 'apps/v1'))).toBe('error');
  });

  it('accepts an HTTPRoute when any parent accepted it', () => {
    const route = {
      apiVersion: 'gateway.networking.k8s.io/v1',
      kind: 'HTTPRoute',
      metadata: { name: 'r', namespace: 'demo', uid: 'u' },
      status: { parents: [{ conditions: [{ type: 'Accepted', status: 'False' }] }, { conditions: [{ type: 'Accepted', status: 'True' }] }] },
    } as unknown as KubeJSON;
    expect(nodeStatus(route)).toBe('success');
  });

  it('errors an HTTPRoute with no accepted parent', () => {
    const route = {
      apiVersion: 'gateway.networking.k8s.io/v1',
      kind: 'HTTPRoute',
      metadata: { name: 'r', namespace: 'demo', uid: 'u' },
      status: { parents: [{ conditions: [{ type: 'Accepted', status: 'False' }] }] },
    } as unknown as KubeJSON;
    expect(nodeStatus(route)).toBe('error');
  });

  it('reads a Pod phase', () => {
    const pod = (phase: string) => ({ apiVersion: 'v1', kind: 'Pod', metadata: { name: 'p', namespace: 'demo', uid: 'u' }, status: { phase } }) as unknown as KubeJSON;
    expect(nodeStatus(pod('Running'))).toBe('success');
    expect(nodeStatus(pod('Succeeded'))).toBe('success');
    expect(nodeStatus(pod('Pending'))).toBe('warning');
    expect(nodeStatus(pod('Failed'))).toBe('error');
  });

  it('is success for kinds with no health semantics', () => {
    const svc = { apiVersion: 'v1', kind: 'Service', metadata: { name: 's', namespace: 'demo', uid: 'u' }, spec: { clusterIP: '10.0.0.1' } } as KubeJSON;
    expect(nodeStatus(svc)).toBe('success');
  });

  it('warns when a resource that should have conditions has none yet', () => {
    const fresh = { apiVersion: 'cloud.ogenki.io/v1alpha1', kind: 'SQLInstance', metadata: { name: 'q', namespace: 'demo', uid: 'u' } } as KubeJSON;
    expect(nodeStatus(fresh)).toBe('warning');
  });
});

describe('conditionOf', () => {
  it('returns the matching condition, or undefined', () => {
    const o = withConditions('App', [{ type: 'Synced', status: 'True', reason: 'ReconcileSuccess' }]);
    expect(conditionOf(o, 'Synced')?.reason).toBe('ReconcileSuccess');
    expect(conditionOf(o, 'Ready')).toBeUndefined();
  });
});
```

- [ ] **Step 2: Write the failing links tests**

`src/links.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { expandLink, parseLinks } from './links';

describe('parseLinks', () => {
  it('parses a JSON array of label/url pairs', () => {
    const got = parseLinks('[{"label":"Grafana","url":"https://g/{namespace}"}]');
    expect(got).toEqual([{ label: 'Grafana', url: 'https://g/{namespace}' }]);
  });

  it('returns nothing for absent, empty, malformed or wrongly-shaped input', () => {
    expect(parseLinks(undefined)).toEqual([]);
    expect(parseLinks('')).toEqual([]);
    expect(parseLinks('not json')).toEqual([]);
    expect(parseLinks('{"label":"x"}')).toEqual([]);
    expect(parseLinks('[{"label":"x"},{"url":"https://y"}]')).toEqual([]);
  });

  it('keeps only http(s) URLs', () => {
    expect(parseLinks('[{"label":"a","url":"javascript:alert(1)"},{"label":"b","url":"https://ok"}]')).toEqual([
      { label: 'b', url: 'https://ok' },
    ]);
  });
});

describe('expandLink', () => {
  const app = { namespace: 'demo', name: 'podinfo' };

  it('substitutes and encodes', () => {
    expect(expandLink('https://g/d/x?var-ns={namespace}&var-app={name}', app)).toBe(
      'https://g/d/x?var-ns=demo&var-app=podinfo',
    );
    expect(expandLink('https://g/{name}', { namespace: 'demo', name: 'a b' })).toBe('https://g/a%20b');
  });

  it('leaves unknown placeholders alone', () => {
    expect(expandLink('https://g/{cluster}/{name}', app)).toBe('https://g/{cluster}/podinfo');
  });
});
```

- [ ] **Step 3: Run to confirm both fail**

Run: `npm test`
Expected: FAIL — cannot resolve `./status` and `./links`.

- [ ] **Step 4: Write `src/status.ts`**

```ts
// Mapping a Kubernetes object to one of the map's three node states. Kinds
// differ in where they keep the truth: composites and managed resources use a
// Ready condition, Deployments use Available, HTTPRoutes report per parent, and
// Pods have a phase. A kind with no health semantics (Service, ConfigMap,
// PodDisruptionBudget) exists or it does not, so it is success.
import type { KubeJSON } from './app';

export type NodeStatus = 'success' | 'warning' | 'error';

export interface KubeCondition {
  type: string;
  status: string;
  reason?: string;
  message?: string;
}

export function conditionOf(obj: KubeJSON, type: string): KubeCondition | undefined {
  const conditions = obj.status?.conditions;
  if (!Array.isArray(conditions)) return undefined;
  return conditions.find((c: KubeCondition) => c?.type === type);
}

/** Kinds whose health lives in a condition other than Ready. */
const CONDITION_BY_KIND: Record<string, string> = {
  Deployment: 'Available',
  StatefulSet: 'Available',
};

/** Kinds that carry no health at all: present is healthy. */
const NO_HEALTH = new Set([
  'Service',
  'ServiceAccount',
  'ConfigMap',
  'Secret',
  'PodDisruptionBudget',
  'HorizontalPodAutoscaler',
  'CiliumNetworkPolicy',
  'VMServiceScrape',
  'VMRule',
  'PersistentVolumeClaim',
  'ReplicaSet',
]);

function fromStatus(status: string | undefined): NodeStatus {
  if (status === 'True') return 'success';
  if (status === 'False') return 'error';
  return 'warning';
}

export function nodeStatus(obj: KubeJSON): NodeStatus {
  if (obj.kind === 'Pod') {
    const phase = obj.status?.phase;
    if (phase === 'Running' || phase === 'Succeeded') return 'success';
    if (phase === 'Failed') return 'error';
    return 'warning';
  }

  if (obj.kind === 'HTTPRoute') {
    const parents = obj.status?.parents;
    if (!Array.isArray(parents) || parents.length === 0) return 'warning';
    const accepted = parents.some((p: { conditions?: KubeCondition[] }) =>
      p?.conditions?.some(c => c.type === 'Accepted' && c.status === 'True'),
    );
    return accepted ? 'success' : 'error';
  }

  if (NO_HEALTH.has(obj.kind)) return 'success';

  const conditionType = CONDITION_BY_KIND[obj.kind] ?? 'Ready';
  const condition = conditionOf(obj, conditionType);
  // No condition yet on a kind that should have one means "still settling",
  // which is a warning rather than a failure — a freshly created XR looks
  // exactly like this for a few seconds.
  return condition ? fromStatus(condition.status) : 'warning';
}
```

- [ ] **Step 5: Write `src/links.ts`**

```ts
// Jump-off links, supplied by an optional ConfigMap so they are GitOps-managed
// and per-cluster. JSON rather than YAML: a ConfigMap value is a string either
// way, and JSON needs no parser in the bundle. Anything malformed yields no
// links — the section simply does not render.
export interface LinkTemplate {
  label: string;
  url: string;
}

export function parseLinks(raw: string | undefined): LinkTemplate[] {
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const out: LinkTemplate[] = [];
  for (const entry of parsed) {
    const label = (entry as LinkTemplate)?.label;
    const url = (entry as LinkTemplate)?.url;
    if (typeof label !== 'string' || typeof url !== 'string' || !label || !url) return [];
    if (!/^https?:\/\//.test(url)) continue;
    out.push({ label, url });
  }
  return out;
}

export function expandLink(url: string, app: { namespace: string; name: string }): string {
  const values: Record<string, string> = { namespace: app.namespace, name: app.name };
  return url.replace(/\{(namespace|name)\}/g, (_m, key: string) => encodeURIComponent(values[key]));
}
```

- [ ] **Step 6: Run everything**

Run: `npm test && npm run lint && npm run tsc`
Expected: all PASS, lint and type-check clean.

- [ ] **Step 7: Commit**

```bash
cd /home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view
git add container-images/headlamp-plugin-app/src
git commit -m "feat(headlamp-plugin-app): kind-aware node status and ConfigMap-driven links"
```

---

### Task 5: The API client, the map source and the list page

**Files:**
- Create: `container-images/headlamp-plugin-app/src/client.ts`, `src/useAppTree.ts`, `src/mapSource.tsx`, `src/AppsListPage.tsx`
- Modify: `container-images/headlamp-plugin-app/src/index.tsx`

**Interfaces:**
- Consumes: `buildAppTree`, `attachOwned`, `nodeStatus`, `AppResource` (Tasks 3–4).
- Produces:
  ```ts
  export function makeApiClient(): ApiClient                       // client.ts
  export function useConfigLinks(): LinkTemplate[]                 // client.ts
  export function useAppTree(namespace: string, name: string): { tree: AppTree | null; app: KubeJSON | null; error: string | null }  // useAppTree.ts
  export function graphNodesFrom(tree: AppTree): { nodes: any[]; edges: any[] }   // mapSource.tsx
  export const appsMapSource: GraphSource                          // mapSource.tsx
  export function AppsListPage(): JSX.Element                      // AppsListPage.tsx
  ```
- Consumed by: Task 6.

- [ ] **Step 1: Write `src/client.ts`**

```tsx
// The live side of the resolver: Headlamp's API proxy, plus the ConfigMap read.
// Kept apart from tree.ts so the traversal stays a pure function over an
// injected client and can be tested without a cluster.
import { ApiProxy } from '@kinvolk/headlamp-plugin/lib';
import { useEffect, useState } from 'react';
import type { KubeJSON } from './app';
import { parseLinks, type LinkTemplate } from './links';
import type { ApiClient, ApiResourceInfo } from './tree';

/** /apis/<group>/<version>, or /api/v1 for core resources. */
function apiBase(apiVersion: string): string {
  return apiVersion.includes('/') ? `/apis/${apiVersion}` : `/api/${apiVersion}`;
}

export function makeApiClient(): ApiClient {
  return {
    async discover(apiVersion: string): Promise<ApiResourceInfo[]> {
      const res = await ApiProxy.request(apiBase(apiVersion));
      const list = (res?.resources ?? []) as Array<{ kind: string; name: string; namespaced: boolean }>;
      // Subresources ("pods/log") are never fetchable objects.
      return list
        .filter(r => !r.name.includes('/'))
        .map(r => ({ kind: r.kind, name: r.name, namespaced: r.namespaced }));
    },
    async getObject(apiVersion, plural, namespace, name): Promise<KubeJSON | null> {
      const path = namespace
        ? `${apiBase(apiVersion)}/namespaces/${namespace}/${plural}/${name}`
        : `${apiBase(apiVersion)}/${plural}/${name}`;
      try {
        return (await ApiProxy.request(path)) as KubeJSON;
      } catch {
        // 404 (not created yet) and 403 (RBAC) are both "not available to
        // this viewer"; the caller records the ref as unresolved.
        return null;
      }
    },
  };
}

const LINKS_NAMESPACE = 'tooling';
const LINKS_CONFIGMAP = 'headlamp-plugin-app';

/**
 * Reads the optional links ConfigMap once per mount. A missing ConfigMap or a
 * viewer without `get` on it yields no links and no error: the section is
 * simply not rendered.
 */
export function useConfigLinks(): LinkTemplate[] {
  const [links, setLinks] = useState<LinkTemplate[]>([]);
  useEffect(() => {
    let live = true;
    ApiProxy.request(`/api/v1/namespaces/${LINKS_NAMESPACE}/configmaps/${LINKS_CONFIGMAP}`)
      .then(cm => {
        if (live) setLinks(parseLinks(cm?.data?.['links.json']));
      })
      .catch(() => {
        if (live) setLinks([]);
      });
    return () => {
      live = false;
    };
  }, []);
  return links;
}
```

- [ ] **Step 2: Write `src/useAppTree.ts`**

```tsx
// One App's tree, kept fresh. Objects reached through ApiProxy are polled
// (Headlamp's own hooks are live, but a hand-rolled fetch is not), which is
// enough for a page someone is looking at.
import { K8s } from '@kinvolk/headlamp-plugin/lib';
import { useEffect, useMemo, useState } from 'react';
import { APP_API_VERSION, type KubeJSON } from './app';
import { makeApiClient } from './client';
import { attachOwned, buildAppTree, type AppTree } from './tree';

const REFRESH_MS = 10_000;

export function useAppTree(namespace: string, name: string) {
  const [app, setApp] = useState<KubeJSON | null>(null);
  const [tree, setTree] = useState<AppTree | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  // Live, via Headlamp's own watch: pods and replicasets of the namespace.
  const [pods] = K8s.ResourceClasses.Pod.useList({ namespace });
  const [replicaSets] = K8s.ResourceClasses.ReplicaSet.useList({ namespace });
  const [jobs] = K8s.ResourceClasses.Job.useList({ namespace });

  useEffect(() => {
    const id = setInterval(() => setTick(t => t + 1), REFRESH_MS);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    let live = true;
    const client = makeApiClient();
    (async () => {
      const root = await client.getObject(APP_API_VERSION, 'apps', namespace, name);
      if (!live) return;
      if (!root) {
        setApp(null);
        setTree(null);
        setError(`No App "${name}" in namespace "${namespace}" on this cluster. If it was just declared, its pull request may not be merged or reconciled yet.`);
        return;
      }
      const built = await buildAppTree(root, client);
      if (!live) return;
      setApp(root);
      setTree(built);
      setError(null);
    })().catch(e => {
      if (live) setError(String(e?.message ?? e));
    });
    return () => {
      live = false;
    };
  }, [namespace, name, tick]);

  const withOwned = useMemo(() => {
    if (!tree) return null;
    const candidates = [...(replicaSets ?? []), ...(jobs ?? []), ...(pods ?? [])].map(
      o => (o as unknown as { jsonData: KubeJSON }).jsonData,
    );
    return attachOwned(tree, candidates);
  }, [tree, pods, replicaSets, jobs]);

  return { app, tree: withOwned, error };
}
```

- [ ] **Step 3: Write `src/mapSource.tsx`**

```tsx
// Two consumers, one shape: the page's embedded graph (the whole tree of one
// app) and the global Map's "Apps" source (every app plus its direct children).
import { registerMapSource } from '@kinvolk/headlamp-plugin/lib';
import { KubeObject } from '@kinvolk/headlamp-plugin/lib/K8s/cluster';
import { useEffect, useMemo, useState } from 'react';
import { AppResource, type KubeJSON } from './app';
import { makeApiClient } from './client';
import { nodeStatus } from './status';
import { buildAppTree, type AppTree } from './tree';

/** Turns a resolved tree into the node/edge shape GraphView consumes. */
export function graphNodesFrom(tree: AppTree) {
  return {
    nodes: tree.nodes.map(n => ({
      id: n.id,
      kubeObject: new KubeObject(n.object as any),
      status: nodeStatus(n.object),
    })),
    edges: tree.edges.map(e => ({ id: e.id, source: e.source, target: e.target })),
  };
}

/**
 * The source used by the App page: one app, its whole tree, nothing else.
 * Built as a source (rather than passed as raw nodes) because GraphView takes
 * sources, and because it keeps both graphs on one code path.
 */
export function appTreeSource(tree: AppTree | null) {
  return {
    id: 'ogenki-app-tree',
    label: 'App',
    useData() {
      return useMemo(() => (tree ? graphNodesFrom(tree) : null), [tree]);
    },
  };
}

/** The global Map's source: every visible App, expanded one level. */
export const appsMapSource = {
  id: 'ogenki-apps',
  label: 'Apps',
  useData() {
    const [apps] = AppResource.useList();
    const [tree, setTree] = useState<AppTree | null>(null);

    useEffect(() => {
      let live = true;
      if (!apps) {
        setTree(null);
        return;
      }
      const client = makeApiClient();
      Promise.all(
        apps.map(a => buildAppTree((a as unknown as { jsonData: KubeJSON }).jsonData, client, 1)),
      )
        .then(trees => {
          if (!live) return;
          setTree({
            nodes: trees.flatMap(t => t.nodes),
            edges: trees.flatMap(t => t.edges),
            unresolved: [],
          });
        })
        .catch(() => live && setTree(null));
      return () => {
        live = false;
      };
    }, [apps]);

    return useMemo(() => (tree ? graphNodesFrom(tree) : null), [tree]);
  },
};

export function registerAppsMapSource() {
  registerMapSource(appsMapSource);
}
```

- [ ] **Step 4: Write `src/AppsListPage.tsx`**

```tsx
// Every App the viewer can see. The name links to the plugin's own page, which
// is the URL the App Wizard builds.
import { Link, ResourceListView, StatusLabel } from '@kinvolk/headlamp-plugin/lib/CommonComponents';
import { getCluster } from '@kinvolk/headlamp-plugin/lib/Utils';
import { AppResource, type KubeJSON } from './app';
import { conditionOf } from './status';

function conditionChip(app: AppResource, type: string) {
  const c = conditionOf(app.jsonData as KubeJSON, type);
  const status = c?.status === 'True' ? 'success' : c?.status === 'False' ? 'error' : 'warning';
  return (
    <StatusLabel status={status} title={c?.message}>
      {c?.status ?? 'Unknown'}
    </StatusLabel>
  );
}

export function AppsListPage() {
  const cluster = getCluster();
  return (
    <ResourceListView
      title="Apps"
      resourceClass={AppResource}
      columns={[
        {
          id: 'name',
          label: 'Name',
          getValue: (app: AppResource) => app.metadata.name,
          render: (app: AppResource) => (
            <Link to={`/c/${cluster}/apps/${app.metadata.namespace}/${app.metadata.name}`}>
              {app.metadata.name}
            </Link>
          ),
        },
        'namespace',
        {
          id: 'ready',
          label: 'Ready',
          getValue: (app: AppResource) => conditionOf(app.jsonData as KubeJSON, 'Ready')?.status ?? 'Unknown',
          render: (app: AppResource) => conditionChip(app, 'Ready'),
        },
        {
          id: 'synced',
          label: 'Synced',
          getValue: (app: AppResource) => conditionOf(app.jsonData as KubeJSON, 'Synced')?.status ?? 'Unknown',
          render: (app: AppResource) => conditionChip(app, 'Synced'),
        },
        {
          id: 'image',
          label: 'Image',
          getValue: (app: AppResource) => {
            const img = (app.jsonData as KubeJSON).spec?.image;
            return img ? [img.repository, img.tag].filter(Boolean).join(':') : '';
          },
        },
        'age',
      ]}
    />
  );
}
```

- [ ] **Step 5: Register the list page and the map source**

`src/index.tsx`:

```tsx
// Registrations for the App view plugin. Every register* call lives here; the
// pages and the map source are imported from their own modules.
import { registerKindIcon, registerRoute, registerSidebarEntry } from '@kinvolk/headlamp-plugin/lib';
import { Icon } from '@iconify/react';
import { APP_KIND } from './app';
import { AppsListPage } from './AppsListPage';
import { registerAppsMapSource } from './mapSource';

registerSidebarEntry({
  name: 'ogenki-apps',
  label: 'Apps',
  icon: 'mdi:apps',
  url: '/apps',
});

registerRoute({
  path: '/apps',
  exact: true,
  name: 'Apps',
  sidebar: 'ogenki-apps',
  component: AppsListPage,
});

// So an App is recognisable wherever a node is drawn.
registerKindIcon(APP_KIND, { icon: <Icon icon="mdi:apps" width="100%" height="100%" /> });

registerAppsMapSource();
```

- [ ] **Step 6: Build and check**

Run: `cd container-images/headlamp-plugin-app && npm run lint && npm run tsc && npm test && npm run build`
Expected: all clean; the Task 3 and 4 tests still pass.

- [ ] **Step 7: Commit**

```bash
cd /home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view
git add container-images/headlamp-plugin-app/src
git commit -m "feat(headlamp-plugin-app): API client, Apps map source and the list page"
```

---

### Task 6: The App page

**Files:**
- Create: `container-images/headlamp-plugin-app/src/AppPage.tsx`
- Modify: `container-images/headlamp-plugin-app/src/index.tsx`

**Interfaces:**
- Consumes: `useAppTree`, `appTreeSource`, `useConfigLinks`, `expandLink`, `nodeStatus`, `conditionOf`.
- Produces: `AppPage` at `/apps/:namespace/:name`, and the "Open App view" header action.

- [ ] **Step 1: Write the page**

`src/AppPage.tsx`:

```tsx
// One App, everything about it. The graph comes first because it is the answer
// to "what does this app actually consist of, and is any of it unhealthy".
import { Icon } from '@iconify/react';
import {
  ActionButton,
  Link,
  ObjectEventList,
  SectionBox,
  SimpleTable,
  StatusLabel,
  WorkloadLogs,
} from '@kinvolk/headlamp-plugin/lib/CommonComponents';
import { KubeObject } from '@kinvolk/headlamp-plugin/lib/K8s/cluster';
import { getCluster } from '@kinvolk/headlamp-plugin/lib/Utils';
import { Alert, Box, Button, Chip, Typography } from '@mui/material';
import { useMemo } from 'react';
import { useParams } from 'react-router-dom';
import type { KubeJSON } from './app';
import { useConfigLinks } from './client';
import { expandLink } from './links';
import { appTreeSource } from './mapSource';
import { conditionOf, nodeStatus } from './status';
import { useAppTree } from './useAppTree';

// Headlamp 0.45.0 exports GraphView through pluginLib.ResourceMap; the pinned
// plugin toolkit (0.14.0) predates that, so a bare import resolves to
// undefined. Read the runtime global instead — see headlamp-plugin.d.ts.
const GraphView = window.pluginLib?.ResourceMap?.GraphView;

function ConditionChip({ app, type }: { app: KubeJSON; type: string }) {
  const c = conditionOf(app, type);
  const status = c?.status === 'True' ? 'success' : c?.status === 'False' ? 'error' : 'warning';
  return (
    <StatusLabel status={status} title={c?.message}>
      {type}: {c?.status ?? 'Unknown'}
    </StatusLabel>
  );
}

export function AppPage() {
  const { namespace, name } = useParams<{ namespace: string; name: string }>();
  const cluster = getCluster();
  const { app, tree, error } = useAppTree(namespace, name);
  const links = useConfigLinks();

  const source = useMemo(() => appTreeSource(tree), [tree]);
  const namespaceFilter = useMemo(
    () => [{ type: 'namespace' as const, namespaces: new Set([namespace]) }],
    [namespace],
  );

  if (error) {
    return (
      <SectionBox title={`App: ${name}`}>
        <Alert severity="warning">{error}</Alert>
        <Box mt={2}>
          <Link to={`/c/${cluster}/apps`}>Back to Apps</Link>
        </Box>
      </SectionBox>
    );
  }

  if (!app || !tree) {
    return <SectionBox title={`App: ${name}`}>Loading…</SectionBox>;
  }

  const image = app.spec?.image ? [app.spec.image.repository, app.spec.image.tag].filter(Boolean).join(':') : '';
  const hostname = app.spec?.route?.enabled ? app.spec.route.hostname : undefined;

  // Everything except the App itself and its Pods: the composed inventory.
  const composed = tree.nodes.filter(n => n.id !== app.metadata.uid && n.object.kind !== 'Pod');
  const pods = tree.nodes.filter(n => n.object.kind === 'Pod');
  const workloads = tree.nodes.filter(n => n.object.kind === 'Deployment' || n.object.kind === 'CronJob');

  return (
    <>
      <SectionBox title={`App: ${app.metadata.name}`} backLink={`/c/${cluster}/apps`}>
        <Box display="flex" flexWrap="wrap" alignItems="center" gap={1} mb={1}>
          <ConditionChip app={app} type="Ready" />
          <ConditionChip app={app} type="Synced" />
          <Chip size="small" label={`namespace: ${namespace}`} />
          {image && <Chip size="small" label={image} />}
          <ActionButton
            description="Open the raw App resource"
            icon="mdi:code-braces"
            onClick={() => {
              window.location.href = `/c/${cluster}/customresources/apps.cloud.ogenki.io/${namespace}/${name}`;
            }}
          />
          {hostname && (
            <Chip
              size="small"
              icon={<Icon icon="mdi:web" />}
              label={hostname}
              component="a"
              href={`https://${hostname}`}
              target="_blank"
              rel="noopener noreferrer"
              clickable
            />
          )}
        </Box>
        {tree.unresolved.length > 0 && (
          <Alert severity="info">
            {tree.unresolved.length} composed resource
            {tree.unresolved.length === 1 ? '' : 's'} could not be read (not created yet, or not
            permitted): {tree.unresolved.map(r => `${r.kind}/${r.name}`).join(', ')}
          </Alert>
        )}
      </SectionBox>

      <SectionBox title="Map">
        {GraphView ? (
          <GraphView
            height="60vh"
            defaultSources={[source]}
            defaultNodeSelection={app.metadata.uid}
            defaultFilters={namespaceFilter}
          />
        ) : (
          <Alert severity="warning">
            This Headlamp is older than 0.45.0, which is the release that lets a plugin embed the
            resource map. Falling back to the global map.{' '}
            <Link to={`/c/${cluster}/map?namespace=${namespace}&node=${app.metadata.uid}`}>
              Open this app in the map
            </Link>
          </Alert>
        )}
      </SectionBox>

      <SectionBox title={`Composed resources (${composed.length})`}>
        <SimpleTable
          columns={[
            { label: 'Kind', getter: (n: (typeof composed)[0]) => n.object.kind },
            {
              label: 'Name',
              getter: (n: (typeof composed)[0]) => (
                <Link kubeObject={new KubeObject(n.object as any)}>{n.object.metadata.name}</Link>
              ),
            },
            {
              label: 'Status',
              getter: (n: (typeof composed)[0]) => (
                <StatusLabel status={nodeStatus(n.object)}>{nodeStatus(n.object)}</StatusLabel>
              ),
            },
            { label: 'Age', getter: (n: (typeof composed)[0]) => n.object.metadata.creationTimestamp ?? '' },
          ]}
          data={composed}
          emptyMessage="No composed resources resolved."
        />
      </SectionBox>

      <SectionBox title={`Pods (${pods.length})`}>
        <SimpleTable
          columns={[
            {
              label: 'Name',
              getter: (n: (typeof pods)[0]) => (
                <Link kubeObject={new KubeObject(n.object as any)}>{n.object.metadata.name}</Link>
              ),
            },
            { label: 'Phase', getter: (n: (typeof pods)[0]) => n.object.status?.phase ?? '' },
            {
              label: 'Restarts',
              getter: (n: (typeof pods)[0]) =>
                (n.object.status?.containerStatuses ?? []).reduce(
                  (sum: number, c: { restartCount?: number }) => sum + (c.restartCount ?? 0),
                  0,
                ),
            },
          ]}
          data={pods}
          emptyMessage="No pods."
        />
        {workloads.map(w => (
          <Box key={w.id} mt={2}>
            <Typography variant="subtitle2">{`${w.object.kind}/${w.object.metadata.name}`}</Typography>
            <WorkloadLogs item={new KubeObject(w.object as any)} />
          </Box>
        ))}
      </SectionBox>

      <SectionBox title="Events">
        <ObjectEventList object={new KubeObject(app as any)} />
      </SectionBox>

      {links.length > 0 && (
        <SectionBox title="Links">
          <Box display="flex" flexWrap="wrap" gap={1}>
            {links.map(l => (
              <Button
                key={l.label}
                variant="outlined"
                size="small"
                href={expandLink(l.url, { namespace, name })}
                target="_blank"
                rel="noopener noreferrer"
                endIcon={<Icon icon="mdi:open-in-new" />}
              >
                {l.label}
              </Button>
            ))}
          </Box>
        </SectionBox>
      )}
    </>
  );
}
```

- [ ] **Step 2: Register the route and the header action**

Add to `src/index.tsx`:

```tsx
import { registerDetailsViewHeaderAction } from '@kinvolk/headlamp-plugin/lib';
import { ActionButton } from '@kinvolk/headlamp-plugin/lib/CommonComponents';
import { getCluster } from '@kinvolk/headlamp-plugin/lib/Utils';
import { AppPage } from './AppPage';

registerRoute({
  path: '/apps/:namespace/:name',
  exact: true,
  name: 'App',
  sidebar: 'ogenki-apps',
  component: AppPage,
});

// On Headlamp's own page for an App resource, offer the richer view.
function OpenAppViewAction({ item }: { item: any }) {
  if (!item || item.kind !== APP_KIND) return null;
  const cluster = getCluster();
  return (
    <ActionButton
      description="Open App view"
      icon="mdi:sitemap-outline"
      onClick={() => {
        window.location.href = `/c/${cluster}/apps/${item.metadata.namespace}/${item.metadata.name}`;
      }}
    />
  );
}

registerDetailsViewHeaderAction({ id: 'ogenki-open-app-view', action: OpenAppViewAction });
```

- [ ] **Step 3: Build**

Run: `cd container-images/headlamp-plugin-app && npm run lint && npm run tsc && npm test && npm run build`
Expected: all clean.

- [ ] **Step 4: Try it against the live cluster**

```bash
npm start
```

`headlamp-plugin start` watches and writes into the local Headlamp plugins directory. With the desktop app pointed at the aws-0 context (or `kubectl proxy` plus a local Headlamp), open **Apps** in the sidebar, then `podinfo`.

Verify, and note what you see:
1. The header shows Ready and Synced chips and the image.
2. The graph renders with the App node selected and its children around it.
3. The composed-resources table lists every entry of `kubectl get app podinfo -n demo -o jsonpath='{.spec.crossplane.resourceRefs}'`, each with a status.
4. Clicking a composed resource's name opens Headlamp's own page for it.
5. The Links section is absent (the ConfigMap does not exist yet — Task 7 adds it).

If `GraphView` is undefined, the warning Alert renders instead. That means Task 1 did not land on the cluster you are pointing at; fix that before continuing.

- [ ] **Step 5: Commit and open the plugin PR**

```bash
cd /home/smana/Sources/cloud-native-ref/.claude/worktrees/headlamp-app-view
git add container-images/headlamp-plugin-app
git commit -m "feat(headlamp-plugin-app): the App page — status, graph, composed resources, pods, events, links"
git push
gh pr create --base main --title "feat(headlamp): a plugin that gives an App its own page" --body "$(cat <<'EOF'
A Headlamp plugin, owned here, that gives one `App` claim a page of its own at `/c/main/apps/<namespace>/<name>`: Ready/Synced status, the resource graph scoped to that app, its composed resources with per-kind status, its pods with logs, events, and configurable jump-off links.

It exists so a card in the App Wizard can open a live view of the app it declares — the wizard holds no cluster credentials, so the link is the whole bridge.

- Tree resolution walks `spec.crossplane.resourceRefs`, recurses into nested XRs (SQLInstance, KVStore, EPI) and attaches owned ReplicaSets/Jobs/Pods. Pure over an injected client, unit-tested.
- The embedded graph uses `GraphView`, exported to plugins in Headlamp 0.45.0 (already pinned). The published plugin toolkit predates that export, so the renderer is read from the runtime global with a local type declaration; there is a documented fallback to the global map if it is missing.
- Ships as an init-container image like the Flux and cert-manager plugins. Lint, type-check and tests run inside the image build, which is this directory's only CI.

Design: `docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md`
ADR: `website/content/docs/decisions/0035-own-headlamp-plugin-for-the-app-view.md`
EOF
)"
```

> The ADR and docs (Task 7's steps 1–4) belong in **this** PR — a technology choice with a rejected alternative needs its record on the branch before the PR opens. Do those steps, then create the PR.

---

### Task 7: ADR, documentation, and the wiring

**Files:**
- Create: `website/content/docs/decisions/0035-own-headlamp-plugin-for-the-app-view.md`, `tooling/base/headlamp/configmap-plugin-app.yaml`
- Modify: `website/content/docs/decisions/_index.md`, `website/content/docs/platform/gitops/_index.md`, `website/content/docs/platform/developer-platform/app-wizard.md`, `.doc-claims.yaml`, `container-images/README.md`, `tooling/base/headlamp/{helmrelease.yaml,kustomization.yaml}`, `apps/platform/app-wizard/{app.yaml,wizard.yaml}`

**Interfaces:**
- Consumes: the image published by Task 5's merge, and app-wizard v0.3.0 from the companion plan.

- [ ] **Step 1: Write ADR-0035**

`website/content/docs/decisions/0035-own-headlamp-plugin-for-the-app-view.md`, following the repo template:

```markdown
---
title: An in-house Headlamp plugin gives the App abstraction its own view
linkTitle: 0035 · Headlamp App plugin
weight: 350
description: The platform's App claim gets a purpose-built Headlamp page — status, a graph of exactly its resources, pods and jump-off links — rather than Headlamp's generic custom-resource page or a third-party Crossplane plugin. The plugin is small because it knows one kind; a generic Crossplane browser would be larger and say less about this platform.
lastVerified: 2026-09-09
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

Source in `container-images/headlamp-plugin-app/`, published by the repo's
container-image workflow and loaded by a fourth init container on the Headlamp
HelmRelease, exactly like the Flux and cert-manager plugins. Jump-off links come
from an optional ConfigMap in `tooling`, substituted per cluster by Flux.

---

## References

- Design: `docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md`
- [kubernetes-sigs/headlamp#6992](https://github.com/kubernetes-sigs/headlamp/pull/6992) — GraphView exported to plugins in 0.45.0
- [builver/headlamp-plugin-crossplane](https://github.com/builver/headlamp-plugin-crossplane) — the rejected third-party option
```

- [ ] **Step 2: Index the ADR**

Append to the table in `website/content/docs/decisions/_index.md`, before the closing "Starting a new one?" line:

```markdown
| [0035]({{< relref "/docs/decisions/0035-own-headlamp-plugin-for-the-app-view.md" >}}) | An in-house Headlamp plugin gives the App abstraction its own view | Accepted | 2026-09-09 |
```

- [ ] **Step 3: Update the two prose pages**

In `website/content/docs/platform/gitops/_index.md`, after the paragraph describing the Flux plugin (around line 468), add:

```markdown
A second plugin is built here rather than pulled in: **`headlamp-plugin-app`**
(`ghcr.io/smana/headlamp-plugin-app`, source in `container-images/`) gives the
platform's own `App` claim a page at `/c/main/apps/<namespace>/<name>` — its
Ready and Synced conditions, a graph of exactly the resources that claim
composed (nested `SQLInstance` and friends included), its pods and events, and
links out to Grafana and VictoriaLogs. It is what an App Wizard card opens.
See [ADR-0035]({{< relref "/docs/decisions/0035-own-headlamp-plugin-for-the-app-view.md" >}}).
It needs Headlamp 0.45.0 or later, which is what the HelmRelease pins.
```

In `website/content/docs/platform/developer-platform/app-wizard.md`, after the "Submit and verify" section and before the "Which should I use?" heading:

```markdown
## From a card to the running app

Once the PR is merged and Flux has reconciled it, the app appears in **My
apps** as a card. Each card carries an **Open** action pointing at Headlamp's
App view for that app — the Ready and Synced conditions, a graph of everything
the claim composed, the pods, the events, and links onward to Grafana and
VictoriaLogs.

Both clusters run the `platform` and `demo` stacks, so the card offers one
entry per cluster and you pick where to look. The wizard itself never contacts
a cluster: it builds the link from the app's namespace and name and opens it in
a new tab. The links are configured in `apps/platform/app-wizard/wizard.yaml`
under `links`.
```

- [ ] **Step 4: Pin the version claim**

Append to `.doc-claims.yaml`:

```yaml
  - id: headlamp-chart-version
    why: >-
      The App view plugin embeds Headlamp's map renderer, which is only exported
      to plugins from 0.45.0. The GitOps page tells operators that floor. If the
      chart is ever rolled back below it the page stops embedding the graph and
      silently falls back to a link, while the docs keep promising the graph.
    source:
      file: tooling/base/headlamp/helmrelease.yaml
      pattern: '^      version: "([0-9.]+)"'
    pages:
      - path: website/content/docs/platform/gitops/_index.md
        must_contain: 'Headlamp {value} or later'
```

- [ ] **Step 5: Validate the documentation**

Run: `./scripts/validate-links.sh && ./scripts/validate-doc-claims.sh`
Expected: both exit 0. The claim passes only if the chart version and the prose agree; if the sentence reads "0.45.0 or later" and the pin is `0.45.0`, it does.

At this point commit and open the plugin PR (Task 5, step 5). The steps below are the **second** PR.

- [ ] **Step 6: Wait for the image**

After the plugin PR merges to `main`:

```bash
gh run list --workflow build-container-images.yml --limit 3
docker manifest inspect ghcr.io/smana/headlamp-plugin-app:v0.1.0 > /dev/null && echo "image published"
```

Expected: `image published`. Nothing below can be applied before this.

- [ ] **Step 7: Add the links ConfigMap**

`tooling/base/headlamp/configmap-plugin-app.yaml`:

```yaml
# Jump-off links rendered by headlamp-plugin-app on an App's page. Optional by
# design: the plugin hides the section when this ConfigMap is absent or the
# viewer cannot read it, so a cluster without it loses nothing else.
#
# JSON rather than YAML because a ConfigMap value is a string either way, and
# JSON needs no parser in the plugin bundle. {namespace} and {name} are
# substituted by the plugin per app; ${private_domain_name} is substituted by
# Flux per cluster, which is what lets one manifest serve both clouds.
apiVersion: v1
kind: ConfigMap
metadata:
  name: headlamp-plugin-app
  namespace: tooling
data:
  links.json: |
    [
      {
        "label": "Logs (VictoriaLogs)",
        "url": "https://vl.${private_domain_name}/select/vmui/?#/?query=%7Bkubernetes.pod_namespace%3D%22{namespace}%22%2Ckubernetes.pod_name%3D~%22{name}.%2A%22%7D"
      },
      {
        "label": "Dashboards (Grafana)",
        "url": "https://grafana.${private_domain_name}/dashboards"
      },
      {
        "label": "Source (GitHub)",
        "url": "https://github.com/Smana/cloud-native-ref/search?q=path%3Aapps+filename%3Aapp.yaml+{name}"
      }
    ]
```

Add it to `tooling/base/headlamp/kustomization.yaml`:

```yaml
resources:
  - configmap-plugin-app.yaml
  - externalsecret-headlamp-envvars.yaml
  - helmrelease.yaml
  - httproute.yaml
```

- [ ] **Step 8: Load the plugin**

In `tooling/base/headlamp/helmrelease.yaml`, add a fourth entry to `values.initContainers`, after `ai-assistant-plugin`:

```yaml
      # The App view: a page per cloud.ogenki.io/App claim (ADR-0035). Built in
      # this repo under container-images/headlamp-plugin-app; the tag comes from
      # ARG HEADLAMP_PLUGIN_APP_VERSION in its Dockerfile.
      - name: app-plugin
        command:
          - /bin/sh
          - -c
          - mkdir -p /build/plugins && cp -r /plugins/* /build/plugins/
        image: ghcr.io/smana/headlamp-plugin-app:v0.1.0
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
        volumeMounts:
          - mountPath: /build/plugins
            name: headlamp-plugins
```

- [ ] **Step 9: Point the wizard at it**

`apps/platform/app-wizard/app.yaml`, `spec.image.tag`:

```yaml
    tag: "v0.3.0"
```

`apps/platform/app-wizard/wizard.yaml`, appended after the `auth` block:

```yaml
# External links on each app card in "My apps". The URL is a template over
# {namespace}, {name} and {stack}, expanded by the SPA and opened in a new tab.
# Both clusters run the platform and demo stacks, so an app can exist on either
# and the card offers both. The wizard never contacts a cluster — this link is
# the whole bridge to a live view (ADR-0035).
links:
  - label: Headlamp (aws-0)
    url: https://headlamp.priv.aws.ogenki.io/c/main/apps/{namespace}/{name}
  - label: Headlamp (gcp-0)
    url: https://headlamp.priv.gcp.ogenki.io/c/main/apps/{namespace}/{name}
```

- [ ] **Step 10: Note the new image in the README**

In `container-images/README.md`, add to the directory-structure block:

```
├── headlamp-plugin-app/     # Headlamp plugin: a page per App claim (ADR-0035)
│   ├── Dockerfile
│   ├── src/
│   ├── build.sh
│   └── README.md
```

- [ ] **Step 11: Validate everything**

Run:

```bash
./scripts/validate-manifests.sh
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
```

Expected: all three exit 0, and the manifest report reads `Invalid: 0, Skipped: 0`. Quote those lines in the PR body.

- [ ] **Step 12: Commit and open the wiring PR**

```bash
git add tooling/base/headlamp apps/platform/app-wizard container-images/README.md
git commit -m "feat(headlamp): load the App view plugin and link the wizard to it

Fourth init container pins ghcr.io/smana/headlamp-plugin-app:v0.1.0, an
optional ConfigMap supplies its jump-off links (substituted per cluster), and
the App Wizard moves to v0.3.0 with one Headlamp link per cluster."
git push
gh pr create --base main --title "feat(headlamp): wire the App view plugin and the wizard link" --body "..."
```

- [ ] **Step 13: Verify on both clusters**

After the merge:

```bash
flux reconcile kustomization tooling --with-source
kubectl get pods -n tooling -l app.kubernetes.io/name=headlamp -o jsonpath='{.items[0].spec.initContainers[*].name}{"\n"}'
kubectl get cm headlamp-plugin-app -n tooling -o jsonpath='{.data.links\.json}' | head -5
flux reconcile kustomization apps --with-source
kubectl get app app-wizard -n apps -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: the init-container list contains `app-plugin`; the ConfigMap holds the substituted URLs with a real domain (no literal `${private_domain_name}`); the wizard App is `True`.

Then, in the browser:
1. Open `https://app-wizard.priv.aws.ogenki.io`, sign in, click **My apps**. Each card shows an **Open** menu with two Headlamp entries.
2. Click **Headlamp (aws-0)** on `podinfo`. A new tab opens `https://headlamp.priv.aws.ogenki.io/c/main/apps/demo/podinfo`.
3. The page shows Ready/Synced, the graph with the App selected, the composed-resources table, pods, events, and now the three links.
4. Repeat step 2 for **Headlamp (gcp-0)** and confirm the same page renders there.
5. In Headlamp, open **Map** and confirm an "Apps" source appears in the source picker with App nodes.

Record the outcome of each numbered check. Anything that fails is a finding, not a footnote.

---

## Self-review

- **Spec coverage.** Chart bump (Task 1); scaffold and image (Task 2); tree resolver with nested XRs and owned pods (Task 3); status mapping and links config (Task 4); map source, list page, kind icon (Task 5); App page with graph, composed resources, pods, logs, events, links, and the header action (Task 6); ADR-0035, both doc pages, the doc claim, the ConfigMap, the init container, the wizard pin and links, and the live verification (Task 7). The spec's success criteria 1–7 map onto Task 7 step 13 and the validation step; criterion 8 (gcp-0) is check 4.
- **Placeholders.** One deliberate `--body "..."` in Task 7 step 12, because the body must quote validation output that does not exist until the step runs; the step above it says exactly what to quote. Everything else is literal.
- **Type consistency.** `ApiClient`, `ApiResourceInfo`, `AppTree`, `TreeNode`, `TreeEdge` are defined in Task 3 and used unchanged in Tasks 5 and 6. `nodeStatus`/`conditionOf` (Task 4) are used in `AppsListPage`, `mapSource` and `AppPage`. `expandLink(url, {namespace, name})` in the plugin takes two placeholders; the wizard's own `expandLink` (companion plan) takes three — different modules, different inputs, deliberately not shared across repositories.
