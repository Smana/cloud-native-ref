// Wire contract mirror of internal/api/types.go — KEEP IN SYNC with the Go
// source of truth. SPEC-008 Phase 1.

export interface SchemaPayload {
  jsonSchema: Record<string, unknown>;
  celRules: CELRule[];
  hints: UIHints;
  stacks: Stack[];
  schemaVersion: string;
}

export interface CELRule {
  rule: string;
  message: string;
}

export interface UIHints {
  fields: Record<string, FieldHint>;
  groups: GroupHint[];
}

export type Tier = "basic" | "advanced" | "expert";

export interface FieldHint {
  tier: Tier;
  group?: string;
  label?: string;
  help?: string;
  example?: string;
  order?: number;
}

export interface GroupHint {
  id: string;
  label: string;
  tier: Tier;
  order: number;
}

export interface Stack {
  name: string;
  description: string;
  namespace: string;
  ownerTeam: string;
}

export interface ValidateRequest {
  spec: Record<string, unknown>;
}

export interface ValidateResponse {
  valid: boolean;
  schemaErrors: FieldError[];
  celViolations: CELRule[];
  secretFindings: SecretFinding[];
}

export interface FieldError {
  path: string;
  message: string;
}

export interface SecretFinding {
  path: string;
  reason: string;
}

export interface RenderPreviewRequest {
  spec: Record<string, unknown>;
  name: string;
  stack: string;
}

export interface RenderPreviewResponse {
  ok: boolean;
  resources: RenderedResource[];
  error?: string;
}

export interface RenderedResource {
  kind: string;
  name: string;
  role?: string;
  // Full rendered manifest — the effective spec after the composition applies its
  // defaults (resources/limits, probes, securityContext, …). Shown expandable.
  yaml?: string;
}

export type PRMode = "create" | "update" | "delete";

export interface PRRequest {
  stack: string;
  appName: string;
  mode?: PRMode; // default "create"
  spec: Record<string, unknown>;
  description: string;
}

export interface PRResponse {
  url: string;
  number: number;
  branch: string;
}

// App inventory entry (GET /api/apps, Phase 2).
export interface AppSummary {
  stack: string;
  name: string;
  namespace: string;
  image: string;
  type: string; // web | worker | cron ("" ⇒ web)
}

// A single app loaded for editing (GET /api/apps/{stack}/{name}, Phase 2).
export interface AppDetail {
  stack: string;
  name: string;
  spec: Record<string, unknown>;
  rawYaml: string;
}

// LLM assists (Phase 3). Optional — hidden when unavailable.
export interface AssistStatus {
  available: boolean;
}

export interface AssistPrefillResponse {
  spec: Record<string, unknown>;
  keys: string[]; // top-level keys the model set (for "AI-suggested" badges)
}

export interface AssistPoliciesResponse {
  ingress: unknown[];
  egress: unknown[];
}

export interface User {
  login: string;
  avatarUrl: string;
  name: string;
  githubLinked: boolean; // zitadel mode: has the user connected a GitHub token for PRs
}
