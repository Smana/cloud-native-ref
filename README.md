# Reference Repository for Building a Cloud Native Platform

**_This is an opinionated set of configurations for managing a Cloud Native platform using GitOps principles._**

This repository provides a comprehensive guide and set of tools for building, managing, and maintaining a Cloud Native platform. It includes configurations for Kubernetes, Crossplane, Flux, OpenBao, and more, with a focus on security, scalability, and best practices.

## Table of Contents

- [☑️ Curated Toolset and Use Cases](#️-curated-toolset-and-use-cases)
- [🚀 Getting started](#-getting-started)
- [🔄 Flux Dependencies Matter](#-flux-dependencies-matter)
- [🏗️ Crossplane Configuration](#️-crossplane-configuration)
  - [Requirements and Security Concerns](#requirements-and-security-concerns)
  - [How is Crossplane Deployed?](#how-is-crossplane-deployed)
- [📦 OCI Registry with Harbor](#-oci-registry-with-harbor)
- [🔗 VPN connection using Tailscale](#-vpn-connection-using-tailscale)
- [🔑 Private PKI with OpenBao](#-private-pki-with-openbao)
- [👁️ Observability](#️-observability)
- [🧪 CI](#-ci)
  - [Overview](#overview)
  - [🏠 Using Self-Hosted Runners](#-using-self-hosted-runners)
- [💬 Chating and contributing](#-chating-and-contributing)

## ☑️ Curated Toolset and Use Cases

![overview](.assets/cloud-native-ref.png)

| Technology                                                                                                           | Domain                 | What it is used for?                                                                                      |
|----------------------------------------------------------------------------------------------------------------------|------------------------|----------------------------------------------------------------------------------------------------------|
| ![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)    | Infrastructure         | Container orchestration, core platform on which applications are deployed                                |
| ![Crossplane](https://img.shields.io/badge/Crossplane-4D4D4D?style=for-the-badge&logo=crossplane&logoColor=white)    | Infrastructure         | Framework to compose application and infrastructure components, providing proper abstraction levels      |
| ![OpenTofu](https://img.shields.io/badge/OpenTofu-24B8EB?style=for-the-badge&logo=open-tofu&logoColor=white)         | Infrastructure         | Open-source alternative to Terraform for provisioning and managing infrastructure                        |
| ![Harbor](https://img.shields.io/badge/Harbor-60B932?style=for-the-badge&logo=harbor&logoColor=white)                | Application            | Secure container image registry with scanning and signing capabilities                                   |
| ![Headlamp](https://img.shields.io/badge/Headlamp-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)        | Application            | Web-based GUI for Kubernetes cluster management                                                          |
| ![CloudNativePG](https://img.shields.io/badge/CloudNativePG-316192?style=for-the-badge&logo=postgresql&logoColor=white) | Data                   | Kubernetes operator managing PostgreSQL clusters with high availability and failover support             |
| ![Valkey](https://img.shields.io/badge/Valkey-4B0082?style=for-the-badge&logo=key&logoColor=white)                   | Data                   | Redis-like key-value data store                                                                          |
| ![Dagger](https://img.shields.io/badge/Dagger-000000?style=for-the-badge&logo=dagger&logoColor=white)                | Continuous Delivery    | CI/CD tool used to define and run pipelines as code                                                      |
| ![Flux](https://img.shields.io/badge/Flux-0D1117?style=for-the-badge&logo=flux&logoColor=white)                      | Continuous Delivery    | GitOps engine ensuring that what is defined in the GitHub repository is deployed on Kubernetes           |
| ![VictoriaMetrics](https://img.shields.io/badge/VictoriaMetrics-2A4666?style=for-the-badge&logo=prometheus&logoColor=white) | Observability          | High-performance monitoring solution for collecting and querying metrics                                 |
| ![Tailscale](https://img.shields.io/badge/Tailscale-006AFC?style=for-the-badge&logo=tailscale&logoColor=white)        | Networking             | VPN solution for secure connections between Kubernetes clusters and other resources                      |
| ![Gateway API](https://img.shields.io/badge/Gateway--API-0088CE?style=for-the-badge&logo=kubernetes&logoColor=white) | Networking             | Defines standard APIs for configuring Kubernetes ingress and traffic routing                             |
| ![Cilium](https://img.shields.io/badge/Cilium-4A90E2?style=for-the-badge&logo=cilium&logoColor=white)                | Networking             | Advanced networking, security, and observability for Kubernetes using eBPF                              |
| ![External DNS](https://img.shields.io/badge/External--DNS-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white) | Networking             | Synchronizes Kubernetes resources with DNS providers like Route 53, Cloudflare, and others               |
| ![OpenBao](https://img.shields.io/badge/OpenBao-232F3E?style=for-the-badge&logo=openbao&logoColor=white)             | Security               | Open-source fork of Vault for secure secret storage, encryption, and access management                   |
| ![Cert-manager](https://img.shields.io/badge/Cert--manager-326CE5?style=for-the-badge&logo=cert-manager&logoColor=white) | Security               | Automates the creation and renewal of TLS certificates                                                   |
| ![ZITADEL](https://img.shields.io/badge/ZITADEL-002B5C?style=for-the-badge&logo=zitadel&logoColor=white)             | Security               | Cloud-native identity and access management system                                                       |
| ![ExternalSecrets Operator](https://img.shields.io/badge/ExternalSecrets_Operator-FF6C37?style=for-the-badge&logo=external-secrets&logoColor=white) | Security               | Synchronizes secrets from external secret managers (e.g., Vault, AWS Secrets Manager) into Kubernetes    |
| ![Route 53](https://img.shields.io/badge/Route_53-FF9900?style=for-the-badge&logo=amazon&logoColor=white)            | Managed Services       | DNS service for routing traffic to applications and resources                                            |
| ![KMS](https://img.shields.io/badge/KMS-FF9900?style=for-the-badge&logo=amazon&logoColor=white)                      | Managed Services       | Key management service to encrypt sensitive data                                                         |
| ![IAM](https://img.shields.io/badge/IAM-FF9900?style=for-the-badge&logo=amazon&logoColor=white)                      | Managed Services       | Identity and Access Management for controlling access to AWS resources                                   |
| ![ELB](https://img.shields.io/badge/ELB-FF9900?style=for-the-badge&logo=amazon&logoColor=white)                      | Managed Services       | Load balancer service to distribute traffic across multiple instances                                    |
| ![S3](https://img.shields.io/badge/S3-FF9900?style=for-the-badge&logo=amazon&logoColor=white)                        | Managed Services       | Cloud storage service for storing and retrieving any amount of data                                      |


## 🚀 Getting started

There are basically 3 things to run when deploying the whole stack:

1. 📡 [Install the network requirements](./opentofu/network/README.md)
2. 🔒 [Deploy a OpenBao instance](./opentofu/openbao/cluster/README.md)
3. ☸️ [Bootstrap the EKS cluster and Flux components](./opentofu/eks/README.md)

## 🔄 Flux Dependencies Matter

[Flux](https://fluxcd.io/) is a foundational component responsible for deploying all resources as soon as the Kubernetes cluster becomes operational. Below is a diagram that highlights the key dependencies in our setup:

```mermaid
graph TD;
    Namespaces-->CRDs;
    CRDs-->Crossplane;
    Crossplane-->EPIs["EKS Pod Identities"];
    EPIs["EKS Pod Identities"]-->Security;
    EPIs["EKS Pod Identities"]-->Infrastructure;
    EPIs["EKS Pod Identities"]-->Observability;
    Observability-->Apps["Other apps"];
    Infrastructure-->Apps["Other apps"];
    Security-->Infrastructure;
    Security-->Observability
```

This diagram can be hard to understand so these are the key information:

- **Namespaces** - Namespaces are the foundational resources in Kubernetes. All subsequent resources can be scoped to namespaces.

- **Custom Resource Definitions (CRDs)** - CRDs extend Kubernetes' capabilities by defining new resource types. These must be established before they can be utilized in other applications.

- **Crossplane** - Used to provision the necessary infrastructure components from Kubernetes.

- **EKS Pod Identities** - Created using Crossplane, these IAM roles are necessary to grant specific AWS API permissions to certain applications.

- **Security** - Among other things, this step deploys `external-secrets` which is essential to use sensitive data into our applications


## 🏗️ Crossplane Configuration

### Requirements and Security Concerns

When the cluster is initialized, we define the permissions for the Crossplane controllers using Opentofu. This involves attaching a set of IAM policies to a role. This role is crucial for managing AWS resources.

We prioritize security by adhering to the principle of **least privilege**. This means we only grant the necessary permissions, avoiding any excess. For instance, although Crossplane allows it, I have chosen not to give the controllers the ability to delete stateful services like S3, IAM or Route53. This decision is a deliberate step to minimize potential risks.

Additionally, I have put a constraint on the resources the controllers can manage. Specifically, they are limited to managing only those resources which are prefixed with `xplane-`. This restriction helps in maintaining a more controlled and secure environment.

### How is Crossplane Deployed?

[Crossplane](https://www.crossplane.io/) allows provisioning and managing Cloud Infrastructure (and even more) using native Kubernetes features. It needs to be installed and set up in three **successive steps**:

1. Installation of the Kubernetes operator.
2. Deployment of the AWS provider, which provides custom resources, including AWS roles, policies, etc.
3. Installation of compositions that will generate AWS resources.

🏷️ Related blog posts:

- [Going Further with Crossplane: Compositions and Functions](https://blog.ogenki.io/post/cilium-gateway-api/)
- [My Kubernetes Cluster (GKE) with Crossplane](https://blog.ogenki.io/post/crossplane_k3d/)

## 📦 OCI Registry with Harbor

The Harbor installation follows best practices for high availability. It leverages recent Crossplane features such as `Composition functions`:

- A [CloudNativePG](https://cloudnative-pg.io/) instance.
- Valkey cluster using the Bitnami Helm chart
- Storing artifacts in S3

🏷️ Related blog post: [Going Further with Crossplane: Compositions and Functions](https://blog.ogenki.io/post/crossplane_composition_functions/)

## 🔗 VPN connection using Tailscale

The VPN configuration is done within the `opentofu/network` directory.
You can follow the steps described in this [README](/opentofu/network/README.md) in order to provision a server that allows to access to private resources within AWS.

Most of the time we don't want to expose our resources publicly. For instance our platform tools such as `Grafana`, `Harbor` should be access through a secured wire.
The risk becomes even more significant when dealing with Kubernetes' API. Indeed, one of the primary recommendations for securing a cluster is to limit access to the API.

Anyway, I intentionnaly created a distinct directory that allows to provision the network and a secured connection. So that there are no confusion with the EKS provisionning.

🏷️ Related blog post: [Beyond Traditional VPNs: Simplifying Cloud Access with Tailscale](https://blog.ogenki.io/post/tailscale/)

## 🔑 Private PKI with OpenBao

:information_source: OpenBao is an opensource fork of the Hashicorp Vault solution.

The OpenBao instance creation is made in 2 steps:

1. Create the cluster as described [here](/opentofu/openbao/cluster/README.md)
2. Then configure it using [this directory](/opentofu/openbao/management/README.md)

The provided code outlines the setup and configuration of a **highly available, secure, and cost-efficient OpenBao cluster**. It describes the process of creating a OpenBao instance in either development or high availability mode, with detailed steps for initializing the OpenBao, managing security tokens, and configuring a robust **Public Key Infrastructure** (PKI) system. The focus is on balancing performance, security, and cost, using a multi-node cluster, ephemeral nodes with SPOT instances, and a tiered CA structure for digital security.

🏷️ Related blog post: [TLS with Gateway API: Efficient and Secure Management of Public and Private Certificates](https://blog.ogenki.io/post/pki-gapi/)


## 👁️ Observability

To effectively **identify issues and optimize performance**, a comprehensive monitoring stack is essential. Several tools are available to provide detailed insights into system health, covering key areas such as metrics, logs, tracing, and profiling. Here's an overview of our current setup:

* **Metrics**: We’ve implemented a combination of VictoriaMetrics and Grafana operators to collect, visualize, and analyze metrics. This stack enables real-time monitoring, custom dashboards, and the ability to configure alerts and notifications for proactive issue management.

* **Logs**: (Coming soon)

🏷️ Related blog posts:

* [Harness the Power of VictoriaMetrics and Grafana Operators for Metrics Management](https://blog.ogenki.io/post/series/observability/metrics)

## 🧪 CI

### Overview

We leverage **[Dagger](https://dagger.io/)** for all our CI tasks. Here's what is currently run:

* Validation of Kubernetes and Kustomize manifests using `kubeconform`
* Validation of Terraform/Opentofu configurations using the [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform)

### 🏠 Using Self-Hosted Runners

Deploying
This feature can be enabled within the `tooling` kustomization. By leveraging **Self-Hosted GitHub Runners**, we achieve:

- **Access to Private Endpoints**: Directly interact with internal resources that are not publicly accessible.
- **Increased Security**: Run CI tasks within our secure internal environment.

For detailed information on setting up and using GitHub Self-Hosted Runners, please refer to this [documentation](https://docs.github.com/en/actions/hosting-your-own-runners).

🏷️ Related blog post: Dagger: [The missing piece of the developer experience](https://blog.ogenki.io/post/dagger-intro/)

## 💬 Chating and contributing

- 🗨️ [**Slack Channel**](https://ogenki.slack.com/): Feel free to come and chat with us if you have any issue, ideas or questions.
- 💡 [**Discussions**](https://github.com/Smana/cloud-native-ref/discussions): Explore improvement areas, define the roadmap, and prioritize issues.
- 🛠️ [**Issues**](https://github.com/Smana/cloud-native-ref/issues): Track tasks and report bugs to ensure prompt resolution.
- 📅 [**Project**](https://github.com/users/Smana/projects/1): Detailed project planning and prioritization information.
