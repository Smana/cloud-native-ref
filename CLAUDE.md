# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a comprehensive cloud-native platform reference repository implementing GitOps practices with Kubernetes. The repository demonstrates production-ready configurations for building, managing, and maintaining a secure, scalable cloud-native platform using AWS EKS.

## Infrastructure Architecture

The platform is deployed in three sequential stages:

1. **Network Layer** (`opentofu/network/`): VPC, subnets, Route53, and Tailscale VPN
2. **Security Layer** (`opentofu/openbao/`): OpenBao cluster for secrets management and PKI
3. **Kubernetes Layer** (`opentofu/eks/init/` + `opentofu/eks/configure/`): EKS cluster with Flux, Cilium, and Karpenter

### Key Components

- **OpenTofu**: Infrastructure as Code (Terraform alternative)
- **Terramate**: OpenTofu orchestration and stack management
- **Flux**: GitOps continuous delivery
- **Crossplane**: Infrastructure composition from Kubernetes
- **OpenBao**: Secrets management and private PKI
- **Cilium**: Advanced networking and security with eBPF
- **Gateway API**: Modern ingress and traffic routing
- **VictoriaMetrics**: High-performance observability stack

### EKS Bootstrap Architecture

Two-stage OpenTofu deployment: Stage 1 creates the EKS cluster with temporary CNI, Stage 2 replaces it with Cilium and installs Flux.

**Why two stages?** Helm provider needs cluster endpoint at plan time, so Stage 2 runs after the cluster exists.

**Deploy**: `cd opentofu/eks/init && terramate script run deploy`

**Key Files:**
- `opentofu/config.tm.hcl` - Cilium/Flux versions
- `opentofu/eks/init/main.tf` - EKS module with bootstrap addons
- `opentofu/eks/configure/main.tf` - Cilium and Flux helm_releases
- `opentofu/eks/init/helm_values/cilium.yaml` - Cilium Helm values

**Cilium Prefix Delegation (DISABLED):**
Secondary CIDR (100.64.0.0/16) is disabled due to Cilium bug #43493 causing Gateway API L7 proxy failures on cross-node traffic. When fixed, uncomment `cilium-cni-config.tf` and related settings in `cilium.yaml`.

**Pod Subnet Tagging (IMPORTANT):**
The pod subnets (100.64.x.x) must NOT have the `kubernetes.io/role/cni` tag. VPC-CNI uses this tag to discover subnets during Stage 1 bootstrap, which creates orphan ENIs when Cilium takes over in Stage 2. Only use `cilium.io/pod-subnet=true` for these subnets.

**IAM:** EBS CSI and Crossplane use EKS Pod Identity (`xplane-*` resource scope for Crossplane).

## Common Commands

### Terramate / OpenTofu

```bash
terramate script run init       # Initialize all stacks
terramate script run preview    # Preview changes
terramate script run deploy     # Deploy platform
terramate script run drift detect  # Check drift

# EKS deploy (both stages)
cd opentofu/eks/init && terramate script run deploy

# Feature branch testing
TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy

# Individual stack
cd opentofu/<stack> && tofu plan -var-file=variables.tfvars
```

### EKS Cluster

```bash
aws eks update-kubeconfig --region eu-west-3 --name mycluster-0
flux get all
flux suspend kustomization --all
flux resume kustomization --all
```

### OpenBao

```bash
export VAULT_ADDR=https://bao.priv.cloud.ogenki.io:8200
export VAULT_SKIP_VERIFY=true
bao status
bao auth -method=userpass username=admin
```

## Development Workflow

### Prerequisites

- [mise](https://mise.jdx.dev/) - Polyglot tool version manager (manages OpenTofu, Terramate, Trivy, pre-commit)
- AWS CLI configured with appropriate permissions
- Helm CLI (v3.12+), kubectl, bao CLI, jq
- Tailscale account and API key

**Tool versions managed via `mise.toml`**. Run `mise install` to install all required tools.

### Configuration Files

- `mise.toml`: Tool versions
- `opentofu/config.tm.hcl`: Global Terramate config (Cilium/Flux versions)
- `opentofu/workflows.tm.hcl`: Terramate scripts and workflows
- `opentofu/eks/init/workflows.tm.hcl`: EKS two-stage deployment scripts

### GitOps with Flux

Flux manages all Kubernetes resources through a dependency hierarchy:

1. **Namespaces** -> **CRDs** -> **Crossplane** -> **EKS Pod Identities**
2. **Security** (External Secrets, Cert-Manager, Kyverno)
3. **Infrastructure** (Cilium, DNS, Load Balancers)
4. **Observability** (VictoriaMetrics, Grafana)
5. **Applications** (Harbor, Headlamp, etc.)

### Crossplane Resources

- **Compositions**: Infrastructure templates in `infrastructure/base/crossplane/configuration/`
- **App Composition**: Platform abstraction supporting progressive complexity (image-only to production-ready with managed PostgreSQL, Redis/Valkey, S3, autoscaling, HA, zero-trust networking)
- **EPI (EKS Pod Identity)**: IAM roles for service accounts in `security/base/epis/`
- **Resource naming**: All Crossplane-managed resources prefixed with `xplane-`

> **KCL and Crossplane validation rules** are in `.claude/rules/kcl-crossplane.md` and `.claude/rules/crossplane-validation.md` (loaded automatically when editing those files).

## Spec-Driven Development (SDD)

This repository uses SDD for non-trivial changes. See [docs/specs/README.md](docs/specs/README.md) for complete documentation.

```
/spec -> /spec-status -> /clarify -> /validate -> Implement -> /create-pr -> Auto-archive
```

**Key Documents**:
- [Platform Constitution](docs/specs/constitution.md) - Non-negotiable principles
- [Architecture Decision Records](docs/decisions/) - Cross-cutting technology choices

### When Specs Are Required

| Change Type | Examples |
|-------------|----------|
| New Crossplane Composition | New KCL module, new XRD |
| Major Infrastructure | New OpenTofu stack, VPC changes, EKS upgrades |
| Security Changes | Network policies, RBAC, PKI, secrets |
| Platform Capabilities | Multi-component features, observability |

### When to Skip Specs

Version bumps, documentation-only, single-file bug fixes, minor config changes, HelmRelease value tweaks.

### SDD Skills

| Skill | Description |
|-------|-------------|
| `/spec [type] "description"` | Creates GitHub issue + spec directory |
| `/spec-status` | Pipeline overview (Draft/Implementing/Done counts) |
| `/clarify [spec-file]` | Resolves `[NEEDS CLARIFICATION]` markers |
| `/validate [spec-file]` | Validates spec completeness |

## Security Considerations

### OpenBao PKI Structure

- Root CA -> Intermediate CA -> Leaf certificates
- AppRole authentication for cert-manager
- Automatic certificate rotation

### IAM and Permissions

- Least privilege principle enforced
- EKS Pod Identity for service account authentication
- Crossplane controllers limited to `xplane-*` prefixed resources
- No deletion permissions for stateful services (S3, IAM, Route53)

### Network Security

- Private EKS API endpoint
- Tailscale VPN for secure access to private resources
- Cilium Network Policies for pod-to-pod communication
- Gateway API for ingress with TLS termination

### Tailscale Gateway API Integration

Private services exposed via Tailscale using Gateway API with custom domains (`*.priv.cloud.ogenki.io`). Two separate Gateways enforce ACL-based access control:

- **General Gateway** (`tag:k8s`): All Tailscale members. Services: Harbor, Headlamp, Homepage, Grafana, VictoriaMetrics.
- **Admin Gateway** (`tag:admin`): `group:admin` only. Services: Hubble UI, VictoriaLogs, Grafana OnCall.

Both use `loadBalancerClass: tailscale` via CiliumGatewayClassConfig. ExternalDNS watches HTTPRoutes to create Route53 records. See `docs/tailscale-gateway-api.md` for setup details.

## Key File Locations

### Infrastructure
- OpenTofu stacks: `opentofu/{network,eks/init,eks/configure,openbao}`
- Kubernetes manifests: `{infrastructure,security,observability,tooling}/base/`
- Cluster-specific overrides: `{infrastructure,security,observability,tooling}/mycluster-0/`

### GitOps
- Flux configuration: `flux/`
- Custom Resource Definitions: `crds/base/`
- Cluster bootstrap: `clusters/mycluster-0/`

### Scripts
- EKS cleanup: `scripts/eks-prepare-destroy.sh`
- OpenBao config: `scripts/openbao-config.sh`
- KCL validation: `scripts/validate-kcl-compositions.sh`

## Troubleshooting

Use `.claude/config` for systematic Flux and Crossplane troubleshooting procedures. Use `.claude/agents/flux-troubleshooter` for automated Flux diagnosis.

### Common Issues
- **EKS Access**: Ensure proper IAM permissions and kubeconfig
- **Flux Sync**: Verify GitHub App credentials in AWS Secrets Manager
- **Certificates**: Check OpenBao CA chain and cert-manager logs
- **Network**: Confirm Tailscale subnet router connectivity
- **Resource Conflicts**: Review Crossplane composition functions and resource references

> **VictoriaLogs and Grafana rules** are in `.claude/rules/observability.md` (loaded automatically when editing observability files).

## Validation Commands

```bash
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
kubeconform -summary -output json <manifest>.yaml
kubectl get nodes && kubectl get pods --all-namespaces
flux get all
```

- always check the network policies when there are timeouts
