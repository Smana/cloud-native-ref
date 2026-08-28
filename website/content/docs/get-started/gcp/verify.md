---
title: Verify the cluster
weight: 25
description: Authenticate to gcp-0 and check every layer yourself, from Flux down to the browser.
lastVerified: 2026-08-27
---

Everything below is read-only. Run it top to bottom after a deploy, or dip into
whichever section you are suspicious of.

## 1. Authenticate

```bash
gcloud auth login                       # once per machine
gcloud config set project ogenki-435905

gcloud container clusters get-credentials gcp-0 \
  --location europe-west4-a --project ogenki-435905

kubectl get nodes
```

{{< callout type="warning" >}}
**The control plane is private.** `kubectl` only works from the tailnet, so
`tailscale status` must show you connected before any of this. A hanging
`kubectl` with no error is almost always a dropped tailnet, not a broken
cluster.
{{< /callout >}}

To keep this out of your usual kubeconfig, point `KUBECONFIG` at a scratch file
before `get-credentials`:

```bash
export KUBECONFIG=/tmp/gcp0.kubeconfig
```

## 2. GitOps layer

```bash
flux get kustomizations           # everything True, bar the suspended ones
flux get helmreleases -A
flux get sources all -A
```

Two Kustomizations report **no status at all**, and that is correct — they are
`spec.suspend: true`:

| Suspended | Why |
|---|---|
| `llm-platform` | opt-in; see `clusters/gcp-0-llm-platform/README.md` |
| `security-openbao-snapshot` | opt-in |
| `zitadel` | only when this cluster consumes an IdP rather than hosting one ([ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}})) |

Anything else not `True` is a real failure. Start with the message:

```bash
kubectl get kustomization -A \
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,MSG:.status.conditions[0].message
```

A `dependency '…' is not ready` message is a **cascade, not a cause** — walk to
the root of the chain and fix that one.

## 3. Secrets

The single most common cause of a stuck cluster, and the least self-evident: a
missing or unreadable secret surfaces as a `HelmRelease` timing out ten minutes
later, naming only the HelmRelease.

```bash
./scripts/secret-store.sh check --cloud gcp --project ogenki-435905
```

That lists every key the cluster's ExternalSecrets ask for and whether it exists.
For the in-cluster side:

```bash
kubectl get externalsecrets -A
```

`SecretSyncedError` has two usual causes, and they look identical from the
cluster:

- **the secret does not exist** — `secret-store.sh check` says so;
- **External Secrets cannot read it** — the grant is per-secret, never
  project-wide, so a newly created secret is unreadable until it is granted:

```bash
gcloud secrets get-iam-policy <name> --project ogenki-435905
```

## 4. Certificates and networking

```bash
kubectl get certificates -A          # all True
kubectl get gateways -A              # PROGRAMMED=True, each with an address
kubectl get httproute -A
```

Private hostnames resolve only over the tailnet; public ones resolve from
anywhere through Route 53 ([ADR-0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}})).

```bash
dig +short auth.gcp.cloud.ogenki.io          # public, from anywhere
dig +short grafana.priv.gcp.ogenki.io        # private, needs the tailnet
```

## 5. Browse it

Everything private is `*.priv.gcp.ogenki.io` and needs the tailnet. Start at the
homepage, which links the rest.

{{< callout type="warning" >}}
**Private services present the OpenBao private CA**, so a browser that does not
trust it shows a certificate warning, and `curl` fails with "unable to establish
a secure connection" rather than an HTTP error. That is the PKI working, not a
broken service — the certificates are real, they are simply not from a public CA.

Trust the chain, or use `curl -k` when you only care whether the service
answers:

```bash
curl -sSk -o /dev/null -w '%{http_code}\n' https://grafana.priv.gcp.ogenki.io/login
```

**ZITADEL is the exception**: it is public, on Route 53, with a Let's Encrypt
certificate, so it verifies normally and needs no `-k`.
{{< /callout >}}

| Service | URL |
|---|---|
| Homepage | `https://home.priv.gcp.ogenki.io` |
| Grafana | `https://grafana.priv.gcp.ogenki.io` |
| Harbor | `https://harbor.priv.gcp.ogenki.io` |
| Headlamp | `https://headlamp.priv.gcp.ogenki.io` |
| Flux UI | `https://flux-ui-gcp-0.priv.gcp.ogenki.io` |
| VictoriaMetrics | `https://vm.priv.gcp.ogenki.io/vmui` |
| VictoriaLogs | `https://vl.priv.gcp.ogenki.io/select/vmui` |
| VictoriaTraces | `https://vt.priv.gcp.ogenki.io/select/vmui` |
| Alertmanager | `https://vmalertmanager-gcp-0.priv.gcp.ogenki.io` |
| pev2 | `https://pev2.priv.gcp.ogenki.io` |
| podinfo | `https://podinfo.priv.gcp.ogenki.io` |
| App Wizard | `https://app-wizard.priv.gcp.ogenki.io` |
| ZITADEL | `https://auth.gcp.cloud.ogenki.io` (**public**) |

### Credentials

Grafana's admin login, and every other generated credential, lives in Secret
Manager. Read one with:

```bash
gcloud secrets versions access latest \
  --secret=observability-victoria-metrics-k8s-stack-grafana-envvars \
  --project=ogenki-435905 | jq -r .GF_SECURITY_ADMIN_USER
```

ZITADEL's first admin is in `zitadel-envvars`
(`ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME` / `…_PASSWORD`). Prefer SSO.

### Single sign-on, in this order

SSO needs **five** steps, and the order is load-bearing: each one creates what
the next reads. Running only the first — which is all this page used to say —
leaves you with OIDC clients and no way to log in through Google.

Every step is idempotent: re-running prints `[skip …]` and changes nothing.

```bash
# 1. Register the OIDC clients, the project, its roles, and
#    projectRoleAssertion. That last one is not optional: with it off ZITADEL
#    puts NO roles in any token AND leaves ctx.v1.user.grants empty inside the
#    groups action, so every consumer authenticates and then has no groups.
./scripts/zitadel-oidc-clients.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --apply

# 2. Let External Secrets read what step 1 just created. Those secrets did not
#    exist when the OpenTofu stack applied, so nothing granted access to them —
#    this reads the cluster's ExternalSecrets and grants what exists.
./scripts/secret-store.sh grant --cloud gcp --project ogenki-435905 --apply

# 3. The Google identity provider, the LOGIN POLICY entry that actually enables
#    it, and the action that flattens project roles into a `groups` claim.
#    Creating the provider without the policy entry gives "User not found".
IDP_URL=https://auth.gcp.cloud.ogenki.io \
  ./scripts/zitadel-idp.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --apply

# 4. Harbor's auth mode. Harbor stores this in its DATABASE, not in the chart,
#    so no manifest can express it and a fresh cluster has no SSO button.
PRIVATE_DOMAIN=priv.gcp.ogenki.io \
  ./scripts/harbor-oidc.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --apply
```

**Then log in once through Google**, at any consumer. That first login is what
CREATES your ZITADEL user — the IdP auto-registers it — so there is nobody to
authorise before it. Afterwards:

```bash
# 5. Give yourself the admin role. Group-based RBAC (cluster-admin via the
#    `admin` group) does nothing until a user actually holds it.
./scripts/zitadel-oidc-clients.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --grant-admin you@example.com --apply
```

The **only** thing left in a console is Google-side: the OAuth client's
authorized redirect URI must list
`https://auth.<public domain>/ui/login/login/externalidp/callback`. Google
accepts many, so one client serves every cluster; `zitadel-idp.sh` prints the
exact URI on every run and cannot add it for you.

## 6. Observability actually receiving data

A green Grafana proves the deployment, not the pipeline. Check that data is
arriving:

```bash
# metrics: how many series, and are the scrapes healthy
kubectl exec -n observability deploy/vmsingle-victoria-metrics-k8s-stack -- \
  wget -qO- 'http://localhost:8428/api/v1/query?query=count(up)'

# logs
kubectl logs -n observability deploy/victoria-logs --tail=5
```

In Grafana, the *Kubernetes / Views / Global* dashboard should show nodes and
pods within a minute of loading. An empty panel with a healthy datasource
usually means the time range is wrong rather than the stack — event-driven
components need 6–12h.

## 7. Alerting reaches Slack

```bash
kubectl get vmalert -A
kubectl get secret flux-slack-app -n flux-system      # must exist
```

Flux's `Alert` is `eventSeverity: error`, so **a healthy cluster sends nothing**.
Silence is the expected state; it is not evidence the wiring works. To prove the
path, look for past deliveries in the notification controller:

```bash
kubectl logs -n flux-system deploy/notification-controller --tail=50 | grep -i slack
```

## 8. Tear it down

Do not leave it running.

```bash
cd opentofu/gcp/gke/init
TM_GCP_ENABLED=true terramate script run destroy
```

Then the rest, and verify the project is empty — see
[Teardown]({{< relref "/docs/get-started/gcp/teardown.md" >}}).
