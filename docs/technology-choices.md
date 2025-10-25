# Technology Choices

This document explains the technologies used in this cloud-native platform and the rationale behind each choice.

## Philosophy

This platform is built on these core principles:

- **Cloud-Native First**: Kubernetes-native solutions that leverage the platform's strengths
- **Open Source**: Community-driven tools to avoid vendor lock-in
- **GitOps-Driven**: Infrastructure and applications managed through Git
- **Security by Design**: Zero-trust networking, private PKI, secrets management
- **Progressive Complexity**: Start simple, grow sophisticated without platform migrations
- **Cost Efficiency**: Leverage SPOT instances, efficient monitoring, right-sized resources

## Technology Stack

![Architecture Overview](../.assets/cloud-native-ref.png)

| Technology                                                                                                           | Domain                 | What it is used for?                                                                                      |
|----------------------------------------------------------------------------------------------------------------------|------------------------|----------------------------------------------------------------------------------------------------------|
| ![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)    | Infrastructure         | Container orchestration, core platform on which applications are deployed                                |
| ![Crossplane](https://img.shields.io/badge/Crossplane-4D4D4D?style=for-the-badge&logo=crossplane&logoColor=white)    | Infrastructure         | Framework to compose application and infrastructure components, providing proper abstraction levels      |
| ![OpenTofu](https://img.shields.io/badge/OpenTofu-24B8EB?style=for-the-badge&logo=open-tofu&logoColor=white)         | Infrastructure         | Open-source alternative to Terraform for provisioning and managing infrastructure                        |
| ![Terramate](https://img.shields.io/badge/Terramate-4B7782?style=for-the-badge&logo=key&logoColor=white)             | Infrastructure         | Tool for managing and organizing OpenTofu code and configurations across multiple stacks      |
| ![Harbor](https://img.shields.io/badge/Harbor-60B932?style=for-the-badge&logo=harbor&logoColor=white)                | Application            | Secure container image registry with scanning and signing capabilities                                   |
| ![Headlamp](https://img.shields.io/badge/Headlamp-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)        | Application            | Web-based GUI for Kubernetes cluster management                                                          |
| ![CloudNativePG](https://img.shields.io/badge/CloudNativePG-316192?style=for-the-badge&logo=postgresql&logoColor=white) | Data                   | Kubernetes operator managing PostgreSQL clusters with high availability and failover support             |
| ![Atlas operator](https://img.shields.io/badge/Atlas-5a664c?style=for-the-badge&logo=postgresql&logoColor=white) | Data                   | Kubernetes operator managing databases schema migrations             |
| ![Valkey](https://img.shields.io/badge/Valkey-4B0082?style=for-the-badge&logo=key&logoColor=white)                   | Data                   | Redis-like key-value data store                                                                          |
| ![Dagger](https://img.shields.io/badge/Dagger-FF6666?style=for-the-badge&logo=dagger&logoColor=white)                | Continuous Integration    | CI/CD tool used to define and run pipelines as code                                                      |
| ![Flux](https://img.shields.io/badge/Flux-006AFC?style=for-the-badge&logo=flux&logoColor=white)                      | Continuous Delivery    | GitOps engine ensuring that what is defined in the GitHub repository is deployed on Kubernetes           |
| ![VictoriaMetrics](https://img.shields.io/badge/VictoriaMetrics-2A4666?style=for-the-badge&logo=prometheus&logoColor=white) | Observability          | High-performance monitoring solution for collecting and querying metrics                                 |
| ![VictoriaLogs](https://img.shields.io/badge/VictoriaLogs-2A4666?style=for-the-badge&logo=victorialogs&logoColor=white) | Observability          | High-performance log management and analytics solution for collecting, storing and querying logs        |
| ![Tailscale](https://img.shields.io/badge/Tailscale-006AFC?style=for-the-badge&logo=tailscale&logoColor=white)        | Networking             | VPN solution for secure connections between Kubernetes clusters and other resources                      |
| ![Gateway API](https://img.shields.io/badge/Gateway--API-0088CE?style=for-the-badge&logo=kubernetes&logoColor=white) | Networking             | Defines standard APIs for configuring Kubernetes ingress and traffic routing                             |
| ![Cilium](https://img.shields.io/badge/Cilium-4A90E2?style=for-the-badge&logo=cilium&logoColor=white)                | Networking             | Advanced networking, security, and observability for Kubernetes using eBPF                              |
| ![External DNS](https://img.shields.io/badge/External--DNS-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white) | Networking             | Synchronizes Kubernetes resources with DNS providers like Route 53, Cloudflare, and others               |
| ![OpenBao](https://img.shields.io/badge/OpenBao-232F3E?style=for-the-badge&logo=openbao&logoColor=white)             | Security               | Open-source fork of Vault for secure secret storage, encryption, and access management                   |
| ![Cert-manager](https://img.shields.io/badge/Cert--manager-326CE5?style=for-the-badge&logo=cert-manager&logoColor=white) | Security               | Automates the creation and renewal of TLS certificates                                                   |
| ![ZITADEL](https://img.shields.io/badge/ZITADEL-002B5C?style=for-the-badge&logo=zitadel&logoColor=white)             | Security               | Cloud-native identity and access management system                                                       |
| ![ExternalSecrets Operator](https://img.shields.io/badge/ExternalSecrets_Operator-FF6C37?style=for-the-badge&logo=external-secrets&logoColor=white) | Security               | Synchronizes secrets from external secret managers (e.g., Vault, AWS Secrets Manager) into Kubernetes    |
| ![Managed Services](https://img.shields.io/badge/Managed_Services-FF9900?style=for-the-badge&logo=amazon&logoColor=white)            | Managed Services       | Cloud Services such as DNS (Route53), IAM, Load Balancing, KMS (Encrypt sensitive data) and Storage (S3)                                            |

## Key Technology Decisions

### OpenBao over HashiCorp Vault

**Decision**: Use OpenBao (open-source Vault fork) for secrets management and PKI.

**Rationale**:
- **Community-driven**: After HashiCorp's license change, OpenBao emerged as a true open-source alternative
- **Feature parity**: Maintains API compatibility with Vault, enabling existing tools and integrations
- **No vendor lock-in**: Linux Foundation project with transparent governance
- **High availability**: Deployed in 5-node Raft cluster with SPOT instances for cost efficiency

**Related**: [TLS with Gateway API: Efficient and Secure Management of Public and Private Certificates](https://blog.ogenki.io/post/pki-gapi/)

### VictoriaMetrics over Prometheus

**Decision**: Use VictoriaMetrics for metrics collection and storage.

**Rationale**:
- **Performance**: Significantly better resource efficiency and query performance
- **Cost-effective**: Lower storage requirements, better compression
- **PromQL compatible**: Drop-in replacement for Prometheus queries
- **Unified stack**: VictoriaLogs integrates seamlessly for log management
- **Scalability**: Better handling of high-cardinality metrics

**Related**: [Harness the Power of VictoriaMetrics and Grafana Operators for Metrics Management](https://blog.ogenki.io/post/series/observability/metrics)

### Crossplane for Infrastructure Abstraction

**Decision**: Use Crossplane alongside OpenTofu (not replacing it) for application infrastructure.

**Rationale**:
- **Right abstraction level**: Provides platform APIs without hiding underlying infrastructure
- **Kubernetes-native**: Leverages existing RBAC, audit, and GitOps workflows
- **Progressive complexity**: App composition grows from simple to production-ready without rewrites
- **Developer self-service**: Teams can provision infrastructure without leaving Kubernetes
- **Composition functions**: KCL enables sophisticated logic and validation

**Why not just Terraform/OpenTofu?**:
- OpenTofu manages foundational infrastructure (VPC, EKS, OpenBao)
- Crossplane manages application-scoped infrastructure (databases, IAM roles, storage)
- This separation provides clear boundaries and ownership

**Related**:
- [Going Further with Crossplane: Compositions and Functions](https://blog.ogenki.io/post/crossplane_composition_functions/)
- [My Kubernetes Cluster (GKE) with Crossplane](https://blog.ogenki.io/post/crossplane_k3d/)

### Gateway API over Traditional Ingress

**Decision**: Use Gateway API for ingress and routing.

**Rationale**:
- **Modern standard**: Kubernetes SIG-supported evolution beyond Ingress
- **Rich routing**: Advanced HTTP routing, traffic splitting, header manipulation
- **TLS management**: First-class Certificate resource integration
- **Multi-tenancy**: Clearer separation between infrastructure and application concerns
- **Future-proof**: Active development, growing ecosystem support

**Related**: [TLS with Gateway API: Efficient and Secure Management of Public and Private Certificates](https://blog.ogenki.io/post/pki-gapi/)

### KCL for Crossplane Compositions

**Decision**: Use KCL (Kusion Configuration Language) instead of traditional Crossplane composition patches.

**Rationale**:
- **Readability**: Code is easier to understand than complex patch operations
- **Validation**: Built-in type checking and schema validation
- **Testing**: Unit tests for composition logic
- **Conditionals**: Complex business logic without patch gymnastics
- **Iteration**: Easy to loop over resources (multiple databases, S3 buckets, etc.)

**Trade-offs**:
- Learning curve for KCL syntax
- Known mutation bug (#285) requires specific patterns
- Requires CI/CD for publishing modules to GHCR

### Cilium for Networking

**Decision**: Use Cilium instead of default AWS VPC CNI or Calico.

**Rationale**:
- **eBPF-based**: Kernel-level networking without iptables performance overhead
- **Network policies**: Rich Layer 7 policies for zero-trust micro-segmentation
- **Observability**: Hubble provides deep network visibility
- **Gateway API support**: Native ingress controller capabilities
- **Performance**: Lower latency, higher throughput than traditional CNI

### Tailscale for Private Access

**Decision**: Use Tailscale VPN instead of bastion hosts or public endpoints.

**Rationale**:
- **Zero configuration**: No complex VPN infrastructure to manage
- **Zero-trust**: Device and user authentication per connection
- **Subnet routing**: Single EC2 instance provides access to entire VPC
- **Ease of use**: Simple client setup, automatic key rotation
- **Cost-effective**: Cheaper than NAT gateways and bastion hosts for admin access

**Related**: [Beyond Traditional VPNs: Simplifying Cloud Access with Tailscale](https://blog.ogenki.io/post/tailscale/)

### Dagger for CI/CD

**Decision**: Use Dagger for CI pipeline definitions.

**Rationale**:
- **Portability**: Run the same pipeline locally and in CI
- **Code over YAML**: Define pipelines in actual programming languages
- **Caching**: Sophisticated layer caching for faster builds
- **Consistency**: Eliminate "works on my machine" issues
- **Developer experience**: Test CI changes locally before pushing

**Related**: [Dagger: The missing piece of the developer experience](https://blog.ogenki.io/post/dagger-intro/)

### Flux for GitOps

**Decision**: Use Flux for continuous delivery.

**Rationale**:
- **Kubernetes-native**: Uses CRDs and controllers, not external daemons
- **Security**: GitHub App authentication, no long-lived tokens
- **Dependencies**: Built-in dependency management between resources
- **Health checking**: Wait for resources to be ready before proceeding
- **CNCF project**: Strong community and ecosystem support

### Terramate for OpenTofu Orchestration

**Decision**: Use Terramate to manage multiple OpenTofu stacks.

**Rationale**:
- **Stack management**: Organize infrastructure into logical units
- **Drift detection**: Continuous monitoring of infrastructure state
- **Change preview**: See what will change before applying
- **DRY configuration**: Share variables across stacks
- **Workflow automation**: Script common operations consistently

## Alternative Considerations

### Why not...

**...use Terraform Cloud/Spacelift/Atlantis?**
- Terramate provides sufficient orchestration without additional services
- GitOps workflow preferred for Kubernetes-centric operations
- Cost and complexity not justified for this use case

**...use ArgoCD instead of Flux?**
- Both are excellent; Flux chosen for Kubernetes-native approach
- GitHub App authentication preferred over deploy keys
- Health checks and dependencies well-suited to our needs

**...use Prometheus instead of VictoriaMetrics?**
- Prometheus is excellent but VictoriaMetrics offers better resource efficiency
- Cost savings significant at scale
- PromQL compatibility makes migration easy if needed

**...use HashiCorp Vault instead of OpenBao?**
- License concerns with HashiCorp products
- OpenBao provides community governance
- Feature parity and compatibility maintained

## Technology Evolution

This platform's technology choices reflect a specific point in time. We continuously evaluate:

- **Emerging standards**: Gateway API, Crossplane, eBPF
- **Community trends**: Open-source forks, CNCF projects
- **Cost efficiency**: Resource usage, cloud costs
- **Developer experience**: Time to production, ease of use
- **Security**: Zero-trust, least privilege, audit trails

## Further Reading

- [Blog: Cloud Native Platform Series](https://blog.ogenki.io/)
- [Crossplane Documentation](https://docs.crossplane.io/)
- [Flux Documentation](https://fluxcd.io/)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Cilium Documentation](https://docs.cilium.io/)
