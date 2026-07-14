// Client-side name validation. DNS-1123 label rules, mirrors what the API
// server / Kubernetes enforces for metadata.name.
const DNS1123 = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;

export function validateAppName(name: string): string | null {
  if (!name) return "App name is required";
  if (name.length > 63) return "App name must be 63 characters or fewer";
  if (!DNS1123.test(name))
    return "Must be a DNS-1123 label: lowercase alphanumeric or '-', starting/ending alphanumeric";
  return null;
}

// Match a FieldError.path against a field's dot/bracket path. The backend may
// emit either "spec.image.repository" or "image.repository"; accept both.
export function errorMatchesPath(errPath: string, fieldPath: string): boolean {
  const norm = (p: string) => p.replace(/^spec\./, "").replace(/\[(\d+)\]/g, ".$1");
  return norm(errPath) === norm(fieldPath);
}
