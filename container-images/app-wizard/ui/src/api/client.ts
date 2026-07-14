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

// Thrown by openPR when the backend returns HTTP 428 (zitadel mode): the user is
// authenticated via Zitadel but has NOT yet linked a GitHub token, so no PR can
// be opened as them. Carries the link URL to send the user through the GitHub
// account-link flow (from the response `Location` header, or the default).
export class GitHubLinkRequiredError extends Error {
  linkUrl: string;
  constructor(linkUrl = githubLinkUrl(), message = "GitHub account not linked") {
    super(message);
    this.name = "GitHubLinkRequiredError";
    this.linkUrl = linkUrl;
  }
}

// The backend endpoint that starts the GitHub account-link OAuth flow (zitadel
// mode). Full-page navigation, like login().
export function githubLinkUrl(): string {
  return "/api/auth/github/link";
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
//
// zitadel mode: if the user hasn't linked GitHub, the backend answers HTTP 428
// (Precondition Required) with a `Location` header pointing at the link flow.
// We surface that as a distinct GitHubLinkRequiredError so the UI can offer the
// "Connect GitHub" action instead of showing a generic failure.
export async function openPR(req: PRRequest): Promise<PRResponse> {
  const res = await fetch("/api/pr", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ mode: "create", ...req }),
  });

  if (res.status === 428) {
    const linkUrl = res.headers.get("Location") || githubLinkUrl();
    const body = await parseJson<{ error?: string }>(res);
    throw new GitHubLinkRequiredError(linkUrl, body.error || "GitHub account not linked");
  }
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
  return parseJson<PRResponse>(res);
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

// Full-page redirect to the backend's login endpoint. Same path for both auth
// modes: github (GitHub OAuth) and zitadel (Zitadel OIDC).
export function login(): void {
  window.location.href = "/api/auth/login";
}

// Full-page redirect to the GitHub account-link flow (zitadel mode): a Zitadel-
// authenticated user links their GitHub identity so PRs open as them.
export function linkGitHub(): void {
  window.location.href = githubLinkUrl();
}
