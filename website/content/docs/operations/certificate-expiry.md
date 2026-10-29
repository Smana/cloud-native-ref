---
title: Certificate expiry
weight: 20
description: Which cert-manager certificates are expiring or not Ready — a read-only report script, the Certificates Grafana dashboard, and the two alerts that watch the same metrics.
lastVerified: 2026-10-29
---

Everything TLS on the cluster — the ingresses, the OpenBao listeners, the
identity providers — is issued by cert-manager, and a certificate that fails
to renew is silent right up to the outage. Nothing red anywhere: the pods
mounting the Secret keep running until expiry day, and then they do not.

This page covers the three views of that signal: a one-shot report you run
from a laptop, the standing **Certificates** Grafana dashboard, and the two
alerts that fire without anyone watching. All three read the same two
metrics, so they cannot disagree.

## The report: `scripts/ops/k8s/cert-expiry.sh`

`scripts/ops/k8s/cert-expiry.sh` prints one line per Certificate expiring
within a window, soonest first:

```console
$ scripts/ops/k8s/cert-expiry.sh
security/gateway-tls 2026-11-04T09:12:00Z 6
observability/vmalert-tls 2026-11-18T21:40:00Z 20
```

The line is `<namespace>/<name> <notAfter> <days left>`, where days left is
the whole days between now and `spec.notAfter` — negative when the
certificate has already expired, because an expired certificate is inside
every window and is the most urgent thing on the list. A Certificate with no
`spec.notAfter` yet — just created, still issuing — has no expiry to report
and is skipped.

The window is 30 days by default; `--days N` widens or narrows it:

```console
$ scripts/ops/k8s/cert-expiry.sh --days 90
```

It is **a report, not a gate**:

- it exits `0` whatever the count, so it never breaks whatever runs it;
- it reads only (`kubectl get`), changes nothing;
- if the cluster is unreachable or cert-manager is not installed it still
  exits `0`, with a warning on stderr.

`scripts/ci/tests/test-cert-expiry.sh` runs the script against a canned
`kubectl get certificates -A -o json` fixture, covering the expired,
in-window, out-of-window and no-`notAfter` cases, both windows, the
unreachable-cluster path and the empty cluster.

## The dashboard: Certificates

The **Certificates** dashboard
(`observability/base/grafana-operator/dashboards/certificates.yaml`, in the
`kubernetes` folder) is the standing view of the same signal:

- **Certificates by days until expiry** — a table, one row per certificate,
  soonest first, computed from
  `certmanager_certificate_expiration_timestamp_seconds` with the same
  arithmetic the script prints, so the two agree on the number.
- **Certificates not Ready** — a stat counting
  `certmanager_certificate_ready_status{condition="True"} == 0`.
- **Expiring in under 14 days** — a stat counting the certificates behind
  the `CertificateExpiringSoon` alert's threshold.

The table names what the alerts summarize: when the stat steps up, the table
row at the top of it is the certificate to look at.

## The alerts

Two VMRules in
`observability/base/victoria-metrics-k8s-stack/vmrules/cert-manager.yaml`
watch the same metrics and fire without anyone looking:

- **CertificateNotReady** — a certificate that has not been Ready for 15
  minutes:

  ```promql
  certmanager_certificate_ready_status{condition="True"} == 0
  ```

  `condition="True" == 0` rather than `condition="False" == 1`: it also
  catches a certificate stuck in `Unknown` — issuance in progress and never
  completing — which is exactly the failed-ACME-order case. Anything
  mounting its Secret is stuck in `ContainerCreating`, and neither Flux nor
  the pod will say why: the reason is on the Order.

- **CertificateExpiringSoon** — a certificate that expires in under 14 days
  for a full hour, which means renewal is failing, not that it is merely
  due (cert-manager renews at two thirds of the lifetime):

  ```promql
  (certmanager_certificate_expiration_timestamp_seconds - time()) < (14 * 24 * 3600)
  ```

## How they relate

The three views answer three different questions at three different
horizons:

- The **alerts** act when nobody is watching: `CertificateNotReady` catches
  a failed issuance within 15 minutes, `CertificateExpiringSoon` catches a
  failing renewal at 14 days out.
- The **dashboard** is what you open when an alert fires: it names the
  certificate and shows whether the problem is renewal, readiness, or both.
- The **script** is the point-in-time audit from outside Grafana — the same
  table, on a laptop, over any window you choose, including certificates
  beyond the alerts' 14-day threshold.

Renewal failing (the alert fired, the script shows a short days-left, the
not-Ready stat is green) and issuance failing (not-Ready, days-left missing
because there is no `notAfter` yet) have different causes and different
fixes; see the annotations on the rules for the diagnosis commands.

## Reading on

- [Flux health]({{< relref "/docs/operations/flux-health.md" >}}) — the
  other one-shot report and its standing view
- [Observability]({{< relref "/docs/platform/observability/_index.md" >}})
  — where the dashboards live and how they reach the cluster
- [Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}) — the
  failures specific to this platform
