// Typed fetch wrappers for the App Wizard backend. Mirrors the endpoints in
// internal/api. 401 (unauthenticated) and 422 (validation failure) are surfaced
// as distinct error subclasses so callers can react differently.
import type {
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

export function openPR(req: PRRequest): Promise<PRResponse> {
  return request<PRResponse>("/api/pr", {
    method: "POST",
    body: JSON.stringify(req),
  });
}

// Full-page redirect to the backend's GitHub OAuth login endpoint.
export function login(): void {
  window.location.href = "/api/auth/login";
}
