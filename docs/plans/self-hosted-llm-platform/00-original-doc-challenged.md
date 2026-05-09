# **Orchestrating Autonomous Intelligence: A Comprehensive Framework for Self-Hosting Lightweight LLMs on EKS via Flux and Crossplane**

The landscape of generative artificial intelligence in April 2026 has transitioned from a phase of centralized, proprietary dominance toward a highly decentralized ecosystem of open-weight models. For technically focused platforms such as blog.ogenki.io, the decision to self-host these models represents a strategic pivot toward data sovereignty, cost predictability, and specialized performance. The emergence of Small Language Models (SLMs) that maintain parity with the massive architectures of 2024 has redefined the economics of inference. By leveraging the advanced orchestration capabilities of Amazon Elastic Kubernetes Service (EKS) alongside the GitOps-driven automation of Flux CD and the infrastructure-as-code efficiency of Crossplane, organizations can deploy a production-grade AI stack that is both resilient and economically optimized. This report provides an exhaustive technical analysis and implementation roadmap for self-hosting the premier lightweight models of 2026 within the AWS Paris region (eu-west-3), focusing on the convergence of architectural efficiency and cloud-native best practices.

## **The State of Lightweight Open-Weight Models in April 2026**

The paradigm shift in large language model (LLM) development has led to the "Age of Efficiency," where models under 10 billion parameters are now capable of executing complex reasoning, multi-turn dialogue, and sophisticated code generation tasks that previously required orders of magnitude more compute.1 In April 2026, the selection of a model is no longer dictated solely by parameter count but by the specific architectural innovations that allow for high-throughput inference on consumer-grade and entry-level enterprise GPUs.

### **Architectural Innovations in Sub-10B Models**

The current market leaders, specifically the Qwen3, DeepSeek-R1 Distill, and Phi-4 series, have integrated several key technologies that make them ideal for self-hosting. The Qwen3-8B model, for instance, utilizes a dual-mode reasoning architecture. This system allows the model to switch between a "thinking mode"—which employs extended chain-of-thought processing for complex mathematical and logical queries—and a "non-thinking mode" for rapid, low-latency conversational responses.2 Such flexibility is essential for a blog-based deployment where user queries may range from simple navigation to requests for complex technical explanations.
Furthermore, the introduction of Mixture-of-Experts (MoE) at the lightweight scale has allowed models like the GPT-OSS-20B (with only 3.6B active parameters) to match the reasoning capabilities of proprietary mid-tier models while maintaining a memory footprint that fits within standard 16GB VRAM configurations.3 These models use sparse attention mechanisms to focus compute only on the most relevant tokens, significantly reducing the energy per inference and the total cost of ownership.

### **Benchmark Analysis and Memory Footprints**

To determine the most effective model for blog.ogenki.io, a comparison of the top-performing lightweight models as of April 2026 is necessary. The analysis focuses on reasoning accuracy, coding proficiency, and the minimum hardware requirements for 4-bit quantized deployment.

| Model Name | Developer | Parameters (Total/Active) | Context Window | Best Use Case | Min VRAM (Q4) |
| :---- | :---- | :---- | :---- | :---- | :---- |
| Qwen3-8B | Qwen Team | 8.2B / 8.2B | 131K | General reasoning, Multilingual | 5.2 GB |
| DeepSeek-R1-Distill-7B | DeepSeek | 7B / 7B | 33K | Math, Programming, Logic | 5.0 GB |
| Phi-4 Mini | Microsoft | 3.8B / 3.8B | 128K | STEM, Analytical tasks | 2.5 GB |
| Llama 3.1 8B | Meta | 8B / 8B | 128K | Dialogue, Broad integration | 4.7 GB |
| Gemma 3n E2B | Google | 5B / 2B | 32K | Multimodal (Vision+Audio) | 3.0 GB |
| SmolLM3-3B | Hugging Face | 3B / 3B | 32K | Summarization, Transparency | 2.0 GB |

The data indicates that Qwen3-8B is the most versatile choice for a general-purpose blog assistant, offering the widest language support and the most flexible reasoning modes.2 However, if the blog primarily focuses on technical code reviews or mathematical content, the DeepSeek-R1-Distill-7B provides a superior accuracy profile, specifically reaching 92.8% on the MATH-500 benchmark and a 55.5% pass rate on AIME 2024, which is remarkable for a model of its size.2
The memory bandwidth requirements for these models are a critical factor in determining the perceived latency for the end user. Inference is primarily a memory-bandwidth-bound task, where the hardware must read model weights from memory as fast as possible to generate tokens. For a model like Qwen3-8B, the bandwidth ceiling for 4-bit (Q4) decode is approximately 94 tokens per second on modern hardware, though this drops as the KV cache grows in long-context conversations.5

## **Infrastructure Economics: The Paris (eu-west-3) GPU Landscape**

For blog.ogenki.io, the primary goal is to minimize costs while ensuring that the infrastructure is capable of handling bursty traffic without significant degradation in quality. The AWS Paris region (eu-west-3) offers a variety of accelerated computing instances, ranging from the legacy G4dn series to the state-of-the-art P5 and G6 instances.

### **Comparative GPU Instance Pricing (April 2026\)**

In April 2026, the NVIDIA L4 GPU, found in the G6 instance family, has become the workhorse of small-scale inference. The L4 offers a significant upgrade over the T4 (G4dn) and the A10G (G5) in terms of energy efficiency and throughput per dollar. The following table highlights the pricing for key instances in the eu-west-3 region.

| Instance Family | GPU Type | VRAM per GPU | On-Demand ($/hr) | Spot ($/hr) | Savings Plan (1yr) |
| :---- | :---- | :---- | :---- | :---- | :---- |
| g6.xlarge | 1 x NVIDIA L4 | 24 GB | $1.0216 | $0.3256 | $0.8313 |
| g6.2xlarge | 1 x NVIDIA L4 | 24 GB | $1.2409 | $0.3357 | $1.0098 |
| g5.xlarge | 1 x NVIDIA A10G | 24 GB | $1.0100 | $0.2800 | $0.7820 |
| inf2.xlarge | 1 x Inferentia2 | 32 GB | $1.0615 | $0.1294 | $0.6700 |
| g4dn.xlarge | 1 x NVIDIA T4 | 16 GB | $0.6150 | $0.1741 | $0.3800 |
| p5.4xlarge | 1 x NVIDIA H100 | 80 GB | $3.9330 | N/A | $2.8000 |

The g6.xlarge instance is the optimal choice for hosting a single instance of Qwen3-8B or DeepSeek-R1-Distill-7B. At a Spot price of $0.3256 per hour, the monthly cost of running the model continuously is approximately $234.43.6 However, for a blog that may only see traffic during specific hours, the use of Karpenter to scale the GPU nodes to zero during idle periods can reduce this cost to a fraction of the baseline.7

### **Hidden Costs and Egress Optimization**

Operating a self-hosted model involves secondary costs that often escape initial budgeting. In the AWS ecosystem, these include NAT Gateways, Elastic Load Balancers (ALB/NLB), and data transfer fees. For instance, data transfer from EC2 to the internet in Paris is billed at $0.02 per GB after the first 100 GB.9 While text-based model responses are light, high-traffic blogs can accumulate significant egress fees if the model is used for image or audio processing via multimodal variants like Gemma 3n E2B.4
A significant cost-saving measure is the consolidation of ingress traffic. Instead of deploying an Application Load Balancer (ALB) for every service, utilizing an NGINX Ingress Controller allows multiple services (the blog, the model API, and monitoring tools) to share a single Network Load Balancer (NLB), which is typically 20-30% cheaper and offers better performance for high-concurrency workloads.10

## **Orchestrating Infrastructure with Crossplane**

The implementation plan for blog.ogenki.io centers on the use of Crossplane to manage the AWS infrastructure through a Kubernetes-native control plane. Crossplane allows the platform team to define high-level abstractions, such as an "AICluster," which encapsulates the complexities of VPCs, IAM roles, and EKS managed node groups into a simple manifest.12

### **The Provider-AWS and Identity Configuration**

The first step in the deployment is the configuration of the Crossplane AWS provider. In 2026, the industry standard is to avoid long-lived access keys in favor of IAM Roles for Service Accounts (IRSA). This mechanism allows the Crossplane pod to assume an IAM role through an OIDC provider, granting it the permissions necessary to provision EC2 and EKS resources without sensitive credentials being stored in the cluster.12
The ProviderConfig resource is used to define how Crossplane authenticates with AWS. For a production environment, the InjectedIdentity source is preferred, as it leverages the STS (Security Token Service) for temporary, rotating credentials.12

YAML

apiVersion: aws.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity

### **Developing Compositions for EKS and GPU Nodes**

Crossplane’s power lies in its ability to compose multiple resources into a single logical unit. For the blog.ogenki.io deployment, a Composition is created to define the "Remote Workload Cluster." This composition includes the EKS control plane, the necessary VPC infrastructure, and two types of node groups: a stable, non-accelerated node group for management controllers (Flux, Crossplane, Karpenter) and a dynamic GPU node group for inference.15
The composition must ensure that the EKS cluster is configured with the correct OIDC provider and that the IAM roles for the worker nodes include the necessary policies, such as AmazonEKSWorkerNodePolicy, AmazonEKS\_CNI\_Policy, and AmazonEC2ContainerRegistryReadOnly.16 For the GPU nodes, additional permissions are required to allow the nodes to interact with the NVIDIA device plugin and pull large model weights from S3 or ECR.14
A critical feature in the 2026 version of Crossplane is the managementPolicies field. This allows the administrator to define exactly what actions Crossplane can take on an external resource. For example, setting the policy to \["Observe", "Create", "Update"\] prevents Crossplane from deleting a production database or VPC accidentally, even if the Kubernetes object is removed.17

## **Continuous Delivery via Flux CD**

Flux CD provides the GitOps engine that ensures the desired state in the Git repository is always reflected in the EKS cluster. By treating the blog's infrastructure and application manifests as the single source of truth, the deployment becomes highly reproducible and auditable.18

### **Bootstrapping the GitOps Repository**

The Flux bootstrap process initializes the cluster and connects it to a GitHub repository. This repository typically follows a multi-environment structure, where the clusters/production folder contains the specific configurations for the blog's live environment.18

Bash

flux bootstrap github \\
  \--owner=$GITHUB\_USER \\
  \--repository=fleet-infra \\
  \--branch=main \\
  \--path=./clusters/production

Flux utilizes HelmRepository and HelmRelease resources to manage the deployment of the AI serving stack. This is particularly useful for tools like vLLM and the NGINX Ingress Controller, which have mature Helm charts. Flux's ability to react to changes in referenced Secrets and ConfigMaps means that rotated API keys or updated model configurations are applied instantly without manual restarts.20

### **Managing Secrets and Sensitive Data**

One of the challenges in a GitOps workflow is the management of secrets. For blog.ogenki.io, Bitnami’s Sealed Secrets or AWS Secrets Manager integration with the External Secrets Operator (ESO) is recommended. This allows encrypted secrets to be safely stored in the Git repository, which are then decrypted by a controller inside the EKS cluster only when needed.21 This ensures that even if the Git repository is compromised, the actual AWS keys and database passwords remain protected.

## **Dynamic GPU Provisioning with Karpenter**

Traditional autoscaling in Kubernetes, which relies on Managed Node Groups and the Cluster Autoscaler, is often too rigid for AI workloads. Karpenter provides a more dynamic approach by observing unschedulable pods and immediately launching the exact instance types required to satisfy their resource requests.7

### **The NodePool and EC2NodeClass Architecture**

Karpenter uses two primary objects: the NodePool and the EC2NodeClass. The NodePool defines the constraints on what Karpenter can provision—such as instance categories (e.g., g6, g5), capacity types (spot, on-demand), and zones.24 The EC2NodeClass contains AWS-specific settings like the AMI family (e.g., Bottlerocket, AL2023), security groups, and subnet selectors.8
For the blog deployment, the NodePool should be configured to prefer Spot instances for GPU workloads to maximize cost savings, while maintaining an on-demand fallback in case of Spot capacity shortages in eu-west-3.7

YAML

apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-workloads
spec:
  template:
    spec:
      requirements:
        \- key: "karpenter.sh/capacity-type"
          operator: In
          values: \["spot", "on-demand"\]
        \- key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: \["g"\]
      taints:
        \- key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule

The use of taints is crucial here; it ensures that general-purpose pods (like the blog's frontend) do not accidentally schedule onto expensive GPU nodes, which are reserved exclusively for the inference engine.8

### **Mitigating Interruption and Cold Starts**

Using Spot instances for GPU workloads requires a robust strategy for handling interruptions. AWS provides a two-minute warning before reclaiming a Spot instance. Karpenter natively handles this by monitoring the EC2 Spot Interruption Termination Notice (ITN) and immediately launching a replacement node while gracefully draining the existing one.24
Cold starts—the time it takes for a new node to boot and pull the massive container image for vLLM and the model weights—are another significant hurdle. In 2026, practitioners mitigate this by "pre-fetching" images using EBS snapshots. By creating a snapshot of the container cache on a Bottlerocket volume and referencing that snapshot ID in the EC2NodeClass, new GPU nodes can boot with the model weights already present, reducing the ready time from minutes to under 45 seconds.8

## **Inference Serving: The vLLM Architecture**

The final component of the AI stack is the inference server. As of April 2026, vLLM remains the industry standard for production serving due to its advanced memory management through PagedAttention, which minimizes fragmentation in the KV cache and allows for higher batch sizes and throughput.28

### **Performance Triage and Optimization**

A production vLLM deployment requires careful tuning to balance Time-to-First-Token (TTFT) and Inter-Token Latency (ITL). For blog.ogenki.io, the following optimization path is recommended:

1. **Quantization**: Utilizing FP8 quantization reduces the VRAM footprint of the model by 50% while maintaining nearly identical accuracy. This is natively supported by the NVIDIA L4 GPUs in G6 instances and allows an 8B model to run comfortably on a single g6.xlarge with significant room for the KV cache.6
2. **Speculative Decoding**: By running a smaller "draft" model (like Phi-4 Mini) alongside the "target" model (Qwen3-8B), vLLM can generate multiple tokens per forward pass. This effectively multiplies the throughput and reduces latency for the end user.5
3. **Distribution Strategy**: For models under 10B parameters, a Tensor Parallel (TP) degree of 1 is optimal. Running multiple independent replicas at TP=1 on separate GPUs provides higher aggregate throughput and better fault tolerance than a single large instance running at TP=4, especially when using Spot instances.28

### **Monitoring and Observability**

The vLLM server exposes a wealth of Prometheus metrics that are essential for maintaining the health of the blog's AI features. Key metrics include num\_requests\_waiting (indicating queue depth) and gpu\_cache\_usage\_perc. These metrics should be integrated into a Grafana dashboard and used as triggers for horizontal pod autoscaling (HPA). If the queue depth exceeds a specific threshold, the HPA can signal Karpenter to provision another GPU node, ensuring that users of blog.ogenki.io do not experience delays during traffic spikes.25

## **Security, Authentication, and Edge Protection**

Self-hosting a model introduces a new vector for abuse, specifically "cost-based denial of service," where attackers flood the endpoint with high-token requests to exhaust the GPU budget. To protect the infrastructure, a multi-layered security model is required, combining identity-aware access control with Layer 7 inspection.30

### **Identity-Aware Access Control (SSO)**

The inference endpoint should never be exposed anonymously. OAuth2 Proxy, deployed via Flux, provides a standardized way to add Single Sign-On (SSO) in front of the vLLM service. By integrating with a provider like GitHub or Google, the blog can restrict access to authenticated users or specific organizational units.32
The configuration involves adding specific annotations to the Kubernetes Ingress resource, which tell the NGINX Ingress Controller to redirect unauthenticated requests to the OAuth2 Proxy for validation.

YAML

annotations:
  nginx.ingress.kubernetes.io/auth-url: "https://oauth2.ogenki.io/oauth2/auth"
  nginx.ingress.kubernetes.io/auth-signin: "https://oauth2.ogenki.io/oauth2/start?rd=$escaped\_request\_uri"

### **Layer 7 AI Security and WAF**

Traditional firewalls are blind to the content of LLM prompts. An integrated Web Application Firewall (WAF) at the ingress layer is necessary to inspect the request payload for malicious patterns, such as prompt injection or probing attacks designed to extract sensitive data from the RAG (Retrieval-Augmented Generation) pipeline.30
In 2026, NGINX Ingress Controller supports advanced rate limiting based on custom variables, such as the estimated token count of a request. This allows the platform to impose stricter limits on "expensive" queries while allowing "cheap" queries to pass through at a higher rate, protecting the GPU resources from being monopolized by a single user.30

## **Implementation Roadmap for blog.ogenki.io**

The deployment of the self-hosted AI stack is structured into four distinct phases, ensuring a stable transition from infrastructure to application.

### **Phase 1: Foundation and Control Plane**

The initial phase involves the establishment of the management hub and the provisioning of the core EKS cluster. This is achieved through Crossplane and Flux, setting the stage for GitOps-driven infrastructure.

1. **Bootstrap Flux**: Initialize the management cluster and connect it to the fleet-infra Git repository. This repository will house all future infrastructure and application manifests.18
2. **Install Crossplane Providers**: Deploy the Crossplane AWS provider and configure it with IRSA for secure, temporary credential access.12
3. **Provision Remote EKS**: Apply the XGPUCluster composite resource to trigger Crossplane to build the VPC, IAM roles, and the EKS control plane in eu-west-3.15
4. **Handoff to Workload Cluster**: Configure Flux to monitor the newly created remote cluster by injecting the KubeConfig secret from Crossplane into Flux’s source controller.21

### **Phase 2: Accelerated Compute and Scaling**

With the cluster operational, the second phase focuses on enabling GPU support and dynamic scaling to optimize for cost and performance.

1. **Deploy NVIDIA Device Plugin**: Install the daemonset necessary for Kubernetes to recognize and schedule GPU resources.8
2. **Install Karpenter**: Use the Flux HelmRelease to deploy Karpenter into the workload cluster. Configure the EC2NodeClass for the G6 instance family and the NodePool for Spot instance prioritization.7
3. **Set Up Interruption Handling**: Create the necessary SQS queues and EventBridge rules to allow Karpenter to respond to Spot interruption notices within the two-minute window.24
4. **Optimize Boot Times**: Create an EBS snapshot of the vLLM image cache and link it to the Bottlerocket userData in the EC2NodeClass to accelerate node readiness.27

### **Phase 3: Inference Serving and Observability**

The third phase involves the deployment of the chosen model and the configuration of the monitoring stack to ensure operational reliability.

1. **Select Model and Quantization**: Choose the Qwen3-8B model for the blog’s general assistant. Use the FP8 quantized version to minimize VRAM usage and maximize throughput.2
2. **Deploy vLLM**: Use Flux to deploy the vLLM Helm chart. Configure it with PagedAttention and speculative decoding using Phi-4 Mini as the drafter.5
3. **Configure Monitoring**: Deploy the Prometheus ServiceMonitor for vLLM and NGINX. Build a Grafana dashboard to track GPU utilization, request latency, and queue depths.11
4. **Implement HPA**: Configure the Horizontal Pod Autoscaler to scale the vLLM replicas based on the num\_requests\_waiting metric, allowing Karpenter to provision additional nodes as needed.25

### **Phase 4: Ingress, Security, and Edge**

The final phase secures the stack and exposes it to the public internet under the ogenki.io domain.

1. **Deploy NGINX Ingress Controller**: Install the controller via Flux and configure it with a single NLB in eu-west-3.11
2. **Configure OAuth2 Proxy**: Set up the proxy with GitHub SSO and create the necessary Kubernetes secrets for the Client ID and Secret.32
3. **Secure the Endpoint**: Add auth annotations to the Ingress resource for the vLLM service. Implement WAF rules to detect prompt injection and enforce token-based rate limiting.30
4. **Final Validation**: Perform an end-to-end test, ensuring that unauthenticated users are redirected to login and that successful authentication allows for low-latency inference from the Qwen3-8B model.

## **Conclusion and Strategic Outlook**

Self-hosting a lightweight open-weight model in April 2026 is a technically sophisticated but economically viable strategy for specialized platforms like blog.ogenki.io. The transition toward sub-10B models that rival the performance of legacy giants has shifted the bottleneck from model capability to the efficiency of the orchestration layer. By integrating Crossplane for infrastructure abstraction, Flux for GitOps consistency, and Karpenter for just-in-time GPU scaling, developers can build a platform that is not only highly performant but also capable of operating at the lowest possible cost through the aggressive use of Spot instances and modern G6 hardware.
As the AI ecosystem continues to evolve, the ability to maintain a sovereign, private inference stack will remain a key competitive advantage. The framework presented here provides a robust foundation for that sovereignty, ensuring that the blog’s intelligent features are built on a bedrock of security, automation, and architectural excellence. The future of AI is increasingly small, open, and distributed—and with the right tools, it is entirely within reach for the modern technical blog.

#### **Sources des citations**

1. Top 10 Small Language Models (SLMs) for 2026 — Benchmarked & Compared \- Intuz, consulté le avril 18, 2026, [https://www.intuz.com/blog/best-small-language-models](https://www.intuz.com/blog/best-small-language-models)
2. Ultimate Guide \- The Best Small LLMs Under 10B Parameters in 2026, consulté le avril 18, 2026, [https://www.siliconflow.com/articles/en/best-small-LLMs-under-10B-parameters](https://www.siliconflow.com/articles/en/best-small-LLMs-under-10B-parameters)
3. Top 10 Open-source Reasoning Models in 2026 \- Clarifai, consulté le avril 18, 2026, [https://www.clarifai.com/blog/top-10-open-source-reasoning-models-in-2026](https://www.clarifai.com/blog/top-10-open-source-reasoning-models-in-2026)
4. 15 Best Lightweight Language Models Worth Running in 2026, consulté le avril 18, 2026, [https://blog.premai.io/best-lightweight-language-models-worth-running/](https://blog.premai.io/best-lightweight-language-models-worth-running/)
5. What to Buy for Local LLMs (April 2026\) | by Julien Simon \- Medium, consulté le avril 18, 2026, [https://julsimon.medium.com/what-to-buy-for-local-llms-april-2026-a4946a381a6a](https://julsimon.medium.com/what-to-buy-for-local-llms-april-2026-a4946a381a6a)
6. g6.xlarge Specs & Pricing \- Spot, On-Demand & Savings Plans in eu-west-3 | DoiT Compute, consulté le avril 18, 2026, [https://compute.doit.com/spot/eu-west-3/g6.xlarge](https://compute.doit.com/spot/eu-west-3/g6.xlarge)
7. Amazon EKS (K8s) Media Cluster: Part 5 — Node Autoscaling with Karpenter \+ Spot instances | by Chris St. John | Medium, consulté le avril 18, 2026, [https://medium.com/@csjcode/amazon-eks-k8s-media-cluster-part-5-node-autoscaling-with-karpenter-spot-instances-de2f7c3334ad](https://medium.com/@csjcode/amazon-eks-k8s-media-cluster-part-5-node-autoscaling-with-karpenter-spot-instances-de2f7c3334ad)
8. Scale to zero GPUs with OpenFaaS, Karpenter and AWS EKS, consulté le avril 18, 2026, [https://www.openfaas.com/blog/scale-to-zero-gpus/](https://www.openfaas.com/blog/scale-to-zero-gpus/)
9. EC2 On-Demand Instance Pricing \- AWS, consulté le avril 18, 2026, [https://aws.amazon.com/ec2/pricing/on-demand/](https://aws.amazon.com/ec2/pricing/on-demand/)
10. Amazon EC2 Pricing Guide 2026 | Costs, Models & Fees \- Go Cloud, consulté le avril 18, 2026, [https://go-cloud.io/amazon-ec2-pricing/](https://go-cloud.io/amazon-ec2-pricing/)
11. How to Use HelmRelease for Deploying NGINX Ingress with Flux \- OneUptime, consulté le avril 18, 2026, [https://oneuptime.com/blog/post/2026-03-05-helmrelease-deploy-nginx-ingress-flux/view](https://oneuptime.com/blog/post/2026-03-05-helmrelease-deploy-nginx-ingress-flux/view)
12. How to Configure Crossplane Provider for AWS \- OneUptime, consulté le avril 18, 2026, [https://oneuptime.com/blog/post/2026-02-09-crossplane-provider-aws/view](https://oneuptime.com/blog/post/2026-02-09-crossplane-provider-aws/view)
13. How to Configure Crossplane Compositions for Resource Templates \- OneUptime, consulté le avril 18, 2026, [https://oneuptime.com/blog/post/2026-02-09-crossplane-compositions-templates/view](https://oneuptime.com/blog/post/2026-02-09-crossplane-compositions-templates/view)
14. v2.2 · Crossplane with Workload Identity, consulté le avril 18, 2026, [https://docs.crossplane.io/latest/guides/crossplane-with-workload-identity/](https://docs.crossplane.io/latest/guides/crossplane-with-workload-identity/)
15. v2.2 · Composite Resources \- Crossplane Documentation, consulté le avril 18, 2026, [https://docs.crossplane.io/latest/composition/composite-resources/](https://docs.crossplane.io/latest/composition/composite-resources/)
16. Building a Platform Abstraction for EKS Cluster Using Crossplane \- Medium, consulté le avril 18, 2026, [https://medium.com/@justramesh2000\_3534/building-a-platform-abstraction-for-eks-cluster-using-crossplane-4ddebf0891e8](https://medium.com/@justramesh2000_3534/building-a-platform-abstraction-for-eks-cluster-using-crossplane-4ddebf0891e8)
17. Managed Resources · Crossplane v2.2, consulté le avril 18, 2026, [https://docs.crossplane.io/latest/managed-resources/managed-resources/](https://docs.crossplane.io/latest/managed-resources/managed-resources/)
18. GitOps Deployment Strategies with Helm and Flux \- OneUptime, consulté le avril 18, 2026, [https://oneuptime.com/blog/post/2026-01-17-helm-flux-gitops-deployment/view](https://oneuptime.com/blog/post/2026-01-17-helm-flux-gitops-deployment/view)
19. Part 1: Multi-Cluster GitOps using Amazon EKS, Flux, and Crossplane | Containers \- AWS, consulté le avril 18, 2026, [https://aws.amazon.com/blogs/containers/part-1-build-multi-cluster-gitops-using-amazon-eks-flux-cd-and-crossplane/](https://aws.amazon.com/blogs/containers/part-1-build-multi-cluster-gitops-using-amazon-eks-flux-cd-and-crossplane/)
20. Manage Helm Releases \- Flux, consulté le avril 18, 2026, [https://fluxcd.io/flux/guides/helmreleases/](https://fluxcd.io/flux/guides/helmreleases/)
21. GitOps model for provisioning and bootstrapping Amazon EKS ..., consulté le avril 18, 2026, [https://aws.amazon.com/blogs/containers/gitops-model-for-provisioning-and-bootstrapping-amazon-eks-clusters-using-crossplane-and-flux/](https://aws.amazon.com/blogs/containers/gitops-model-for-provisioning-and-bootstrapping-amazon-eks-clusters-using-crossplane-and-flux/)
22. Learning GitOps with Helm Charts \+ Flux \- DEV Community, consulté le avril 18, 2026, [https://dev.to/mxoliver/learning-gitops-with-helm-charts-flux-163m](https://dev.to/mxoliver/learning-gitops-with-helm-charts-flux-163m)
23. Karpenter \- Amazon EKS \- AWS Documentation, consulté le avril 18, 2026, [https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)
24. Using Amazon EC2 Spot Instances with Karpenter | Containers \- AWS, consulté le avril 18, 2026, [https://aws.amazon.com/blogs/containers/using-amazon-ec2-spot-instances-with-karpenter/](https://aws.amazon.com/blogs/containers/using-amazon-ec2-spot-instances-with-karpenter/)
25. EKS Karpenter: Deep Dive \- stormforge.io, consulté le avril 18, 2026, [https://stormforge.io/kubernetes-autoscaling/eks-karpenter/](https://stormforge.io/kubernetes-autoscaling/eks-karpenter/)
26. Managing AMIs | Karpenter, consulté le avril 18, 2026, [https://karpenter.sh/docs/tasks/managing-amis/](https://karpenter.sh/docs/tasks/managing-amis/)
27. GPU Scaling on EKS: 5 Karpenter Mistakes to Stop Making | Sedai, consulté le avril 18, 2026, [https://sedai.io/blog/ultimate-guide-to-gpu-scaling-karpenter](https://sedai.io/blog/ultimate-guide-to-gpu-scaling-karpenter)
28. 5 steps to triage vLLM performance \- Red Hat Developer, consulté le avril 18, 2026, [https://developers.redhat.com/articles/2026/03/09/5-steps-triage-vllm-performance](https://developers.redhat.com/articles/2026/03/09/5-steps-triage-vllm-performance)
29. Best Open Source Self-Hosted LLMs for Coding in 2026 \- Pinggy, consulté le avril 18, 2026, [https://pinggy.io/blog/best\_open\_source\_self\_hosted\_llms\_for\_coding/](https://pinggy.io/blog/best_open_source_self_hosted_llms_for_coding/)
30. Ingress Security for AI Workloads in Kubernetes: Protecting AI Endpoints with WAF | Tigera, consulté le avril 18, 2026, [https://www.tigera.io/blog/ingress-security-for-ai-workloads-in-kubernetes-protecting-ai-endpoints-with-waf/](https://www.tigera.io/blog/ingress-security-for-ai-workloads-in-kubernetes-protecting-ai-endpoints-with-waf/)
31. CNCF Warns Kubernetes Alone Is Not Enough to Secure LLM Workloads \- InfoQ, consulté le avril 18, 2026, [https://www.infoq.com/news/2026/04/kubernetes-secure-workloads/](https://www.infoq.com/news/2026/04/kubernetes-secure-workloads/)
32. How to Deploy OAuth2 Proxy with Flux CD \- OneUptime, consulté le avril 18, 2026, [https://oneuptime.com/blog/post/2026-03-13-deploy-oauth2-proxy-with-flux-cd/view](https://oneuptime.com/blog/post/2026-03-13-deploy-oauth2-proxy-with-flux-cd/view)
33. The NGINX Kubernetes Open Source Roadmap: First Half of 2026, consulté le avril 18, 2026, [https://blog.nginx.org/blog/the-nginx-kubernetes-open-source-roadmap-first-half-of-2026](https://blog.nginx.org/blog/the-nginx-kubernetes-open-source-roadmap-first-half-of-2026)
34. Helm Charts \- vLLM, consulté le avril 18, 2026, [https://docs.vllm.ai/en/stable/examples/online\_serving/chart-helm/](https://docs.vllm.ai/en/stable/examples/online_serving/chart-helm/)
35. How to Deploy NGINX Ingress Controller with Flux CD \- OneUptime, consulté le avril 18, 2026, [https://oneuptime.com/blog/post/2026-03-06-deploy-nginx-ingress-controller-flux-cd/view](https://oneuptime.com/blog/post/2026-03-06-deploy-nginx-ingress-controller-flux-cd/view)
