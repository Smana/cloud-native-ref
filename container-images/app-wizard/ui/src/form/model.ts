// Pure helpers that turn a SchemaPayload into an ordered, tiered field layout
// and provide immutable get/set on the nested spec object by dot/array path.
import type { FieldHint, GroupHint, SchemaPayload, Tier } from "../api/types";
import { asSchema, type JSONSchema } from "./jsonSchema";

export interface TopField {
  key: string;
  schema: JSONSchema;
  hint: FieldHint; // synthesised default when absent from hints
  order: number;
}

// A field with no hint defaults to the "advanced" tier and is NEVER dropped.
// This is load-bearing for SC-002 (new XRD field appears automatically).
export function hintFor(key: string, hints: SchemaPayload["hints"]): FieldHint {
  return hints.fields[key] ?? { tier: "advanced" };
}

export interface Layout {
  basic: TopField[];
  // Advanced/expert fields organised by group, groups themselves ordered.
  groups: Array<{ group: GroupHint; fields: TopField[] }>;
  // Advanced/expert fields whose hint.group is unknown/missing land here so they
  // are still rendered (never dropped).
  ungrouped: TopField[];
}

const FALLBACK_GROUP: GroupHint = {
  id: "__more__",
  label: "More options",
  tier: "advanced",
  order: 999,
};

export function buildLayout(payload: SchemaPayload): Layout {
  const props = asSchema(payload.jsonSchema).properties ?? {};
  const all: TopField[] = Object.entries(props).map(([key, schema]) => {
    const hint = hintFor(key, payload.hints);
    return { key, schema, hint, order: hint.order ?? 500 };
  });

  const byOrder = (a: TopField, b: TopField) =>
    a.order - b.order || a.key.localeCompare(b.key);

  const basic = all.filter((f) => f.hint.tier === "basic").sort(byOrder);
  const rest = all.filter((f) => f.hint.tier !== "basic");

  const groupsById = new Map<string, GroupHint>();
  for (const g of payload.hints.groups) groupsById.set(g.id, g);

  const grouped = new Map<string, TopField[]>();
  const ungrouped: TopField[] = [];
  for (const f of rest) {
    const gid = f.hint.group;
    if (gid && groupsById.has(gid)) {
      const arr = grouped.get(gid) ?? [];
      arr.push(f);
      grouped.set(gid, arr);
    } else {
      ungrouped.push(f);
    }
  }

  const groups = [...grouped.entries()]
    .map(([gid, fields]) => ({
      group: groupsById.get(gid)!,
      fields: fields.sort(byOrder),
    }))
    .sort((a, b) => a.group.order - b.group.order);

  return { basic, groups, ungrouped: ungrouped.sort(byOrder) };
}

export const fallbackGroup = FALLBACK_GROUP;

// --- Immutable nested get/set by path segments -----------------------------

export type PathSeg = string | number;

export function getAt(obj: unknown, path: PathSeg[]): unknown {
  let cur: unknown = obj;
  for (const seg of path) {
    if (cur == null) return undefined;
    cur = (cur as Record<PathSeg, unknown>)[seg];
  }
  return cur;
}

export function setAt(obj: unknown, path: PathSeg[], value: unknown): unknown {
  if (path.length === 0) return value;
  const [head, ...tail] = path;
  if (typeof head === "number") {
    const arr = Array.isArray(obj) ? [...obj] : [];
    arr[head] = setAt(arr[head], tail, value);
    return arr;
  }
  const base = obj && typeof obj === "object" ? { ...(obj as object) } : {};
  (base as Record<string, unknown>)[head] = setAt(
    (base as Record<string, unknown>)[head],
    tail,
    value,
  );
  return base;
}

export function deleteAt(obj: unknown, path: PathSeg[]): unknown {
  if (path.length === 0) return undefined;
  const [head, ...tail] = path;
  if (tail.length === 0) {
    if (typeof head === "number" && Array.isArray(obj)) {
      return obj.filter((_, i) => i !== head);
    }
    if (obj && typeof obj === "object") {
      const copy = { ...(obj as Record<string, unknown>) };
      delete copy[head as string];
      return copy;
    }
    return obj;
  }
  const child = getAt(obj, [head]);
  return setAt(obj, [head], deleteAt(child, tail));
}

export function pathToString(path: PathSeg[]): string {
  return path
    .map((s) => (typeof s === "number" ? `[${s}]` : s))
    .join(".")
    .replace(/\.\[/g, "[");
}

// Recursively strip undefined / empty-object / empty-array so the YAML pane and
// claim stay tidy.
export function prune(value: unknown): unknown {
  if (Array.isArray(value)) {
    const arr = value.map(prune).filter((v) => v !== undefined);
    // Drop empty arrays entirely so defaulted/untouched list fields (e.g.
    // route.rules) never appear in the generated claim.
    return arr.length ? arr : undefined;
  }
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const pv = prune(v);
      if (pv === undefined) continue;
      if (pv && typeof pv === "object" && !Array.isArray(pv) && Object.keys(pv).length === 0)
        continue;
      out[k] = pv;
    }
    return out;
  }
  if (value === "" || value === undefined || value === null) return undefined;
  return value;
}

// Deep-copy `spec` and fill in schema `default` values for absent keys,
// recursing into nested object `properties` (FIX 4 — "Show defaults" view).
// Pure: never mutates its inputs. Only fills values that have an explicit
// schema default — no values are invented for defaultless fields.
export function applyDefaults(spec: unknown, jsonSchema: unknown): unknown {
  const schema = asSchema(jsonSchema);

  if (schema.type === "object" || schema.properties) {
    const src =
      spec && typeof spec === "object" && !Array.isArray(spec)
        ? (spec as Record<string, unknown>)
        : {};
    const out: Record<string, unknown> = {};
    // Preserve user-provided keys (deep copy) even if not in the schema.
    for (const [k, v] of Object.entries(src)) {
      out[k] = deepCopy(v);
    }
    for (const [k, child] of Object.entries(schema.properties ?? {})) {
      const childSchema = asSchema(child);
      const present = k in src;
      if (present) {
        out[k] = applyDefaults(src[k], childSchema);
      } else if (childSchema.default !== undefined) {
        out[k] = deepCopy(childSchema.default);
      } else if (childSchema.type === "object" || childSchema.properties) {
        // Recurse to surface nested defaults even when the parent is absent.
        const nested = applyDefaults(undefined, childSchema);
        if (nested && Object.keys(nested as object).length > 0) out[k] = nested;
      }
    }
    return out;
  }

  return deepCopy(spec);
}

function deepCopy(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(deepCopy);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = deepCopy(v);
    }
    return out;
  }
  return value;
}

// Tier badge helper.
export function tierBadgeVariant(tier: Tier): "secondary" | "outline" | "default" {
  if (tier === "expert") return "outline";
  if (tier === "advanced") return "secondary";
  return "default";
}
