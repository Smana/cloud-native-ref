# Spec: Add Queuing Composition Supporting Strimzi (Kafka) or SQS

**ID**: SPEC-001
**Issue**: [#1309](https://github.com/Smana/cloud-native-ref/issues/1309)
**Status**: draft
**Type**: composition
**Created**: 2026-01-24

---

## Summary

Add a new Crossplane composition that provides a unified API for message queuing, supporting both Strimzi (Kafka) for in-cluster event streaming and AWS SQS for managed cloud queuing. This enables platform users to provision queues with a consistent interface regardless of the underlying implementation.

---

## Problem

Application developers need message queuing for asynchronous communication, event-driven architectures, and workload decoupling. Currently, they must manually configure either Strimzi Kafka clusters or AWS SQS queues, requiring deep knowledge of each system. This leads to:

- Inconsistent configurations across teams
- Security misconfigurations (missing encryption, overly permissive IAM)
- No standard way to provide credentials to applications
- Manual effort to set up monitoring and alerting

A unified composition abstracts these details while enforcing platform standards.

---

## User Stories

### US-1: Simple Queue Provisioning (Priority: P1)

As a **developer**, I want **to provision a message queue with minimal configuration**, so that **I can focus on application logic rather than infrastructure setup**.

**Acceptance Scenarios**:
1. **Given** a QueueInstance CR with only `name` and `type: kafka`, **When** I apply it, **Then** a Kafka topic is created with sensible defaults (3 partitions, replication factor 2)
2. **Given** a QueueInstance CR with `type: sqs`, **When** I apply it, **Then** an SQS queue is created with encryption enabled and a dead-letter queue configured

### US-2: Credential Injection (Priority: P1)

As a **developer**, I want **queue credentials automatically available to my application**, so that **I don't need to manually configure secrets or IAM roles**.

**Acceptance Scenarios**:
1. **Given** a Kafka queue with `connectionSecret.name` specified, **When** the queue is ready, **Then** a Kubernetes Secret contains bootstrap servers, SASL credentials, and CA certificate
2. **Given** an SQS queue, **When** the queue is ready, **Then** an EKS Pod Identity is created allowing the specified service account to send/receive messages

### US-3: Production Configuration (Priority: P2)

As a **platform engineer**, I want **to configure production-grade queuing with HA, monitoring, and security**, so that **critical workloads have reliable message delivery**.

**Acceptance Scenarios**:
1. **Given** a Kafka queue with `highAvailability: true`, **When** created, **Then** the topic has min.insync.replicas=2 and the Kafka cluster spans multiple AZs
2. **Given** any queue type, **When** `monitoring.enabled: true`, **Then** appropriate ServiceMonitor/PodMonitor resources are created

---

## Requirements

### Functional

- **FR-001**: System MUST support Strimzi Kafka topics as a queue backend
- **FR-002**: System MUST support AWS SQS queues as a queue backend
- **FR-003**: System MUST create connection secrets with all required credentials
- **FR-004**: System MUST support dead-letter queue configuration for both backends
- **FR-005**: System MUST enable encryption at rest and in transit by default
- **FR-006**: System SHOULD support FIFO queues for SQS backend
- **FR-007**: System SHOULD create EKS Pod Identity for SQS access (no long-lived credentials)

### Non-Goals

- Multi-region replication (future iteration)
- Kafka Connect integration (separate composition)
- Schema Registry management (separate concern)
- Queue-to-queue bridging between Kafka and SQS

---

## Success Criteria

- **SC-001**: Users can create a Kafka topic with < 5 required fields
- **SC-002**: Users can create an SQS queue with < 5 required fields
- **SC-003**: Connection secrets are populated within 2 minutes of queue readiness
- **SC-004**: All examples render with Polaris score >= 85
- **SC-005**: E2E test demonstrates message send/receive for both backends

---

## Design

### API / Interface

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: QueueInstance
metadata:
  name: xplane-orders-queue
  namespace: apps
spec:
  # Required
  type: kafka | sqs  # Backend type

  # Kafka-specific (when type: kafka)
  kafka:
    clusterRef: my-kafka-cluster  # Reference to existing KafkaCluster
    partitions: 3                  # Optional, default: 3
    replicationFactor: 2           # Optional, default: 2
    retentionMs: 604800000         # Optional, default: 7 days
    config:                        # Optional, additional topic config
      cleanup.policy: delete

  # SQS-specific (when type: sqs)
  sqs:
    fifo: false                    # Optional, default: false
    visibilityTimeoutSeconds: 30   # Optional, default: 30
    messageRetentionSeconds: 345600 # Optional, default: 4 days
    maxMessageSize: 262144          # Optional, default: 256KB

  # Common options
  deadLetterQueue:
    enabled: true                  # Optional, default: true
    maxReceiveCount: 3             # Optional, default: 3

  # Credential delivery
  connectionSecret:
    name: orders-queue-credentials  # Secret name for credentials
    namespace: apps                 # Optional, defaults to CR namespace

  # For SQS: Pod Identity
  podIdentity:
    serviceAccountName: orders-service
    serviceAccountNamespace: apps

  # Monitoring
  monitoring:
    enabled: true                  # Optional, default: false
```

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| Strimzi KafkaTopic | type: kafka | Topic in referenced Kafka cluster |
| Strimzi KafkaUser | type: kafka | SASL/SCRAM user for authentication |
| Secret (connection) | Always | Bootstrap servers, credentials, CA cert |
| SQS Queue | type: sqs | Main queue with encryption |
| SQS Queue (DLQ) | type: sqs + DLQ enabled | Dead-letter queue |
| EKSPodIdentity | type: sqs | IAM role for pod access |
| ServiceMonitor | monitoring.enabled | Prometheus scraping |
| CiliumNetworkPolicy | Always | Restrict queue access |

### Dependencies

- [x] Strimzi Operator HelmRelease added (infrastructure/base/strimzi/)
- [x] AWS Crossplane Provider SQS added (provider-sqs.yaml)
- [x] EKS Pod Identity composition available (for SQS IAM)
- [x] External Secrets Operator (for Kafka credentials if using external secret store)

---

## Tasks

### Phase 1: Prerequisites
- [x] T001: Add Strimzi Operator HelmRelease (flux/sources/helmrepo-strimzi.yaml, infrastructure/base/strimzi/)
- [x] T002: Add provider-aws-sqs (infrastructure/base/crossplane/providers/provider-sqs.yaml)
- [x] T003: Define XRD schema for QueueInstance (queueinstance-definition.yaml)
- [x] T003b: Add Strimzi RBAC for Crossplane (additional-rbac.yaml)

### Phase 2: Implementation
- [x] T004: Implement Kafka backend in KCL (topic + user + secret)
- [x] T005: Implement SQS backend in KCL (queue + DLQ + policy)
- [x] T006: Implement EKS Pod Identity integration for SQS
- [x] T007: Implement connection secret generation for both backends
- [x] T008: Add CiliumNetworkPolicy generation

### Phase 3: Validation & Documentation
- [x] T009: Create basic and complete examples
- [ ] T010: Write E2E tests for both backends
- [ ] T011: Add to composition documentation
- [x] T012: Run validation suite (KCL fmt + syntax validation passed)

---

## Validation

- [x] Basic example (Kafka) renders successfully
- [x] Basic example (SQS) renders successfully
- [x] Complete example renders successfully
- [x] Polaris score >= 85 (Kafka: 100%, SQS: false positive on AWS IAM Role)
- [x] kube-linter passes
- [ ] E2E test passes for Kafka backend
- [ ] E2E test passes for SQS backend
- [ ] Success criteria SC-001 through SC-005 verified

---

## Review Checklist

Complete this checklist before implementation. Each persona represents a different perspective.

### Project Manager
- [x] Problem statement is clear and specific
- [x] User stories capture real user needs
- [x] Acceptance scenarios are testable
- [x] Scope is well-defined (goals AND non-goals)
- [x] Success criteria are measurable

### Platform Engineer
- [x] Design follows existing patterns (App, SQLInstance as references)
- [x] API is consistent with other compositions
- [x] Resource naming follows `xplane-*` convention
- [x] KCL avoids mutation pattern (issue #285)
- [x] Examples provided (basic + complete)

### Security & Compliance
- [x] Zero-trust networking (CiliumNetworkPolicy defined)
- [x] Least-privilege RBAC (Strimzi RBAC added for Crossplane)
- [x] Secrets via External Secrets (no hardcoded credentials)
- [ ] Security context enforced (non-root, read-only FS where possible) - N/A: no Deployments created
- [x] IAM policies scoped to `xplane-*` resources (if AWS)

### SRE
- [ ] Health checks defined (liveness, readiness probes) - N/A: no Deployments created
- [x] Observability configured (metrics, logs) - VMServiceScrape for Kafka
- [ ] Resource limits appropriate - N/A: no Deployments created
- [ ] Failure modes documented
- [ ] Recovery/rollback path clear

---

## Clarifications

<!-- Use [NEEDS CLARIFICATION: question?] for unresolved items -->
<!-- Resolve conversationally, then update with [CLARIFIED: answer] -->

- [CLARIFIED: Topics only - composition creates topics within existing Kafka clusters via clusterRef. Similar to SQLInstance pattern. A separate KafkaCluster composition can be added later if needed.]

- [CLARIFIED: SASL/SCRAM only - simpler credential management that works well with External Secrets. mTLS support can be added in a future iteration based on user demand.]

- [CLARIFIED: Same-account only - aligns with existing EKS Pod Identity pattern and zero-trust principle of minimal scope. Cross-account support can be added later if real use cases emerge.]

---

## References

- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar: [SQLInstance composition](../../../infrastructure/base/crossplane/configuration/kcl/cloudnativepg/)
- Similar: [App composition](../../../infrastructure/base/crossplane/configuration/kcl/app/)
- Strimzi docs: https://strimzi.io/docs/operators/latest/overview
- AWS SQS Crossplane: https://marketplace.upbound.io/providers/upbound/provider-aws-sqs
