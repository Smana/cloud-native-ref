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

The links section reads an optional ConfigMap `headlamp-plugin-app` in the
`tooling` namespace, key `links.json`: a JSON array of
`{"label": "...", "url": "..."}` whose URL may use `{namespace}` and `{name}`.
Absent or unreadable ⇒ the links section is hidden.

**Not wired up yet.** This repo has no
`tooling/base/headlamp/configmap-plugin-app.yaml`, and the plugin isn't loaded
into a running Headlamp at all yet either — see the platform's GitOps page and
ADR-0035 for the current deployment state. A later change adds that ConfigMap,
rendered with `${private_domain_name}` substituted per cluster by Flux,
alongside the init container wiring; until then the links section always
renders hidden.

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
