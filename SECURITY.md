# Security Policy

## Reporting Security Issues

If you find a security vulnerability in this repository, please report it by:

1. Opening a [GitHub Security Advisory](https://github.com/Smana/cloud-native-ref/security/advisories/new)
2. Or emailing the maintainer directly

Please do not create public issues for security vulnerabilities.

## What this repository is

A **reference implementation** of a cloud-native platform. Everything in it
runs — it is not a slideware repo — but it is built to be read and forked, not
to be adopted unexamined. The posture below is what it actually enforces, and
the limitations further down are the ones it genuinely has rather than the
generic caveats a template would list.

## Enforced posture

| Property | How | Where |
|---|---|---|
| No static cloud credentials | EKS Pod Identity, never IRSA, never long-lived keys | [ADR-0002](website/content/docs/decisions/0002-eks-pod-identity-over-irsa.md), `security/base/epis/` |
| IAM scoped to `xplane-*` | Crossplane provider policies restricted by resource prefix | [Platform constitution](docs/platform-constitution.md) |
| No delete permission on stateful services | S3, IAM and Route 53 grants exclude deletion | [Platform constitution](docs/platform-constitution.md) |
| Default-deny pod networking | A `CiliumNetworkPolicy` per pod-running workload, both directions | `security/base/*/network-policy.yaml` |
| Private cluster API | The EKS endpoint is private; reachable only over Tailscale | [ADR-0013](website/content/docs/decisions/0013-tailscale-over-bastion.md), `opentofu/aws/eks/init/` |
| Admin services unreachable, not merely unlisted | Two Tailscale gateways split by ACL tag (`tag:k8s`, `tag:admin`) | `infrastructure/base/gapi/` |
| TLS on internal traffic | A private PKI issues every certificate through cert-manager | [ADR-0011](website/content/docs/decisions/0011-openbao-over-vault.md), `security/base/cert-manager/` |
| No secrets in Git | External Secrets Operator pulls from AWS Secrets Manager and OpenBao at runtime | `security/base/external-secrets/` |
| Restricted pod security context | Kyverno at admission, Polaris on the rendered bundle before merge | [ADR-0016](website/content/docs/decisions/0016-kyverno-over-gatekeeper.md), `scripts/validate-manifests.sh` |

## Supply chain

Narrower than the phrase usually implies, so it is worth being exact about
which of these block a merge and which only report:

| Tool | Scope | Blocks a merge? |
|---|---|---|
| `flux schema validate` | Every rendered manifest, with `skipMissingSchemas: false` — an unknown Kind fails the build rather than being skipped | **Yes** |
| Polaris | The rendered bundle (~69 controllers), not the source tree | **Yes** |
| Trivy | Filesystem scan of the repository, `CRITICAL,HIGH`, `ignore-unfixed` | Reports to GitHub Security |
| Checkov | `terraform,secrets` frameworks, `soft_fail: true` | No — advisory only |
| TruffleHog | CI, `--only-verified` | Reports |
| `detect-secrets` | pre-commit, before the push | **Yes**, locally |

**No container image is scanned anywhere in CI.** Trivy runs `scan-type: fs`
against the repository, not against images. Harbor carries no explicit Trivy
configuration, so whatever its chart defaults to is what you get.

## Known limitations

These are real and specific to this repository. They are documented rather than
hidden because a reader evaluating the platform needs to know which properties
are enforced and which are accepted exceptions.

- **The root CA private key is present in the live OpenBao mount.** The
  intermediate is signed inside OpenBao so the deploy stays unattended.
  Accepted for a reference platform; explicitly not to be carried into a
  deployment where the root CA matters.
- **CiliumNetworkPolicy coverage is uneven.** The constitution requires one on
  every pod-running workload; the observability stack does not yet meet that
  bar.
- **Some enforcement is inherited, not chosen.** `kyverno-policies` installs
  with `values: {}`, so which Pod Security Standard policies run — and whether
  they audit or enforce — comes from the upstream chart's defaults rather than
  a decision recorded here.
- **The demo cluster is single-tenant and single-operator.** RBAC binds one
  `admin` OIDC group to `cluster-admin`. A multi-tenant deployment needs a
  finer split than this repository demonstrates.

## Before running any of this yourself

- Review IAM permissions against your own account's blast radius.
- Enable CloudTrail and audit logging; this repository configures neither for you.
- Generate your own PKI material — do not reuse anything committed here.
- Decide your own secret rotation policy; External Secrets syncs, it does not rotate.

## How the platform implements this

The security model is documented in full at
[cnref.ogenki.io](https://cnref.ogenki.io):
[Zero trust](https://cnref.ogenki.io/docs/concepts/zero-trust/) for the model,
and [Security](https://cnref.ogenki.io/docs/platform/security/) for the PKI
chain, the secret flow and the policies enforced on a running workload.

## Supported Versions

Only the tip of `main` is maintained. Renovate tracks upstream releases and CI
renders the whole repository against each one before it can merge.
