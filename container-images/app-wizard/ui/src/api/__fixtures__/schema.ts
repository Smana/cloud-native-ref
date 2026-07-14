import type { SchemaPayload } from "../types";

// Mock SchemaPayload derived from the real App XRD's shape
// (infrastructure/base/crossplane/configuration/app-definition.yaml). Used by
// the renderer during dev and by the unit tests. NOTE: `futureScalarField` is
// intentionally present in jsonSchema but ABSENT from hints.fields — it proves
// SC-002 (a new XRD field appears automatically in the advanced tier with no
// wizard code change).
export const fixtureSchema: SchemaPayload = {
  schemaVersion: "fixture-v1",
  stacks: [
    {
      name: "dev",
      description: "Development stack",
      namespace: "dev-apps",
      ownerTeam: "platform",
    },
    {
      name: "prod",
      description: "Production stack",
      namespace: "prod-apps",
      ownerTeam: "platform",
    },
  ],
  celRules: [
    {
      rule: "!has(self.autoscaling) || !self.autoscaling.enabled || self.autoscaling.minReplicas <= self.autoscaling.maxReplicas",
      message: "autoscaling.minReplicas must be <= maxReplicas",
    },
    {
      rule: "!has(self.route) || !self.route.enabled || has(self.route.hostname)",
      message: "route.hostname is required when route is enabled",
    },
  ],
  jsonSchema: {
    type: "object",
    required: ["image"],
    properties: {
      type: {
        type: "string",
        description: "Workload type",
        enum: ["web", "worker", "cronjob"],
        default: "web",
      },
      image: {
        type: "object",
        description: "Container image",
        required: ["repository"],
        properties: {
          repository: { type: "string", description: "Container image repository" },
          tag: { type: "string", description: "Container image tag", default: "latest" },
          pullPolicy: {
            type: "string",
            description: "Image pull policy",
            enum: ["Always", "Never", "IfNotPresent"],
            default: "IfNotPresent",
          },
        },
      },
      service: {
        type: "object",
        description: "Kubernetes Service configuration",
        properties: {
          port: {
            type: "integer",
            description: "Service port (container port to expose)",
            minimum: 1,
            maximum: 65535,
            default: 8080,
          },
        },
      },
      route: {
        type: "object",
        description: "HTTPRoute configuration for external access",
        properties: {
          enabled: {
            type: "boolean",
            description: "Enable HTTPRoute creation for external access",
            default: false,
          },
          internetFacing: {
            type: "boolean",
            description: "Whether the service is internet-facing",
            default: false,
          },
          hostname: {
            type: "string",
            description: "Hostname without domain suffix (e.g. 'myapp')",
          },
        },
      },
      replicas: {
        type: "integer",
        description: "Number of replicas when autoscaling is disabled",
        minimum: 1,
        default: 1,
      },
      autoscaling: {
        type: "object",
        description: "Horizontal pod autoscaling",
        properties: {
          enabled: {
            type: "boolean",
            description: "Enable horizontal pod autoscaling",
            default: false,
          },
          minReplicas: {
            type: "integer",
            description: "Minimum number of replicas",
            minimum: 1,
            default: 1,
          },
          maxReplicas: {
            type: "integer",
            description: "Maximum number of replicas",
            minimum: 1,
            default: 5,
          },
          targetCPUUtilizationPercentage: {
            type: "integer",
            description: "Target CPU utilization percentage",
            minimum: 1,
            maximum: 100,
            default: 70,
          },
        },
      },
      sqlInstance: {
        type: "object",
        description: "Managed PostgreSQL database",
        properties: {
          enabled: {
            type: "boolean",
            description: "Provision a managed SQL instance",
            default: false,
          },
          engine: {
            type: "string",
            description: "Database engine",
            enum: ["postgres"],
            default: "postgres",
          },
        },
      },
      persistence: {
        type: "object",
        description: "Persistent volume configuration",
        properties: {
          enabled: {
            type: "boolean",
            description: "Enable a persistent volume claim",
            default: false,
          },
          size: {
            type: "string",
            description: "Requested volume size",
            pattern: "^[0-9]+[KMGT]i?$",
            default: "1Gi",
          },
          accessMode: {
            type: "string",
            description: "Volume access mode",
            enum: ["ReadWriteOnce", "ReadWriteMany"],
            default: "ReadWriteOnce",
          },
        },
      },
      env: {
        type: "array",
        description: "Non-sensitive environment variables (literals only)",
        items: {
          type: "object",
          required: ["name"],
          properties: {
            name: { type: "string", description: "Environment variable name" },
            value: { type: "string", description: "Non-sensitive literal value" },
          },
        },
      },
      externalSecrets: {
        type: "array",
        description: "References to AWS Secrets Manager secrets (no values stored)",
        items: {
          type: "object",
          required: ["name", "remoteRef"],
          properties: {
            name: { type: "string", description: "ExternalSecret name / env var" },
            remoteRef: {
              type: "string",
              description: "Path in AWS Secrets Manager",
            },
          },
        },
      },
      sidecars: {
        type: "array",
        description: "Additional sidecar containers",
        items: {
          type: "object",
          properties: {
            name: { type: "string", description: "Sidecar container name" },
            image: { type: "string", description: "Sidecar image" },
          },
        },
      },
      podLabels: {
        type: "object",
        description: "Extra labels applied to pods",
        additionalProperties: { type: "string" },
      },
      // --- SC-002 canary: present in schema, absent from hints below. ---
      futureScalarField: {
        type: "string",
        description: "A brand-new XRD field the wizard has never seen before.",
      },
    },
  },
  hints: {
    groups: [
      { id: "networking", label: "Networking & Exposure", tier: "advanced", order: 1 },
      { id: "scaling", label: "Scaling & Availability", tier: "advanced", order: 2 },
      { id: "data", label: "Data & Storage", tier: "advanced", order: 3 },
      { id: "config", label: "Environment & Secrets", tier: "advanced", order: 4 },
      { id: "expert", label: "Expert", tier: "expert", order: 5 },
    ],
    fields: {
      type: { tier: "basic", label: "Workload type", order: 1 },
      image: { tier: "basic", label: "Image", order: 2, example: "ghcr.io/org/app" },
      service: { tier: "basic", label: "Service", order: 3 },
      route: { tier: "advanced", group: "networking", label: "External route", order: 1 },
      replicas: { tier: "advanced", group: "scaling", label: "Replicas", order: 1 },
      autoscaling: { tier: "advanced", group: "scaling", label: "Autoscaling", order: 2 },
      sqlInstance: { tier: "advanced", group: "data", label: "Managed database", order: 1 },
      persistence: { tier: "advanced", group: "data", label: "Persistent storage", order: 2 },
      env: { tier: "advanced", group: "config", label: "Environment variables", order: 1 },
      externalSecrets: {
        tier: "advanced",
        group: "config",
        label: "Secret references",
        order: 2,
      },
      sidecars: { tier: "expert", group: "expert", label: "Sidecars", order: 1 },
      podLabels: { tier: "expert", group: "expert", label: "Pod labels", order: 2 },
      // futureScalarField intentionally omitted — defaults to advanced tier.
    },
  },
};
