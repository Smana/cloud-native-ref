# Slack alert notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the chart-vendored Monzo Slack templates with a repo-owned template that names the cluster, environment, cloud and region, renders labels and duration, truncates runbook prose, and is protected by a golden-file gate.

**Architecture:** The template ships through `alertmanager.templateFiles` in the existing values ConfigMap, so the chart builds the ConfigMap and wires `VMAlertmanager.spec.templates` itself. vmalert stamps four identity labels onto every alert. A new `scripts/validate-alertmanager-templates.sh` extracts both the rendered template ConfigMap and the rendered Alertmanager config Secret out of `.bundle/`, renders every templated string with `amtool template render` against five JSON fixtures, and golden-compares the result.

**Tech Stack:** Alertmanager v0.32.1 Go templates (`text/template` + Alertmanager's function set), `victoria-metrics-k8s-stack` chart 0.92.1, Flux post-build substitution, OpenTofu, bash + python3/PyYAML gates, mise.

**Spec:** [`docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md`](../specs/2026-09-12-slack-alert-notifications-design.md)

## Global Constraints

- **Never write a literal `${` in the template body unless the variable is a real Flux key.** Flux post-build substitution expands `${var}` and would replace it with an empty string. Bare `$var` (Go template variables) is untouched and safe. `${private_domain_name}` **is** deliberate — it is defined in both clusters' `flux_cluster_vars`.
- **Alertmanager ships no sprig.** The only functions available are `append base64decode base64encode date dict humanizeDuration join list match now reReplaceAll routeLabels safeHtml safeUrl since stringSlice title toJson toLower toUpper trimSpace tz urlUnescape`, plus Go builtins (`len index slice printf urlquery eq ne lt gt and or not with range`). **There is no `default`, and no arithmetic.** Never write `default`, `sub`, `add`, `min`, `max`, `trunc`, `b64enc`.
- **Every optional label or annotation is guarded** with `{{ if }}`/`{{ with }}` and falls back to an em dash `—` or an omitted segment. A missing label must never render as an empty Slack field or a dead button URL.
- **Annotation contract:** `summary` required (one line, ≤140 chars); `description` optional and unbounded; `runbook_url` and `dashboard` optional.
- **Resource naming and ownership:** compositions are not edited in this repo; nothing here touches Crossplane.
- **Commit messages and PR text are English**, no co-author or attribution trailers.
- **Evidence before completion:** every "passes" claim needs a fresh command run in the same message, per `.claude/rules/process.md`.

---

### Task 1: The `cloud` ConfigMap key

Adds the one identity label that does not already exist as a Flux variable, on both clouds plus the render fixture. Nothing consumes it yet — that is deliberate, so this lands and can be applied to both clusters before any manifest references it.

**Files:**
- Modify: `opentofu/aws/eks/configure/kubernetes.tf` (the `flux_cluster_vars` `data` map)
- Modify: `opentofu/gcp/gke/configure/kubernetes.tf` (the `flux_cluster_vars` `data` map)
- Modify: `scripts/flux-schema/render-bundle.py` (the `FIXTURE_VARS` and `CLUSTER_FIXTURE_VARS` dicts)
- Test: `scripts/flux-schema/check-substitution.py` (existing, no edit)

**Interfaces:**
- Consumes: nothing.
- Produces: Flux variable `${cloud}` — `"aws"` on `aws-0`, `"gcp"` on `gcp-0`. Task 4 reads it via `vmalert.spec.externalLabels`.

- [ ] **Step 1: Add the key to the AWS ConfigMap**

In `opentofu/aws/eks/configure/kubernetes.tf`, inside the `data = {` block of `resource "kubectl_manifest" "flux_cluster_vars"`, next to `environment`:

```hcl
      environment   = var.env
      # Which cloud this cluster runs on, as a plain alert/label value. Hardcoded
      # per lane rather than derived from the cluster name: `aws-0` happens to be
      # prefixed today, and a label that silently follows a naming convention
      # breaks the first time a cluster is named something else.
      cloud = "aws"
```

- [ ] **Step 2: Add the key to the GCP ConfigMap**

In `opentofu/gcp/gke/configure/kubernetes.tf`, inside the same `data = {` block, next to `environment`:

```hcl
      environment         = var.env
      # See the AWS lane's copy of this key: hardcoded per lane, not derived
      # from the cluster name.
      cloud = "gcp"
```

- [ ] **Step 3: Add the render fixture**

In `scripts/flux-schema/render-bundle.py`, in the `FIXTURE_VARS` dict, next to `"region"`:

```python
    # Both lanes define `cloud`, so unlike `region` this fixture is not
    # AWS-shaped by necessity -- it is AWS-shaped because the bundle renders
    # once and cannot know which cluster it is standing in. A manifest that
    # branches on the VALUE of ${cloud} would therefore be unvalidated for gcp-0;
    # nothing does today, and the label is only ever displayed.
    "cloud": "aws",
```

- [ ] **Step 3b: Add the gcp-0 override**

In the same file, in `CLUSTER_FIXTURE_VARS["gcp-0"]`, next to `"region"`:

```python
        "cloud": "gcp",
```

This does not affect the Slack templates — `observability/base/` belongs to no cluster, so `cluster_of()` returns `None` and it renders from the merged AWS-shaped map. It is added because a gcp-0-scoped manifest that ever reads `${cloud}` should render `gcp`, and the merged map would silently hand it `aws`.

- [ ] **Step 4: Verify the substitution wiring sees both keys**

Run:
```bash
python3 scripts/flux-schema/check-substitution.py && tofu fmt -check -recursive opentofu/
```
Expected: exit 0 from both. `check-substitution.py` reads the two `.tf` files directly, so a key added to only one lane would be reported the first time a manifest uses it.

- [ ] **Step 5: Commit**

```bash
git add opentofu/aws/eks/configure/kubernetes.tf opentofu/gcp/gke/configure/kubernetes.tf scripts/flux-schema/render-bundle.py
git commit -m "feat(observability): publish the cloud name as a Flux variable

Alerts are about to carry cluster, env, cloud and region so a Slack
message says which of the two clusters it came from. environment and
region already exist in both flux_cluster_vars ConfigMaps; cloud did not."
```

---

### Task 2: Annotation contract and its gate

Test-first in the literal sense: the gate goes in before the rename, fails on 19 alerts, and passes once they are renamed.

**Files:**
- Modify: `scripts/validate-vmrules.sh` (the embedded python block)
- Modify: `observability/base/victoria-metrics-k8s-stack/vmrules/openbao.yaml` (7)
- Modify: `observability/base/victoria-metrics-k8s-stack/vmrules/cert-manager.yaml` (2)
- Modify: `observability/aws-0/victoria-metrics-k8s-stack/vmrules/karpenter.yaml` (3)
- Modify: `flux/observability/vmrule.yaml` (3)
- Modify: `infrastructure/base/cilium/vmrules.yaml` (2)
- Modify: `observability/base/kubernetes-event-exporter/vmrule.yaml` (1)
- Modify: `observability/base/loggen/demo-vmrule.yaml` (1)

**Interfaces:**
- Consumes: nothing.
- Produces: the guarantee that every repo-authored alert carries `annotations.summary`. Task 4's template still implements the `summary → message → description` fallback anyway, because chart-shipped rules are outside this gate.

- [ ] **Step 1: Write the failing check**

In `scripts/validate-vmrules.sh`, inside the embedded python block. Add the collector next to the existing ones (near `failures = []`):

```python
annotation_failures = []   # (path, rule_name, alert_name, why)
SUMMARY_MAX = 140
```

Then, inside the `for group in groups:` loop, **before** the `if gtype not in PROMQL_TYPES:` skip — annotations are language-independent, so a `type: vlogs` group is checked here even though promtool never sees it:

```python
            for rule in group.get("rules") or []:
                if not isinstance(rule, dict) or "alert" not in rule:
                    continue          # recording rules have no annotations
                alert = rule.get("alert", "<unnamed>")
                summary = ((rule.get("annotations") or {}).get("summary") or "").strip()
                if not summary:
                    annotation_failures.append((
                        path, name, alert,
                        "no `annotations.summary` — Slack renders the summary as the "
                        "headline and falls back to the description, which is where "
                        "runbook prose lives",
                    ))
                elif "\n" in summary:
                    annotation_failures.append((
                        path, name, alert,
                        "`annotations.summary` spans multiple lines — it is one line "
                        "in a Slack message; put detail in `description`",
                    ))
                elif len(summary) > SUMMARY_MAX:
                    annotation_failures.append((
                        path, name, alert,
                        "`annotations.summary` is %d characters (max %d)"
                        % (len(summary), SUMMARY_MAX),
                    ))
```

Then, in the reporting section, **before** the existing `if failures:` block:

```python
if annotation_failures:
    print()
    for path, name, alert, why in annotation_failures:
        print("INVALID  %s" % path)
        print("    VMRule %s, alert %s" % (name, alert))
        print("    %s" % why)
    print()
    print(
        "%d alert(s) do not meet the annotation contract.\n"
        "`summary` is required: one line, <= %d characters, the sentence a human\n"
        "reads first in Slack. `description` is optional and unbounded -- Slack\n"
        "truncates it, RunLore reads all of it.\n"
        "See docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md"
        % (len(annotation_failures), SUMMARY_MAX)
    )
    sys.exit(1)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./scripts/validate-vmrules.sh`
Expected: FAIL, exit 1, listing **19 alerts** with "no `annotations.summary`" across 7 files — `openbao.yaml` (7), `flux/observability/vmrule.yaml` (3), `karpenter.yaml` (3), `cert-manager.yaml` (2), `cilium/vmrules.yaml` (2), `kubernetes-event-exporter/vmrule.yaml` (1), `loggen/demo-vmrule.yaml` (1).

If the count is not 19, stop and reconcile before renaming anything — the spec's table is the baseline and a different number means the rule set moved.

- [ ] **Step 3: Rename `message:` to `summary:`**

Only inside `annotations:` blocks of VMRules. Run:

```bash
sed -i 's/^\( *\)message:/\1summary:/' \
  observability/base/victoria-metrics-k8s-stack/vmrules/openbao.yaml \
  observability/base/victoria-metrics-k8s-stack/vmrules/cert-manager.yaml \
  observability/aws-0/victoria-metrics-k8s-stack/vmrules/karpenter.yaml \
  flux/observability/vmrule.yaml \
  infrastructure/base/cilium/vmrules.yaml \
  observability/base/kubernetes-event-exporter/vmrule.yaml \
  observability/base/loggen/demo-vmrule.yaml
git diff --stat
```

Then read `git diff` in full. Two things to check by eye, because `sed` cannot:
1. No `message:` key outside an `annotations:` block was renamed (there is none today — confirm).
2. No renamed value is multi-line or over 140 characters. `openbao.yaml` uses short single-line messages (`message: OpenBao is unreachable.`) and `cert-manager.yaml` uses a templated one-liner, so all 19 should pass — but the gate is the arbiter, not this sentence.

- [ ] **Step 4: Run the gate again**

Run: `./scripts/validate-vmrules.sh`
Expected: PASS, exit 0, with the existing summary line reporting the PromQL groups and `1 group(s) / 1 rule(s) skipped` (the `loggen` `type: vlogs` group — unchanged by this task).

- [ ] **Step 5: Commit**

```bash
git add scripts/validate-vmrules.sh observability infrastructure flux
git commit -m "feat(observability): require a summary annotation on every alert

The Slack template renders summary as the headline and falls back to
description -- which is where runbook prose lives, so a rule without a
summary pastes a runbook into the channel. 19 alerts across 7 files used
message instead; they are renamed, and validate-vmrules.sh now holds the
contract so the next one cannot regress it.

No exemption list: all 45 repo-authored alerts pass."
```

---

### Task 3: The gate, before the template exists

The gate is written first and must fail for the right reason: there is no `ogenki.tmpl` in the bundle yet.

**Files:**
- Modify: `mise.toml`
- Create: `scripts/validate-alertmanager-templates.sh`
- Create: `scripts/alertmanager-fixtures/critical-single.json`
- Create: `scripts/alertmanager-fixtures/warning-group-of-3.json`
- Create: `scripts/alertmanager-fixtures/resolved.json`
- Create: `scripts/alertmanager-fixtures/mixed-firing-resolved.json`
- Create: `scripts/alertmanager-fixtures/degenerate.json`
- Modify: `scripts/validate-manifests.sh`

**Interfaces:**
- Consumes: `.bundle/` as produced by `scripts/flux-schema/render-bundle.py`.
- Produces: `./scripts/validate-alertmanager-templates.sh` (exit 0 = every templated string in the rendered Slack receiver renders against every fixture and matches its golden file) and `./scripts/validate-alertmanager-templates.sh --update-golden` (rewrites `scripts/alertmanager-fixtures/golden/*.txt`).

- [ ] **Step 1: Pin amtool**

In `mise.toml`, after the `promtool` entry:

```toml
# amtool renders the Slack notification templates against fixture payloads
# (scripts/validate-alertmanager-templates.sh) with no cluster and no running
# Alertmanager. Pinned to the version the victoria-metrics-k8s-stack chart runs
# (alertmanager.spec.image.tag in its values.yaml), because the renderer IS the
# gate: a template using a function the cluster's Alertmanager does not have
# must fail here, not at notification time. amtool ships inside the alertmanager
# release archive.
"aqua:prometheus/alertmanager" = "0.32.1"
```

- [ ] **Step 2: Verify amtool resolves and has the subcommand**

Run:
```bash
mise install
mise which amtool -C . || ls "$(mise where aqua:prometheus/alertmanager)"
"$(mise which amtool -C .)" template render --help | head -20
```
Expected: a path under `~/.local/share/mise/installs/`, and help text listing `--template.glob`, `--template.text`, `--template.data`.

If `mise which amtool` finds nothing but the install directory contains an `amtool` binary, that is fine — Step 4's script resolves via `mise where` as a fallback. If the aqua package does not exist under that name, switch the entry to `"ubi:prometheus/alertmanager" = "0.32.1"` and re-run; do not fall back to an unpinned PATH binary.

- [ ] **Step 3: Write the fixtures**

`scripts/alertmanager-fixtures/critical-single.json` — one critical alert, full identity, long multi-line description:

```json
{
  "receiver": "slack-monitoring",
  "status": "firing",
  "version": "4",
  "groupKey": "{}/{}:{alertname=\"OpenBaoRaftQuorumAtRisk\", cluster=\"aws-0\"}",
  "externalURL": "https://vmalertmanager-aws-0.priv.aws.ogenki.io",
  "groupLabels": {"alertname": "OpenBaoRaftQuorumAtRisk", "cluster": "aws-0", "severity": "critical", "namespace": "security"},
  "commonLabels": {"alertname": "OpenBaoRaftQuorumAtRisk", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "critical", "namespace": "security", "job": "openbao"},
  "commonAnnotations": {
    "summary": "OpenBao raft cluster cannot tolerate a node failure.",
    "description": "Failure tolerance has been below 1 for 15 minutes: losing one more\nnode loses quorum, and a cluster without quorum cannot issue a\ncertificate or read a secret. If OpenBaoRaftNodeLost fired first\nand was not acted on, this is that same dead peer plus a real one.",
    "runbook_url": "https://openbao.org/docs/internals/telemetry/",
    "dashboard": "https://grafana.priv.aws.ogenki.io/dashboards"
  },
  "alerts": [
    {
      "status": "firing",
      "labels": {"alertname": "OpenBaoRaftQuorumAtRisk", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "critical", "namespace": "security", "job": "openbao", "instance": "10.0.12.44:8200"},
      "annotations": {
        "summary": "OpenBao raft cluster cannot tolerate a node failure.",
        "description": "Failure tolerance has been below 1 for 15 minutes: losing one more\nnode loses quorum, and a cluster without quorum cannot issue a\ncertificate or read a secret. If OpenBaoRaftNodeLost fired first\nand was not acted on, this is that same dead peer plus a real one.",
        "runbook_url": "https://openbao.org/docs/internals/telemetry/",
        "dashboard": "https://grafana.priv.aws.ogenki.io/dashboards"
      },
      "startsAt": "2026-09-12T09:06:00Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=1&alert_id=1",
      "fingerprint": "0000000000000001"
    }
  ]
}
```

`scripts/alertmanager-fixtures/warning-group-of-3.json` — three alerts on `gcp-0`, shared summary, per-alert descriptions, no `dashboard` annotation:

```json
{
  "receiver": "slack-monitoring",
  "status": "firing",
  "version": "4",
  "groupKey": "{}/{}:{alertname=\"KubePodCrashLooping\", cluster=\"gcp-0\"}",
  "externalURL": "https://vmalertmanager-gcp-0.priv.gcp.ogenki.io",
  "groupLabels": {"alertname": "KubePodCrashLooping", "cluster": "gcp-0", "severity": "warning", "namespace": "apps"},
  "commonLabels": {"alertname": "KubePodCrashLooping", "cluster": "gcp-0", "env": "dev", "cloud": "gcp", "region": "europe-west1", "severity": "warning", "namespace": "apps"},
  "commonAnnotations": {"summary": "Pod is restarting repeatedly.", "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/kubepodcrashlooping"},
  "alerts": [
    {"status": "firing", "labels": {"alertname": "KubePodCrashLooping", "cluster": "gcp-0", "env": "dev", "cloud": "gcp", "region": "europe-west1", "severity": "warning", "namespace": "apps", "pod": "podinfo-7d8f"}, "annotations": {"summary": "Pod is restarting repeatedly.", "description": "12 restarts in 10m", "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/kubepodcrashlooping"}, "startsAt": "2026-09-12T09:12:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=2&alert_id=1", "fingerprint": "b1"},
    {"status": "firing", "labels": {"alertname": "KubePodCrashLooping", "cluster": "gcp-0", "env": "dev", "cloud": "gcp", "region": "europe-west1", "severity": "warning", "namespace": "apps", "pod": "podinfo-9f2c"}, "annotations": {"summary": "Pod is restarting repeatedly.", "description": "8 restarts in 10m", "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/kubepodcrashlooping"}, "startsAt": "2026-09-12T09:12:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=2&alert_id=2", "fingerprint": "b2"},
    {"status": "firing", "labels": {"alertname": "KubePodCrashLooping", "cluster": "gcp-0", "env": "dev", "cloud": "gcp", "region": "europe-west1", "severity": "warning", "namespace": "apps", "pod": "podinfo-b1a4"}, "annotations": {"summary": "Pod is restarting repeatedly.", "description": "5 restarts in 10m", "runbook_url": "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/kubepodcrashlooping"}, "startsAt": "2026-09-12T09:12:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=2&alert_id=3", "fingerprint": "b3"}
  ]
}
```

`scripts/alertmanager-fixtures/resolved.json` — the resolved branch, with `endsAt` set:

```json
{
  "receiver": "slack-monitoring",
  "status": "resolved",
  "version": "4",
  "groupKey": "{}/{}:{alertname=\"TargetDown\", cluster=\"aws-0\"}",
  "externalURL": "https://vmalertmanager-aws-0.priv.aws.ogenki.io",
  "groupLabels": {"alertname": "TargetDown", "cluster": "aws-0", "severity": "warning", "namespace": "kube-system"},
  "commonLabels": {"alertname": "TargetDown", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "warning", "namespace": "kube-system", "job": "core-dns"},
  "commonAnnotations": {"summary": "One or more targets are unreachable.", "description": "100% of the core-dns/victoria-metrics-k8s-stack-core-dns targets in kube-system namespace are down.", "dashboard": "https://grafana.priv.aws.ogenki.io/dashboards"},
  "alerts": [
    {"status": "resolved", "labels": {"alertname": "TargetDown", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "warning", "namespace": "kube-system", "job": "core-dns"}, "annotations": {"summary": "One or more targets are unreachable.", "description": "100% of the core-dns/victoria-metrics-k8s-stack-core-dns targets in kube-system namespace are down.", "dashboard": "https://grafana.priv.aws.ogenki.io/dashboards"}, "startsAt": "2026-09-12T09:05:00Z", "endsAt": "2026-09-12T09:11:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=3&alert_id=1", "fingerprint": "c1"}
  ]
}
```

`scripts/alertmanager-fixtures/mixed-firing-resolved.json` — a firing notification that also carries a resolved member, so `.Alerts.Firing` and `len .Alerts` differ:

```json
{
  "receiver": "slack-monitoring",
  "status": "firing",
  "version": "4",
  "groupKey": "{}/{}:{alertname=\"CPUThrottlingHigh\", cluster=\"aws-0\"}",
  "externalURL": "https://vmalertmanager-aws-0.priv.aws.ogenki.io",
  "groupLabels": {"alertname": "CPUThrottlingHigh", "cluster": "aws-0", "severity": "info", "namespace": "tooling"},
  "commonLabels": {"alertname": "CPUThrottlingHigh", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "info", "namespace": "tooling"},
  "commonAnnotations": {"summary": "Processes are being throttled by their CPU limit."},
  "alerts": [
    {"status": "firing", "labels": {"alertname": "CPUThrottlingHigh", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "info", "namespace": "tooling", "pod": "xplane-harbor-valkey-0", "container": "metrics"}, "annotations": {"summary": "Processes are being throttled by their CPU limit.", "description": "27.78% throttling of CPU"}, "startsAt": "2026-09-12T08:40:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=4&alert_id=1", "fingerprint": "d1"},
    {"status": "firing", "labels": {"alertname": "CPUThrottlingHigh", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "info", "namespace": "tooling", "pod": "xplane-harbor-core-5f", "container": "core"}, "annotations": {"summary": "Processes are being throttled by their CPU limit.", "description": "31.02% throttling of CPU"}, "startsAt": "2026-09-12T08:41:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=4&alert_id=2", "fingerprint": "d2"},
    {"status": "resolved", "labels": {"alertname": "CPUThrottlingHigh", "cluster": "aws-0", "env": "dev", "cloud": "aws", "region": "eu-west-3", "severity": "info", "namespace": "tooling", "pod": "xplane-harbor-jobservice-7a", "container": "jobservice"}, "annotations": {"summary": "Processes are being throttled by their CPU limit.", "description": "26.10% throttling of CPU"}, "startsAt": "2026-09-12T08:20:00Z", "endsAt": "2026-09-12T08:55:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=4&alert_id=3", "fingerprint": "d3"}
  ]
}
```

`scripts/alertmanager-fixtures/degenerate.json` — every guard at once: no namespace, no summary, no `runbook_url`, no `dashboard`, empty `cloud` and `region` (the pre-apply state from Task 1), and **seven** alerts so the ≤5 cap fires:

```json
{
  "receiver": "slack-monitoring",
  "status": "firing",
  "version": "4",
  "groupKey": "{}/{}:{alertname=\"NodeFilesystemAlmostOutOfSpace\"}",
  "externalURL": "https://vmalertmanager-aws-0.priv.aws.ogenki.io",
  "groupLabels": {"alertname": "NodeFilesystemAlmostOutOfSpace"},
  "commonLabels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "env": "", "cloud": "", "region": ""},
  "commonAnnotations": {},
  "alerts": [
    {"status": "firing", "labels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "instance": "10.0.1.11:9100"}, "annotations": {"description": "Filesystem on /dev/nvme0n1p1 at 10.0.1.11:9100 has only 3.24% available space left and is filling up fast. This host has been reporting steadily decreasing free space for the last six hours and will run out within the day at the current rate, which will evict pods and wedge the kubelet."}, "startsAt": "2026-09-12T07:00:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=5&alert_id=1", "fingerprint": "e1"},
    {"status": "firing", "labels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "instance": "10.0.1.12:9100"}, "annotations": {"description": "Filesystem at 10.0.1.12:9100 has only 4.10% available space left."}, "startsAt": "2026-09-12T07:01:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=5&alert_id=2", "fingerprint": "e2"},
    {"status": "firing", "labels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "instance": "10.0.1.13:9100"}, "annotations": {"description": "Filesystem at 10.0.1.13:9100 has only 4.55% available space left."}, "startsAt": "2026-09-12T07:02:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=5&alert_id=3", "fingerprint": "e3"},
    {"status": "firing", "labels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "instance": "10.0.1.14:9100"}, "annotations": {"description": "Filesystem at 10.0.1.14:9100 has only 4.70% available space left."}, "startsAt": "2026-09-12T07:03:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=5&alert_id=4", "fingerprint": "e4"},
    {"status": "firing", "labels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "instance": "10.0.1.15:9100"}, "annotations": {"description": "Filesystem at 10.0.1.15:9100 has only 4.81% available space left."}, "startsAt": "2026-09-12T07:04:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=5&alert_id=5", "fingerprint": "e5"},
    {"status": "firing", "labels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "instance": "10.0.1.16:9100"}, "annotations": {"description": "Filesystem at 10.0.1.16:9100 has only 4.92% available space left."}, "startsAt": "2026-09-12T07:05:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=5&alert_id=6", "fingerprint": "e6"},
    {"status": "firing", "labels": {"alertname": "NodeFilesystemAlmostOutOfSpace", "cluster": "aws-0", "instance": "10.0.1.17:9100"}, "annotations": {"description": "Filesystem at 10.0.1.17:9100 has only 4.99% available space left."}, "startsAt": "2026-09-12T07:06:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://vmalert-victoria-metrics-k8s-stack.observability:8080/vmalert/alert?group_id=5&alert_id=7", "fingerprint": "e7"}
  ]
}
```

- [ ] **Step 4: Write the gate**

Create `scripts/validate-alertmanager-templates.sh`, `chmod +x`:

```bash
#!/usr/bin/env bash
#
# validate-alertmanager-templates.sh — render the Slack notification templates.
#
# `flux schema validate` proves the Alertmanager config is a well-shaped
# Secret; polaris never looks at it. Neither one parses the Go templates
# inside, and a template that fails to parse or execute does not degrade
# gracefully: Alertmanager drops the notification. Every alert, silently, for
# as long as the template is broken. That is the same failure mode
# validate-vmrules.sh exists to prevent, one layer further out.
#
# What is rendered, and why it comes from the bundle rather than the source:
# the message is assembled from TWO places. The Go templates live in
# alertmanager.templateFiles (-> a ConfigMap), but `fallback`, every
# `fields[].value` and all four button URLs are templated strings inside the
# receiver in the Alertmanager config Secret. Reading the rendered bundle gets
# both, already Flux-substituted -- so an unsubstituted ${var} or a typo in a
# field value fails here too.
#
# Durations are not golden-compared: `since` measures against wall-clock now,
# so the Duration field is asserted against a regex instead and masked in the
# golden output. Everything else is byte-compared.
#
#   ./scripts/validate-alertmanager-templates.sh                 # check
#   ./scripts/validate-alertmanager-templates.sh --update-golden # rewrite goldens
#
# Requires a rendered bundle. validate-manifests.sh runs this after the render;
# standalone, run that script first or set BUNDLE_DIR to an existing bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

BUNDLE_DIR="${BUNDLE_DIR:-.bundle}"
MODE="${1:-check}"

if [ ! -d "${BUNDLE_DIR}" ]; then
  echo "error: no bundle at ${BUNDLE_DIR}." >&2
  echo "       Fix: ./scripts/validate-manifests.sh  (renders it), or set BUNDLE_DIR." >&2
  exit 2
fi

# Same resolution precedence as validate-vmrules.sh: explicit override > mise
# scoped to this repo > bare PATH. The pin is what makes "it renders" mean the
# same thing on a laptop and in CI.
if [ -n "${AMTOOL_BIN:-}" ]; then
  if [ ! -x "${AMTOOL_BIN}" ]; then
    echo "error: \$AMTOOL_BIN='${AMTOOL_BIN}' is set but is not an executable file." >&2
    exit 2
  fi
else
  AMTOOL_BIN=""
  if command -v mise >/dev/null 2>&1 && [ -f "${REPO_ROOT}/mise.toml" ]; then
    AMTOOL_BIN="$(mise which -C "${REPO_ROOT}" amtool 2>/dev/null || true)"
    if [ -z "${AMTOOL_BIN}" ]; then
      _where="$(mise where -C "${REPO_ROOT}" aqua:prometheus/alertmanager 2>/dev/null || true)"
      [ -n "${_where}" ] && AMTOOL_BIN="$(find "${_where}" -name amtool -type f -perm -u+x | head -1)"
    fi
  fi
  [ -z "${AMTOOL_BIN}" ] && AMTOOL_BIN="$(command -v amtool 2>/dev/null || true)"
fi

if [ -z "${AMTOOL_BIN}" ]; then
  echo "error: amtool not found (checked \$AMTOOL_BIN, mise, PATH)." >&2
  echo "       amtool ships inside the alertmanager release archive and is pinned" >&2
  echo "       in mise.toml. Fix: mise install  (or set AMTOOL_BIN)" >&2
  exit 2
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "error: the Python 'yaml' module (PyYAML) is not installed." >&2
  exit 2
fi

python3 - "${AMTOOL_BIN}" "${BUNDLE_DIR}" "${MODE}" <<'PY'
import difflib
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

amtool, bundle_dir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
update = mode == "--update-golden"

FIXTURE_DIR = pathlib.Path("scripts/alertmanager-fixtures")
GOLDEN_DIR = FIXTURE_DIR / "golden"
TEMPLATE_KEY = "ogenki.tmpl"
RECEIVER = "slack-monitoring"
# The one field whose rendered value moves with wall-clock time.
VOLATILE_FIELD = "field:Duration"
DURATION_RE = re.compile(r"^(\d|resolved after).*")

tmpl_text = None
slack = None

for path in sorted(pathlib.Path(bundle_dir).rglob("*.yaml")):
    try:
        docs = list(yaml.safe_load_all(path.read_text(encoding="utf-8", errors="replace")))
    except yaml.YAMLError:
        continue
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        if doc.get("kind") == "ConfigMap":
            data = doc.get("data") or {}
            if TEMPLATE_KEY in data:
                tmpl_text = data[TEMPLATE_KEY]
        if doc.get("kind") == "Secret":
            raw = (doc.get("stringData") or {}).get("alertmanager.yaml")
            if not raw:
                continue
            try:
                cfg = yaml.safe_load(raw)
            except yaml.YAMLError:
                continue
            for recv in (cfg or {}).get("receivers") or []:
                if recv.get("name") != RECEIVER:
                    continue
                for sc in recv.get("slack_configs") or []:
                    slack = sc

if tmpl_text is None:
    print("error: no ConfigMap in %s carries a %r key." % (bundle_dir, TEMPLATE_KEY))
    print("       The Slack templates ship via alertmanager.templateFiles in")
    print("       observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml.")
    sys.exit(1)

if slack is None:
    print("error: no receiver %r with a slack_configs entry in the rendered "
          "Alertmanager config." % RECEIVER)
    sys.exit(1)

# Every templated string the receiver hands to Slack, in render order.
targets = []
for key in ("color", "fallback", "title", "title_link", "text"):
    if key in slack:
        targets.append((key, slack[key]))
for field in slack.get("fields") or []:
    targets.append(("field:%s" % field.get("title", "<untitled>"), field.get("value", "")))
for action in slack.get("actions") or []:
    targets.append(("action:%s" % action.get("text", "<untitled>"), action.get("url", "")))

BAD = (("<no value>", "a template referenced a field that does not exist"),
       ("${", "a Flux variable was never substituted"),
       ("%!", "a Go format verb failed"))

with tempfile.NamedTemporaryFile("w", suffix=".tmpl", delete=False, encoding="utf-8") as fh:
    fh.write(tmpl_text)
    tmpl_path = fh.name

failures = []
rendered_files = 0

try:
    for fixture in sorted(FIXTURE_DIR.glob("*.json")):
        chunks = []
        for label, text in targets:
            proc = subprocess.run(
                [amtool, "template", "render",
                 "--template.glob", tmpl_path,
                 "--template.text", text,
                 "--template.data", str(fixture)],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                failures.append((fixture.name, label,
                                 "amtool failed to render:\n%s" % (proc.stderr.strip() or proc.stdout.strip())))
                chunks.append("==> %s\n<RENDER FAILED>" % label)
                continue
            out = proc.stdout.rstrip("\n")
            for needle, why in BAD:
                if needle in out:
                    failures.append((fixture.name, label,
                                     "output contains %r — %s:\n%s" % (needle, why, out)))
            if not out.strip():
                failures.append((fixture.name, label, "rendered empty"))
            if label == VOLATILE_FIELD:
                if not DURATION_RE.match(out.strip()):
                    failures.append((fixture.name, label,
                                     "does not look like a duration: %r" % out))
                out = "<DURATION>"
            chunks.append("==> %s\n%s" % (label, out))

        actual = "\n\n".join(chunks) + "\n"
        golden = GOLDEN_DIR / (fixture.stem + ".txt")
        if update:
            GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
            golden.write_text(actual, encoding="utf-8")
            rendered_files += 1
            continue
        if not golden.exists():
            failures.append((fixture.name, "-", "no golden file at %s — run with --update-golden" % golden))
            continue
        expected = golden.read_text(encoding="utf-8")
        if expected != actual:
            diff = "\n".join(difflib.unified_diff(
                expected.splitlines(), actual.splitlines(),
                fromfile=str(golden), tofile="rendered", lineterm="",
            ))
            failures.append((fixture.name, "-", "output changed:\n%s" % diff))
        rendered_files += 1
finally:
    pathlib.Path(tmpl_path).unlink()

if update:
    print("==> Rewrote %d golden file(s) in %s" % (rendered_files, GOLDEN_DIR))
    print("    Read the diff before committing: it IS the Slack message.")
    sys.exit(0)

if failures:
    print()
    for fixture, label, detail in failures:
        print("INVALID  %s  [%s]" % (fixture, label))
        for line in detail.splitlines():
            print("    %s" % line)
        print()
    print("%d problem(s) rendering the Slack templates.\n"
          "Alertmanager drops a notification whose template fails, so this would\n"
          "be a silent, total loss of alerting. If the change is intentional,\n"
          "re-render with --update-golden and review the diff."
          % len(failures))
    sys.exit(1)

print("==> %d templated string(s) render across %d fixture(s); all match their golden files"
      % (len(targets), rendered_files))
PY
```

- [ ] **Step 5: Run it and watch it fail for the right reason**

Run:
```bash
./scripts/validate-manifests.sh >/dev/null 2>&1 || true   # render a bundle
./scripts/validate-alertmanager-templates.sh
```
Expected: FAIL, exit 1, with `error: no ConfigMap in .bundle carries a 'ogenki.tmpl' key.`

That exact message is the point of this step. Any other failure (amtool missing, bundle missing, PyYAML missing) means the harness is wrong, not the absent template — fix that first.

- [ ] **Step 6: Wire it into `validate-manifests.sh`**

In `scripts/validate-manifests.sh`: extend the header comment list with a sixth item, renumber the existing `[N/5]` echoes to `[N/6]`, and add after the polaris gate:

```bash
echo "==> [6/6] Gate 3 — Alertmanager Slack templates render"
./scripts/validate-alertmanager-templates.sh
```

- [ ] **Step 7: Commit**

```bash
git add mise.toml scripts/validate-alertmanager-templates.sh scripts/alertmanager-fixtures scripts/validate-manifests.sh
git commit -m "test(observability): render the Slack templates in CI

Alertmanager drops a notification whose template fails to execute, so a
broken template is a silent, total loss of alerting -- and nothing in the
repo parsed those templates. amtool renders every templated string in the
rendered receiver against five fixture payloads and golden-compares the
result.

Fails right now, by design: there is no ogenki.tmpl yet."
```

---

### Task 4: The template and the receiver

Makes Task 3's gate pass. This is the whole message.

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`
- Create: `scripts/alertmanager-fixtures/golden/*.txt` (5, generated)
- Modify: `docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md` (field rename)

**Interfaces:**
- Consumes: `${cloud}` from Task 1; the gate from Task 3.
- Produces: templates `slack.ogenki.color`, `slack.ogenki.fallback`, `slack.ogenki.title`, `slack.ogenki.title_link`, `slack.ogenki.text`, `slack.ogenki.field_namespace`, `slack.ogenki.runbook_url`, `slack.ogenki.dashboard_url`, `ogenki.severity`, `ogenki.emoji`, `ogenki.identity`, `ogenki.location`, `ogenki.duration`, `ogenki.headline`, `ogenki.target`, `ogenki.bullet`, `__alert_silence_link`.

- [ ] **Step 1: Rename the field in the spec**

The spec's mockups label the third field **Firing since**, but one static title has to serve both a firing and a resolved notification. Rename it to **Duration**, whose value reads `14m 0s (since 09:06 UTC)` or `6m 0s (resolved 09:11 UTC)`.

```bash
sed -i 's/Firing since     Location/Duration         Location/; s/Firing since 09:12 (4m)  Location   gcp \/ europe-west1/Duration   4m 0s (since 09:12 UTC)   Location   gcp \/ europe-west1/; s/^┃ 09:06 (14m)      aws \/ eu-west-3$/┃ 14m 0s (since 09:06 UTC)  aws \/ eu-west-3/; s/Namespace · Severity · Firing since · Location/Namespace · Severity · Duration · Location/' docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md
grep -n 'Firing since' docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md
```
Expected: no remaining `Firing since` hits. If any survive, edit them by hand.

- [ ] **Step 2: Add the identity labels and turn the Monzo template off**

In `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`, extend the existing `vmalert.spec.externalLabels` block (keep the comment above it, which already explains why these live on vmalert and not vmagent, and add the second paragraph):

```yaml
    vmalert:
      spec:
        externalLabels:
          cluster: "${cluster_name}"
          # env/cloud/region join cluster so a Slack message says WHERE without
          # anyone having to know which cluster runs which workload. They are on
          # vmalert and deliberately not on vmagent: vmalert attaches them to
          # alerts and recording-rule output (a few hundred series), whereas the
          # same four labels on vmagent would attach to every scraped series in
          # the TSDB -- a real cardinality bill for a presentation feature.
          #
          # `cloud` comes from a ConfigMap key added in the same change. Until
          # both `configure` stacks are applied, Flux substitutes it EMPTY; the
          # templates guard for that and drop the segment rather than render
          # "aws-0 · dev · /".
          env: "${environment}"
          cloud: "${cloud}"
          region: "${region}"
```

- [ ] **Step 3: Add the template file**

In the same file, under `alertmanager:` and **as a sibling of `spec:` and `config:`** (i.e. at `alertmanager.monzoTemplate` / `alertmanager.templateFiles`), insert before `config:`:

```yaml
      # The chart vendors Monzo's 2018 templates and enables them by default.
      # They were written for one cluster: they print no cluster, environment,
      # cloud, region, label or duration, and they print `message` and
      # `description` in full -- so a rule whose description is a runbook pastes
      # that runbook into the channel. Replaced wholesale below.
      #
      # Turning this off also deletes `__alert_silence_link`, which is defined in
      # that template and used by the Silence button. It is redefined in ours.
      monzoTemplate:
        enabled: false

      # The chart renders this map into a `<fullname>-extra-tpl` ConfigMap and
      # appends it to VMAlertmanager.spec.templates itself (see its
      # _helpers.tpl, `vm.alertmanager.spec`). Values are inserted raw -- no
      # `tpl` -- so Go template syntax survives Helm untouched.
      #
      # TWO RULES FOR EDITING THIS BLOCK:
      #
      # 1. Never write a literal `${`. Flux post-build substitution expands
      #    `${var}` and replaces an unknown one with an EMPTY STRING. Bare `$var`
      #    -- every Go template variable below -- is untouched and safe. The one
      #    `${private_domain_name}` below is deliberate: it is a real key in both
      #    clusters' ConfigMaps, and the gate asserts no `${` survives rendering.
      #
      # 2. Alertmanager ships NO sprig. There is no `default`, and no arithmetic
      #    (`sub`, `add`, `min`). Available: append base64decode base64encode
      #    date dict humanizeDuration join list match now reReplaceAll
      #    routeLabels safeHtml safeUrl since stringSlice title toJson toLower
      #    toUpper trimSpace tz urlUnescape, plus Go builtins (len index slice
      #    printf urlquery eq ne lt gt and or not with range).
      #
      # ./scripts/validate-alertmanager-templates.sh renders every string below
      # against five fixture payloads and golden-compares the output. A template
      # that fails to execute makes Alertmanager DROP the notification, so this
      # is the difference between a formatting bug and silent total alert loss.
      templateFiles:
        ogenki.tmpl: |-
          {{/* ───────────────────────── helpers ───────────────────────── */}}

          {{/* Severity, never empty. */}}
          {{- define "ogenki.severity" -}}
          {{- if .CommonLabels.severity }}{{ .CommonLabels.severity }}{{ else }}unknown{{ end -}}
          {{- end }}

          {{/* Leading emoji. :lgtm: is a workspace custom emoji already in use. */}}
          {{- define "ogenki.emoji" -}}
          {{- if ne .Status "firing" -}}:lgtm:
          {{- else if eq .CommonLabels.severity "critical" -}}:fire:
          {{- else if eq .CommonLabels.severity "warning" -}}:warning:
          {{- else if eq .CommonLabels.severity "info" -}}:information_source:
          {{- else -}}:question:
          {{- end -}}
          {{- end }}

          {{/* "aws-0 · dev". Drops the env segment rather than render a dangling
               separator when the label is empty. */}}
          {{- define "ogenki.identity" -}}
          {{- if .CommonLabels.cluster }}{{ .CommonLabels.cluster }}{{ else }}unknown-cluster{{ end -}}
          {{- with .CommonLabels.env }} · {{ . }}{{ end -}}
          {{- end }}

          {{/* "aws / eu-west-3", degrading to either half, then to an em dash.
               Empty strings are falsy, which is what makes the pre-apply
               `cloud: ""` state render correctly instead of as " / eu-west-3". */}}
          {{- define "ogenki.location" -}}
          {{- if and .CommonLabels.cloud .CommonLabels.region -}}
          {{ .CommonLabels.cloud }} / {{ .CommonLabels.region }}
          {{- else if .CommonLabels.cloud -}}{{ .CommonLabels.cloud }}
          {{- else if .CommonLabels.region -}}{{ .CommonLabels.region }}
          {{- else -}}—{{- end -}}
          {{- end }}

          {{/* "14m 0s (since 09:06 UTC)" / "6m 0s (resolved 09:11 UTC)".
               UTC is explicit and deliberate: `tz` would need tzdata in the
               container, and a missing zone is a template execution error --
               which drops the notification. */}}
          {{- define "ogenki.duration" -}}
          {{- $a := index .Alerts 0 -}}
          {{- if eq .Status "firing" -}}
          {{ humanizeDuration (since $a.StartsAt).Seconds }} (since {{ $a.StartsAt.UTC.Format "15:04 MST" }})
          {{- else -}}
          resolved after {{ humanizeDuration ($a.EndsAt.Sub $a.StartsAt).Seconds }} (at {{ $a.EndsAt.UTC.Format "15:04 MST" }})
          {{- end -}}
          {{- end }}

          {{/* The one-line headline. Group-wide annotations win over the first
               alert's; summary wins over message wins over description. A rule
               with only a description lands here with its whole body, so this
               truncates -- that is the runbook-in-the-channel fix. */}}
          {{- define "ogenki.headline" -}}
          {{- $a := index .Alerts 0 -}}
          {{- $h := "" -}}
          {{- if .CommonAnnotations.summary }}{{ $h = .CommonAnnotations.summary }}
          {{- else if .CommonAnnotations.message }}{{ $h = .CommonAnnotations.message }}
          {{- else if $a.Annotations.summary }}{{ $h = $a.Annotations.summary }}
          {{- else if $a.Annotations.message }}{{ $h = $a.Annotations.message }}
          {{- else if .CommonAnnotations.description }}{{ $h = .CommonAnnotations.description }}
          {{- else if $a.Annotations.description }}{{ $h = $a.Annotations.description }}
          {{- else }}{{ $h = "(this alert sets no summary annotation)" }}{{ end -}}
          {{- $h = reReplaceAll "\\s+" " " $h -}}
          {{- if gt (len $h) 280 }}{{ slice $h 0 280 }}…{{ else }}{{ $h }}{{ end -}}
          {{- end }}

          {{/* What one alert in the group is ABOUT: the most specific identifier
               its labels carry. */}}
          {{- define "ogenki.target" -}}
          {{- $l := .Labels -}}
          {{- if and $l.namespace $l.pod -}}{{ $l.namespace }}/{{ $l.pod }}
          {{- else if $l.pod -}}{{ $l.pod }}
          {{- else if $l.instance -}}{{ $l.instance }}
          {{- else if $l.node -}}{{ $l.node }}
          {{- else if $l.job -}}{{ $l.job }}
          {{- else if $l.namespace -}}{{ $l.namespace }}
          {{- else -}}{{ .Fingerprint }}{{- end -}}
          {{- end }}

          {{/* One bullet per alert. The description is shown only when the alert
               ALSO has a summary or message -- otherwise the description is
               already the headline and would print twice. */}}
          {{- define "ogenki.bullet" -}}
          {{ template "ogenki.target" . }}
          {{- if and .Annotations.description (or .Annotations.summary .Annotations.message) -}}
          {{- $d := reReplaceAll "\\s+" " " .Annotations.description -}}
          {{- " — " -}}
          {{- if gt (len $d) 180 }}{{ slice $d 0 180 }}…{{ else }}{{ $d }}{{ end -}}
          {{- end -}}
          {{- end }}

          {{/* Silence link. Redefined here because disabling the chart's Monzo
               template deletes the original. The alertname is appended last so
               the label list has no trailing separator. */}}
          {{- define "__alert_silence_link" -}}
          {{ .ExternalURL }}/#/silences/new?filter=%7B
          {{- range .CommonLabels.SortedPairs -}}
          {{- if ne .Name "alertname" -}}
          {{- .Name }}%3D"{{- .Value | urlquery -}}"%2C%20
          {{- end -}}
          {{- end -}}
          alertname%3D"{{ .CommonLabels.alertname }}"%7D
          {{- end }}

          {{/* ──────────────────── receiver entry points ──────────────────── */}}

          {{- define "slack.ogenki.color" -}}
          {{- if ne .Status "firing" -}}good
          {{- else if eq .CommonLabels.severity "critical" -}}danger
          {{- else if eq .CommonLabels.severity "warning" -}}warning
          {{- else -}}#439FE0
          {{- end -}}
          {{- end }}

          {{/* What Slack shows in push notifications and channel previews. It
               was unset before, which is why a phone notification said nothing
               useful. */}}
          {{- define "slack.ogenki.fallback" -}}
          [{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ len .Alerts.Firing }}{{ end }}] {{ if .CommonLabels.alertname }}{{ .CommonLabels.alertname }}{{ else }}alert{{ end }} · {{ template "ogenki.identity" . }} · {{ template "ogenki.severity" . }}
          {{- end }}

          {{- define "slack.ogenki.title" -}}
          {{ template "ogenki.emoji" . }} {{ if eq .Status "firing" }}FIRING{{ if gt (len .Alerts.Firing) 1 }} · {{ len .Alerts.Firing }}{{ end }}{{ else }}RESOLVED{{ end }} — {{ if .CommonLabels.alertname }}{{ .CommonLabels.alertname }}{{ else }}alert{{ end }}
          {{- end }}

          {{- define "slack.ogenki.title_link" -}}
          {{- $a := index .Alerts 0 -}}
          {{- if $a.Annotations.dashboard }}{{ $a.Annotations.dashboard }}{{ else }}{{ $a.GeneratorURL }}{{ end -}}
          {{- end }}

          {{/* Identity, headline, then at most five bullets. The cap is index
               based rather than `slice`, because a slice past the end panics and
               there is no `min` to clamp it with. */}}
          {{- define "slack.ogenki.text" -}}
          `{{ template "ogenki.identity" . }}`

          {{ template "ogenki.headline" . }}
          {{ range $i, $a := .Alerts }}{{ if lt $i 5 }}
           • {{ template "ogenki.bullet" $a }}{{ end }}{{ end }}
          {{- if gt (len .Alerts) 5 }}
           … showing 5 of {{ len .Alerts }}{{ end }}
          {{- end }}

          {{- define "slack.ogenki.field_namespace" -}}
          {{- if .CommonLabels.namespace }}{{ .CommonLabels.namespace }}{{ else }}—{{ end -}}
          {{- end }}

          {{/* No button is ever dead: both fall back to a page that exists. */}}
          {{- define "slack.ogenki.runbook_url" -}}
          {{- $a := index .Alerts 0 -}}
          {{- if $a.Annotations.runbook_url }}{{ $a.Annotations.runbook_url }}{{ else }}https://cnref.ogenki.io/docs/platform/observability/dashboards-and-alerts/{{ end -}}
          {{- end }}

          {{- define "slack.ogenki.dashboard_url" -}}
          {{- $a := index .Alerts 0 -}}
          {{- if $a.Annotations.dashboard }}{{ $a.Annotations.dashboard }}{{ else }}https://grafana.${private_domain_name}/dashboards{{ end -}}
          {{- end }}
```

- [ ] **Step 4: Rewrite the receiver**

Replace the whole `- name: "slack-monitoring"` receiver block with:

```yaml
          - name: "slack-monitoring"
            slack_configs:
              - channel: "#alerts"
                send_resolved: true
                icon_emoji: ":waitwhat:"
                color: '{{ template "slack.ogenki.color" . }}'
                # Unset before this change, so a phone notification showed
                # Slack's own generic preview instead of the alert.
                fallback: '{{ template "slack.ogenki.fallback" . }}'
                title: '{{ template "slack.ogenki.title" . }}'
                title_link: '{{ template "slack.ogenki.title_link" . }}'
                text: '{{ template "slack.ogenki.text" . }}'
                mrkdwn_in: ["text"]
                # `fields` is a STATIC list -- only the values are templated, so
                # a field cannot be conditionally omitted. Every value template
                # therefore falls back to an em dash rather than rendering an
                # empty box.
                fields:
                  - title: "Namespace"
                    value: '{{ template "slack.ogenki.field_namespace" . }}'
                    short: true
                  - title: "Severity"
                    value: '{{ template "ogenki.severity" . }}'
                    short: true
                  - title: "Duration"
                    value: '{{ template "ogenki.duration" . }}'
                    short: true
                  - title: "Location"
                    value: '{{ template "ogenki.location" . }}'
                    short: true
                actions:
                  - type: button
                    text: "Runbook :green_book:"
                    url: '{{ template "slack.ogenki.runbook_url" . }}'
                  - type: button
                    text: "Dashboard :grafana:"
                    url: '{{ template "slack.ogenki.dashboard_url" . }}'
                  - type: button
                    text: "Query :mag:"
                    url: "{{ (index .Alerts 0).GeneratorURL }}"
                  - type: button
                    text: "Silence :no_bell:"
                    url: '{{ template "__alert_silence_link" . }}'
                # The fifth button is gone. It pointed at
                # .CommonAnnotations.link_url, an annotation no rule in this repo
                # has ever set, so it rendered with an empty URL on every alert.
```

- [ ] **Step 5: Render and read the output before trusting it**

Run:
```bash
./scripts/validate-manifests.sh 2>&1 | tail -20
./scripts/validate-alertmanager-templates.sh --update-golden
cat scripts/alertmanager-fixtures/golden/critical-single.txt
cat scripts/alertmanager-fixtures/golden/degenerate.txt
```

Read both files properly — this is the review, and the gate cannot do it for you. Check:

1. `critical-single.txt` — `title` reads `:fire: FIRING — OpenBaoRaftQuorumAtRisk`; `text` opens with `` `aws-0 · dev` ``, then the summary, then **no bullet detail duplicating the headline**; `field:Location` is `aws / eu-west-3`; the Runbook action is the openbao.org URL and Dashboard is the Grafana one.
2. `degenerate.txt` — `field:Namespace` and `field:Location` are both `—`; `text` ends with ` … showing 5 of 7`; the headline is the first alert's description **truncated at 280 characters with an ellipsis**; the Runbook action is the `cnref.ogenki.io` fallback and Dashboard is `https://grafana.priv.cluster.local/dashboards` — the render fixture's domain, **not** a literal `${private_domain_name}`.
3. `resolved.txt` — `title` starts `:lgtm: RESOLVED`, `color` is `good`, `field:Duration` is masked to `<DURATION>`.
4. `warning-group-of-3.txt` — three bullets, each `apps/podinfo-… — N restarts in 10m`, and the shared summary printed once.

If any of those is wrong, fix the template and re-run `--update-golden`. Do not commit a golden file you have not read.

- [ ] **Step 6: Run the gate in check mode**

Run: `./scripts/validate-alertmanager-templates.sh`
Expected: PASS, exit 0, `==> 13 templated string(s) render across 5 fixture(s); all match their golden files`.

- [ ] **Step 7: Commit**

```bash
git add observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml scripts/alertmanager-fixtures/golden docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md
git commit -m "feat(observability): Slack alerts say which cluster they came from

Replaces the chart's vendored Monzo templates, which print no cluster,
environment, cloud, region, label or duration, and print description in
full -- so a rule whose description is a runbook pastes that runbook into
the channel.

The message now carries an identity line, the summary as a headline, up to
five per-target bullets with truncated detail, a Namespace/Severity/
Duration/Location grid, and a fallback string so phone notifications are
readable. The fifth button, which pointed at an annotation no rule sets,
is gone."
```

---

### Task 5: Routing and inhibition

Config-only. The goldens must not move — if they do, something in Task 4 was disturbed.

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml` (the `route` and a new `inhibit_rules` block)

**Interfaces:**
- Consumes: the `severity` label, and `cluster` from Task 1's label set.
- Produces: no new template names.

- [ ] **Step 1: Add per-severity routes**

Replace the `route:` block's `repeat_interval` and `routes:` list:

```yaml
        route:
          group_by:
            - cluster
            - alertname
            - severity
            - namespace
          group_interval: 5m
          group_wait: 30s
          # Was 3h for every severity, so a warning nagged as often as a page.
          # This is now only the default for anything that matches no route
          # below; each severity sets its own.
          repeat_interval: 12h
          receiver: "slack-monitoring"
          routes:
            - matchers:
                - alertname =~ "InfoInhibitor|Watchdog|KubeCPUOvercommit"
              receiver: "blackhole"
            # Send a copy of every non-blackholed alert to the RunLore SRE agent,
            # then continue so Slack still receives it. RunLore's own trigger policy
            # decides which alerts it actually investigates.
            - receiver: "runlore"
              continue: true
            # One channel carries every severity, so the cadence is what
            # separates a page from a nag.
            - matchers:
                - severity = "critical"
              receiver: "slack-monitoring"
              group_wait: 10s
              repeat_interval: 1h
            - matchers:
                - severity = "warning"
              receiver: "slack-monitoring"
              repeat_interval: 12h
            # info, and anything with no severity label at all.
            - receiver: "slack-monitoring"
              repeat_interval: 24h
```

- [ ] **Step 2: Add the inhibit rules**

As a new top-level key of `alertmanager.config`, after `receivers:`:

```yaml
        # There were NO inhibit rules: setting alertmanager.config replaces the
        # chart's defaults wholesale, so every implied alert posted alongside its
        # cause. An inhibited alert never reaches Slack at all -- that is the
        # accepted trade, and the reason these are narrow.
        inhibit_rules:
          # One alertname firing at two severities: keep the louder one.
          - source_matchers:
              - severity = "critical"
            target_matchers:
              - severity = "warning"
            equal: [cluster, alertname, namespace]
          # Observed 2026-09-12, one minute apart: quorum-at-risk means a peer is
          # ALREADY lost, so the warning adds nothing. Two different alertnames,
          # which is why the generic rule above cannot catch it. Add named pairs
          # as they are observed rather than generalising -- a clever generic
          # rule mutes things nobody intended.
          - source_matchers:
              - alertname = "OpenBaoRaftQuorumAtRisk"
            target_matchers:
              - alertname = "OpenBaoRaftNodeLost"
            equal: [cluster]
```

- [ ] **Step 3: Verify the config still parses and nothing rendered moved**

Run:
```bash
./scripts/validate-manifests.sh 2>&1 | tail -12
git status --short scripts/alertmanager-fixtures/golden
```
Expected: all gates pass, and `git status` shows **no modified golden files** — routing changes what is delivered, never how it is drawn.

- [ ] **Step 4: Verify Alertmanager itself accepts the config**

Run:
```bash
python3 - <<'PY'
import pathlib, yaml, subprocess, tempfile, os
for p in pathlib.Path(".bundle").rglob("*.yaml"):
    for d in yaml.safe_load_all(p.read_text()):
        if isinstance(d, dict) and d.get("kind") == "Secret" and "alertmanager.yaml" in (d.get("stringData") or {}):
            fh = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
            fh.write(d["stringData"]["alertmanager.yaml"]); fh.close()
            print(fh.name); raise SystemExit(0)
raise SystemExit("no alertmanager config Secret in .bundle")
PY
```
Take the printed path and run:
```bash
"$(mise which amtool -C . 2>/dev/null || command -v amtool)" check-config <that path>
```
Expected: `SUCCESS` and a list of found receivers/routes. This is the only step that type-checks `inhibit_rules` and the route tree; the schema gate sees the config as an opaque string inside a Secret.

If `check-config` complains about the missing `templates` glob or unreadable `credentials_file` paths, that is expected — those resolve inside the pod. Only a parse or route error is a failure here.

- [ ] **Step 5: Commit**

```bash
git add observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml
git commit -m "feat(observability): one cadence per severity, and two inhibit rules

Setting alertmanager.config replaces the chart's defaults wholesale, so
this config had no inhibit_rules at all and every implied alert posted
alongside its cause -- OpenBaoRaftQuorumAtRisk and OpenBaoRaftNodeLost
arrived a minute apart on 2026-09-12.

repeat_interval was also 3h for everything. Critical now repeats hourly
and warns within 10s; warning every 12h; info daily."
```

---

### Task 6: The ADR and the docs page

**Files:**
- Create: `website/content/docs/decisions/0037-alertmanager-native-slack-templates.md`
- Modify: `website/content/docs/platform/observability/dashboards-and-alerts.md`
- Modify: `docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md` (link the ADR now that it exists)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing consumed by code.

- [ ] **Step 1: Read the ADR template and a recent neighbour**

Run:
```bash
cat website/content/docs/decisions/template.md
head -40 website/content/docs/decisions/0036-per-app-secret-ownership-via-zitadel-groups.md
```
Match that front matter and section structure exactly — heading levels, `weight`, and any `date`/`status` fields.

- [ ] **Step 2: Write ADR-0037**

Title: *Alertmanager-native Slack templates over a Block Kit bridge*. It must say, in the repo's ADR voice:

- **Context.** Two clusters on two clouds, one `#alerts` channel, and a vendored 2018 template that names neither. Slack marks the legacy attachment format deprecated and steers new integrations to Block Kit.
- **Decision.** Keep rendering Slack's legacy attachments from Alertmanager's own templates, shipped through `alertmanager.templateFiles`.
- **Alternatives considered and rejected:**
  - **Block Kit through a bridge** (Robusta, or a small custom webhook relay). Alertmanager has no Block Kit support — <https://github.com/prometheus/alertmanager/issues/2217>, open since March 2020. A bridge puts a component in the notification data path whose failure mode is silent, and this platform already runs RunLore with its own Slack app posting to the same channel; adding a second Slack-rendering service for formatting alone buys layout and costs an integration to operate.
  - **Grafana Alerting** instead of Alertmanager. Would move alert routing out of the VictoriaMetrics stack that owns the rules; out of proportion to a formatting problem.
- **Consequences.** Layout is bounded by what legacy attachments can express — no accordions, no interactive elements beyond link buttons, at most five actions. If Slack ever removes attachments, or Alertmanager gains Block Kit, this is the record to revisit. Accepted because the message's information content, not its chrome, was the actual problem.

- [ ] **Step 3: Document the contract**

In `website/content/docs/platform/observability/dashboards-and-alerts.md`, add a section covering:

- The annotation contract, exactly as `scripts/validate-vmrules.sh` enforces it: `summary` required, one line, ≤140 chars; `description` optional and unbounded (Slack truncates at 180 chars per bullet and 280 for a headline, RunLore reads all of it); `runbook_url` and `dashboard` optional, both with working fallbacks.
- A rendered example — paste the `title`/`text`/fields blocks from `scripts/alertmanager-fixtures/golden/critical-single.txt` so the page shows the real output rather than a description of it.
- The identity labels (`cluster`, `env`, `cloud`, `region`) and where they come from (`vmalert.spec.externalLabels`, fed by each cluster's `flux_cluster_vars`).
- The severity cadences (1h / 12h / 24h) and the two inhibit rules, with a sentence on how to add a named pair.
- How to change the wording: edit `templateFiles.ogenki.tmpl`, run `./scripts/validate-alertmanager-templates.sh --update-golden`, read the diff, commit it.

- [ ] **Step 4: Link the ADR from the spec**

The spec currently names the ADR as a path because linking a non-existent file fails `validate-links.sh`. Now that it exists, make both mentions relative links:

```bash
sed -i 's|`website/content/docs/decisions/0037-alertmanager-native-slack-templates.md` (not yet written)|[ADR-0037](../../../website/content/docs/decisions/0037-alertmanager-native-slack-templates.md)|; s|Recorded in ADR-0037\.|Recorded in [ADR-0037](../../../website/content/docs/decisions/0037-alertmanager-native-slack-templates.md).|' docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md
```

- [ ] **Step 5: Verify the docs gates**

Run:
```bash
./scripts/validate-links.sh && ./scripts/validate-doc-claims.sh
```
Expected: exit 0 from both.

If `validate-doc-claims.sh` has a claim covering this page, update `.doc-claims.yaml` rather than loosening the page.

- [ ] **Step 6: Commit**

```bash
git add website docs/superpowers/specs/2026-09-12-slack-alert-notifications-design.md
git commit -m "docs(observability): record the Slack template decision and contract

ADR-0037 records choosing Alertmanager's own templates over a Block Kit
bridge, which Alertmanager cannot do natively (#2217, open since 2020) and
which would duplicate RunLore's Slack path for layout alone.

The observability page gains the annotation contract the new
validate-vmrules.sh check enforces, a real rendered example taken from the
golden files, and how to change the wording safely."
```

---

## Final verification

Run all of it fresh, in one go, and cite the output:

```bash
./scripts/validate-manifests.sh          # includes gates 1-3 and the two source checks
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
tofu fmt -check -recursive opentofu/
```

Expected: exit 0 from each, and the manifest report showing `Invalid: 0, Skipped: 0`.

## Deployment order — this matters

`${cloud}` does not exist on either cluster until its `configure` stack is applied. Merging the manifests first renders `cloud: ""`, which the templates survive (Location falls back to the region, then to an em dash) but which is still wrong.

1. Apply both clusters: `cd opentofu/aws/eks/configure && terramate script run deploy`, then the same under `opentofu/gcp/gke/configure`. For a feature-branch test, `TF_VAR_flux_git_ref=refs/heads/<branch>`.
2. Confirm the key landed: `kubectl get cm eks-aws-0-vars -n flux-system -o jsonpath='{.data.cloud}'` → `aws`, and `gke-gcp-0-vars` → `gcp`.
3. Then merge.

State this in the PR body.

## Post-merge verification

Cluster-observable, so it cannot be claimed before the deploy:

1. `flux get kustomizations observability` → `Ready=True`.
2. `kubectl get secret victoria-metrics-k8s-stack-alertmanager -n observability -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -40` → the new receiver, with `${private_domain_name}` substituted.
3. Fire a real message:
   ```bash
   amtool --alertmanager.url=https://vmalertmanager-aws-0.priv.aws.ogenki.io alert add \
     SlackTemplateSmokeTest severity=critical cluster=aws-0 env=dev cloud=aws \
     region=eu-west-3 namespace=observability \
     --annotation=summary="Verifying the new Slack template renders on the cluster." \
     --annotation=description="Synthetic alert, safe to ignore. Resolves on its own." \
     --end="$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
   ```
   Check the channel: identity line, four fields, four live buttons, and a readable phone notification.
4. `sum(increase(alertmanager_notifications_failed_total{integration="slack"}[15m]))` → 0. A non-zero value here is the signature of a template Alertmanager accepted but Slack rejected, which is the one class of bug the fixture gate cannot see.

Reaching the cluster currently needs the `vm.priv.aws.ogenki.io` / private-endpoint DNS workaround; the MCP path fails to resolve.
