// Typed fetch wrappers for the App Wizard backend. Mirrors the endpoints in
// internal/api. 401 (unauthenticated) and 422 (validation failure) are surfaced
// as distinct error subclasses so callers can react differently.
import type {
  AppDetail,
  AppSummary,
  AssistPoliciesResponse,
  AssistPrefillResponse,
  AssistStatus,
  PRRequest,
  PRResponse,
  RenderPreviewRequest,
  RenderPreviewResponse,
  SchemaPayload,
  User,
  ValidateRequest,
  ValidateResponse,
} from "./types";

export class UnauthorizedError extends Error {
  constructor(message = "Not authenticated") {
    super(message);
    this.name = "UnauthorizedError";
  }
}

// Carries the parsed validation body (schema/CEL/secret findings) from a 422.
export class ValidationError extends Error {
  body: ValidateResponse | { error?: string };
  constructor(body: ValidateResponse | { error?: string }, message = "Validation failed") {
    super(message);
    this.name = "ValidationError";
    this.body = body;
  }
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

async function parseJson<T>(res: Response): Promise<T> {
  const text = await res.text();
  return text ? (JSON.parse(text) as T) : ({} as T);
}

async function request<T>(input: string, init?: RequestInit): Promise<T> {
  const res = await fetch(input, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init?.body ? { "Content-Type": "application/json" } : {}),
      ...init?.headers,
    },
  });

  if (res.status === 401) {
    throw new UnauthorizedError();
  }
  if (res.status === 422) {
    const body = await parseJson<ValidateResponse | { error?: string }>(res);
    throw new ValidationError(body);
  }
  if (!res.ok) {
    const body = await parseJson<{ error?: string }>(res);
    throw new ApiError(res.status, body.error || `Request failed (${res.status})`);
  }
  return parseJson<T>(res);
}

export function getSchema(): Promise<SchemaPayload> {
  return request<SchemaPayload>("/api/schema");
}

// GET /api/me — throws UnauthorizedError when the session is missing.
export function getMe(): Promise<User> {
  return request<User>("/api/me");
}

export function validate(req: ValidateRequest): Promise<ValidateResponse> {
  return request<ValidateResponse>("/api/validate", {
    method: "POST",
    body: JSON.stringify(req),
  });
}

export function renderPreview(req: RenderPreviewRequest): Promise<RenderPreviewResponse> {
  return request<RenderPreviewResponse>("/api/render-preview", {
    method: "POST",
    body: JSON.stringify(req),
  });
}

// GET /api/apps — day-2 inventory of apps declared across all stacks.
export function listApps(): Promise<AppSummary[]> {
  return request<AppSummary[]>("/api/apps");
}

// GET /api/apps/{stack}/{name} — a single app loaded for editing.
export function getApp(stack: string, name: string): Promise<AppDetail> {
  return request<AppDetail>(
    `/api/apps/${encodeURIComponent(stack)}/${encodeURIComponent(name)}`,
  );
}

// POST /api/pr — opens a create/update/delete PR. `mode` defaults to "create"
// server-side when omitted; we send it explicitly.
export function openPR(req: PRRequest): Promise<PRResponse> {
  return request<PRResponse>("/api/pr", {
    method: "POST",
    body: JSON.stringify({ mode: "create", ...req }),
  });
}

// --- LLM assists (Phase 3) -------------------------------------------------
// All optional. The form must work fully when assists are unavailable (FR-011),
// so a 503 (or any failure) is surfaced as "unavailable" rather than an error.

// GET /api/assist/status — is the assist backend configured/reachable?
// Never throws for the availability probe: any failure ⇒ { available: false }.
export function assistStatus(): Promise<AssistStatus> {
  return request<AssistStatus>("/api/assist/status").catch(() => ({ available: false }));
}

// POST /api/assist/prefill — describe-to-spec. 503 ⇒ ApiError(503); callers
// should treat that as "assist unavailable" and keep the form usable.
export function assistPrefill(description: string): Promise<AssistPrefillResponse> {
  return request<AssistPrefillResponse>("/api/assist/prefill", {
    method: "POST",
    body: JSON.stringify({ description }),
  });
}

// POST /api/assist/policies — describe-to-network-policies. 503 ⇒ ApiError(503).
export function assistPolicies(description: string): Promise<AssistPoliciesResponse> {
  return request<AssistPoliciesResponse>("/api/assist/policies", {
    method: "POST",
    body: JSON.stringify({ description }),
  });
}

// Full-page redirect to the backend's GitHub OAuth login endpoint.
export function login(): void {
  window.location.href = "/api/auth/login";
}
