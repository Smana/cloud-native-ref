# Cloud Native Platform Reference

**_An opinionated, production-ready Kubernetes platform using GitOps principles._**

A reference implementation of a complete cloud-native platform on AWS EKS and GCP GKE: infrastructure as
code with OpenTofu and Crossplane, continuous delivery with Flux, a private PKI and zero-trust
networking, a full observability stack, and a developer-facing abstraction that turns one small
YAML claim into a whole application.

📖 **Full documentation: [cnref.ogenki.io](https://cnref.ogenki.io)**

## Architecture

![Platform Architecture](docs/architecture/img/platform-overview.png)

> Editable source: [`docs/architecture/platform-overview.drawio`](docs/architecture/platform-overview.drawio)

Three bands: the **cloud's managed services** on the left, with their AWS and GCP equivalents
side by side (Route 53 / Cloud DNS, ELB / Cloud Load Balancing, IAM via EKS Pod Identity / GKE
Workload Identity, S3 / Cloud Storage, KMS / Cloud KMS), the **Kubernetes cluster** in the centre
in four tiers (GitOps & composition, compute & networking, security & identity, observability),
and **applications & data** on the right. Flux reconciles the repository; Tailscale provides
private access; OpenBao holds the secrets and the PKI. The AI platform — self-hosted LLMs, the AI
gateway and the Agent Factory — lives in [Smana/ai-native-ref](https://github.com/Smana/ai-native-ref)
([airef.ogenki.io](https://airef.ogenki.io/)); this repository hosts it as opt-in umbrellas pinned
to its signed artifact.

Every subsystem is explained at
[cnref.ogenki.io/docs/platform](https://cnref.ogenki.io/docs/platform/).

## Quickstart

Roughly 45 minutes end to end, and almost all of it unattended: about 30 minutes of
infrastructure, then Flux converging the platform while you do something else. The
committed configuration is **AWS-primary** (`primary_cloud = "aws"`): `aws-0` is the live
cluster and `gcp-0` is torn down. You need a GCP project, an AWS account holding the public
Route53 zone, a Tailscale account, and a GitHub App or token for Flux. Full prerequisites,
the AWS lane and the annotated walkthrough are in
[Get Started](https://cnref.ogenki.io/docs/get-started/).

```bash
# 1. Point the platform at your environment
$EDITOR opentofu/config.tm.hcl        # region, chart versions, primary_cloud

# 2. Provide the one secret that is not in a cloud secret store
export TF_VAR_tailscale_api_key=<your-tailscale-api-key>

# 3. Network, then OpenBao, then GKE with Cilium and Flux (~30 min)
cd opentofu && TM_CLOUD=gcp terramate script run deploy

# 4. Get a kubeconfig (the control plane is private: the tailnet must be up)
gcloud container clusters get-credentials gcp-0 --zone europe-west4-a --project <your-project>

# 5. Watch Flux build the rest of the platform
flux get all
```

Flux takes over from there: security (External Secrets, cert-manager, Kyverno), infrastructure
(Cilium, Gateway API, ExternalDNS, ComputeClasses), observability (VictoriaMetrics, VictoriaLogs,
Grafana) and tooling (Harbor, Headlamp, Homepage).

## Documentation

Full documentation — deploy guides, platform internals, concepts, and the
architecture decision records — is published at **[cnref.ogenki.io](https://cnref.ogenki.io)**.

- [Get Started](https://cnref.ogenki.io/docs/get-started/) — deploy the platform in about 45 minutes, mostly unattended
- [Platform](https://cnref.ogenki.io/docs/platform/) — every domain, what runs and why
- [Concepts](https://cnref.ogenki.io/docs/concepts/) — the ideas the platform is built on
- [Guides](https://cnref.ogenki.io/docs/guides/) — fork and adapt, add an application, troubleshoot
- [Reference](https://cnref.ogenki.io/docs/reference/) — technology stack, commands, repository layout
- [Decisions](https://cnref.ogenki.io/docs/decisions/) — what was chosen, and what over

The blog posts that explain several of these components in long form are collected under
[Further reading](https://cnref.ogenki.io/docs/reference/further-reading/).

## Repository Structure

```
.
├── opentofu/                      # 🔧 Infrastructure as Code
│   ├── aws/                       # AWS stacks
│   │   ├── network/               # VPC, Tailscale VPN
│   │   ├── openbao/               # Secrets management and PKI
│   │   ├── eks/                   # Kubernetes cluster (two-stage)
│   │   │   ├── init/              # Stage 1: EKS + bootstrap addons
│   │   │   └── configure/         # Stage 2: Cilium + Flux
│   │   └── llm-platform/          # Opt-in: S3 Files + IAM for the LLM platform
│   ├── gcp/                       # GCP stacks
│   │   ├── network/               # VPC, Tailscale VPN
│   │   ├── openbao/               # Secrets management and PKI
│   │   └── gke/                   # Kubernetes cluster (two-stage)
│   │       ├── init/              # Stage 1: GKE cluster
│   │       └── configure/         # Stage 2: Cilium + Flux
│   └── shared/                    # Owned by neither cloud (Tailscale tailnet, AWS↔GCP federation)
├── flux/                          # 🚀 Flux operator and configuration
├── clusters/                      # Per-cluster Kustomizations (aws-0, gcp-0) and the AI umbrellas
├── infrastructure/                # 🏗️ Platform infrastructure
├── security/                      # 🔒 Security components
├── observability/                 # 👁️ Monitoring and logging
├── tooling/                       # 🛠️ Platform tools
├── apps/                          # 📦 Applications, as App claims
├── crds/                          # Custom Resource Definitions
├── website/                       # 📚 The documentation site (Hugo + Hextra)
├── docs/                          # Architecture diagrams, specs, design artifacts
└── scripts/                       # Automation and validation
```

## AI-Assisted Development

This repository leverages a coding agent for code generation, troubleshooting, and documentation.
Its instructions are **agent-agnostic**: [AGENTS.md](AGENTS.md) carries the repo-wide context, each
directory that needs its own rules carries a nested `AGENTS.md` loaded only when work touches it,
and repeatable procedures live in [`.agents/skills/`](.agents/skills/) as
[Agent Skills](https://agentskills.io). `CLAUDE.md` and `.claude/skills` are symlinks, so Claude
Code, Codex, Cursor, Gemini CLI and Antigravity all read one copy.

Non-trivial changes go through the [Superpowers](https://github.com/obra/superpowers) workflow —
a design document is brainstormed and approved, turned into an implementation plan, then
executed task by task, with every artifact committed under
[docs/superpowers/](docs/superpowers/). A [platform constitution](docs/platform-constitution.md)
states the non-negotiable rules every design is checked against. The agent also integrates with
observability tools via MCP servers (VictoriaMetrics, VictoriaLogs, Flux) for real-time
debugging directly from the development environment.

## Contributing and Community

We welcome contributions, feedback, and questions!

- 🗨️ **[Slack Channel](https://ogenki.slack.com/)**: Chat with the community
- 💬 **[Discussions](https://github.com/Smana/cloud-native-ref/discussions)**: Ideas, questions, roadmap
- 🐛 **[Issues](https://github.com/Smana/cloud-native-ref/issues)**: Bug reports and feature requests
- 📅 **[Project Board](https://github.com/users/Smana/projects/1)**: Task tracking and priorities

**Before contributing**: Review [SECURITY.md](SECURITY.md) for security policy and
[AGENTS.md](AGENTS.md) for development guidelines.

## Support this work

One person maintains cloud-native-ref and pays for the AWS and GCP clusters its live tests need;
[sponsoring it](https://github.com/sponsors/Smana) helps cover that.

## License

This project is provided as a reference implementation. Please review individual component licenses.

## Acknowledgments

This platform builds on the excellent work of many open-source projects:

- [Crossplane](https://www.crossplane.io/) team and community
- [Flux](https://fluxcd.io/) maintainers and CNCF
- [Cilium](https://cilium.io/) and eBPF ecosystem
- [VictoriaMetrics](https://victoriametrics.com/) developers
- [OpenBao](https://openbao.org/) and Linux Foundation
- All the maintainers of the tools in this stack

---

**Ready to get started?** → [cnref.ogenki.io/docs/get-started](https://cnref.ogenki.io/docs/get-started/)

**Questions?** → [Join our Slack](https://ogenki.slack.com/)
