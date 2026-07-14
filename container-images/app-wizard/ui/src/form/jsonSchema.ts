// A pragmatic subset of JSON Schema (draft used by Kubernetes openAPIV3Schema).
// Only the keywords the renderer honours are typed; unknown keywords pass
// through untouched.
export interface JSONSchema {
  type?: "string" | "boolean" | "integer" | "number" | "object" | "array";
  description?: string;
  default?: unknown;
  enum?: unknown[];
  minimum?: number;
  maximum?: number;
  pattern?: string;
  properties?: Record<string, JSONSchema>;
  required?: string[];
  items?: JSONSchema;
  // `true` or a schema → free-form / key-value map object.
  additionalProperties?: boolean | JSONSchema;
}

export function asSchema(v: unknown): JSONSchema {
  return (v ?? {}) as JSONSchema;
}
