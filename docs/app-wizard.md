# Declaring an application

There are **two ways** to declare an application on the platform. Both end the
same way — a reviewable pull request under `apps/<stack>/<app_name>/` that Flux
reconciles onto the cluster — and both are validated against the exact same App
schema. Pick whichever fits how you work:

| | **App Wizard** (assisted) | **Write YAML** (direct) |
|---|---|---|
| Best for | First app, exploring options, not sure which fields exist | You know the App API; bulk/automation; small edits |
| Input | A guided form (or a plain-language description) | An `app.yaml` you write yourself |
| Validation | Live, in the browser, before you submit | At PR CI and at admission time |
| Opens the PR | For you, as your GitHub identity | You open it (or `git push` a branch) |
| Learn the API | The form *is* the schema (nothing to memorize) | [Field reference](apps-user-guide.md) |

Both paths hit the **same guardrails**: schema + CEL validation, a
`crossplane render` preview of what the claim will actually create, and a
secret scan that refuses any PR containing a credential value. Neither path can
deploy anything directly — Flux remains the only actor that touches the cluster.

---

## Option A — App Wizard (assisted)

The wizard is a small web app (private, behind Tailscale at
`https://app-wizard.priv.cloud.ogenki.io`). Sign in, fill the form, review, and
it opens the PR under your own GitHub identity.

### Signing in

You authenticate with **Zitadel (SSO)** — the same single sign-on you use for
the rest of the platform. Because every pull request is opened as *you* on
GitHub, you also **connect your GitHub account once**: after signing in, the
wizard shows a "Connect GitHub" prompt; follow it, authorize, and you're done.
That link is remembered for future sessions, so it's a one-time step. Until
GitHub is connected the "Open PR" button stays disabled — everything else
(building the form, live validation, preview) works without it.

> In local/dev deployments the wizard may run in a plain GitHub-login mode
> instead; there is no separate connect step there.

The first screen shows only the essentials — name, stack, image, and how the
app is exposed — with everything else (database, cache, autoscaling, network
policies, …) one expander away. A live YAML pane on the right shows the exact
claim being generated as you type.

![App Wizard — create form with live YAML pane](assets/app-wizard/01-create-form.png)
<!-- screenshot: wizard landing, basic tier (name/stack/image/route) on the left, live YAML pane on the right -->

Expand the advanced sections to add infrastructure — a Postgres database, a
Valkey cache, an S3 bucket, autoscaling, a PodDisruptionBudget, network
policies — without leaving the form.

![App Wizard — advanced sections (database, autoscaling)](assets/app-wizard/02-advanced.png)
<!-- screenshot: an expanded advanced section, e.g. sqlInstance + autoscaling -->

Validation is live: schema, CEL rules, and secret findings appear inline before
you can submit, with the same messages the API server would return.

![App Wizard — inline validation](assets/app-wizard/03-validation.png)
<!-- screenshot: an inline validation error, e.g. "route.hostname is required when route is enabled" -->

Before opening the PR, "Preview" runs `crossplane render` and lists the
resources the claim will create (Deployment, Service, HTTPRoute, PVC, …), so
reviewers review outcomes, not raw YAML.

![App Wizard — render preview](assets/app-wizard/04-render-preview.png)
<!-- screenshot: the render-preview panel listing rendered resource kinds/names -->

"Open PR" creates the branch, the three files, and the pull request as you, and
posts the render preview as a PR comment.

![App Wizard — pull request opened](assets/app-wizard/05-pull-request.png)
<!-- screenshot: the resulting GitHub PR (or the success state with the PR link) -->

### Secrets

The wizard's env/secrets editor only accepts **references** to secrets in AWS
Secrets Manager (via `externalSecrets`) — there is no field to type a secret
*value*. This is by design: secret values never transit the wizard or land in
Git.

---

## Option B — Write YAML and open a PR

If you know the App API, just write the claim yourself. This is how every app
in `apps/` was created, and it is a first-class, fully supported path.

**1. Create the directory** `apps/<stack>/<app_name>/` (stacks are listed in
[`apps/stacks.yaml`](../apps/stacks.yaml)) with two files:

`apps/<stack>/<app_name>/app.yaml`:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: demo-api
  namespace: demo          # the stack's namespace (see apps/stacks.yaml)
spec:
  image:
    repository: ghcr.io/smana/demo-api
    tag: "1.4.2"
  service:
    port: 8080
  route:
    enabled: true
    hostname: demo-api      # → demo-api.priv.cloud.ogenki.io
```

`apps/<stack>/<app_name>/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - app.yaml
```

**2. Register the app** in the stack's parent `apps/<stack>/kustomization.yaml`
by adding `- ./<app_name>` to its `resources`.

**3. Open a PR.** CI validates the claim; once merged, Flux reconciles it.

The full list of available fields (databases, autoscaling, probes, network
policies, observability, …) is in the [App user guide](apps-user-guide.md).

### Scaffold + validate locally (optional)

The `app-wizard` binary can do the boring, error-prone parts for you — generate
the three files (including the parent-kustomization edit) and run the same
schema / CEL / secret / render gates — without GitHub or a cluster:

```bash
# from the repo root
app-wizard generate \
  -stack demo -name demo-api -spec ./spec.yaml \
  -out . -render            # -render runs the crossplane render gate (needs docker)
```

where `spec.yaml` is just the App `.spec` block. It writes
`apps/demo/demo-api/{app.yaml,kustomization.yaml}` and updates the parent
kustomization, ready to commit. Drop `-out` to print to stdout instead.

---

## Which should I use?

- **New to the platform, or not sure what's available?** Use the **wizard** — it
  shows every option with help text, validates as you go, and wires up the PR.
- **Know the API and want speed, or scripting many apps?** **Write YAML** and
  open a PR (optionally `app-wizard generate` to scaffold and validate locally).

Same schema, same gates, same review flow — just two front doors.
