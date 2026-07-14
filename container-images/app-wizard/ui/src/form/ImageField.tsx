// Bespoke "Image" field. Replaces the generic image object on the basic screen
// with a single guided text input (registry/name:tag), parsing the string back
// into spec.image.repository + spec.image.tag. Pull policy is an inline radio
// group (single enum, values/default sourced from the XRD schema).
import { useEffect, useState } from "react";
import type { UIHints } from "../api/types";
import { Input } from "../components/ui/input";
import { asSchema, type JSONSchema } from "./jsonSchema";
import { getAt, setAt } from "./model";

interface Props {
  // The `image` object schema from the XRD (has repository/tag/pullPolicy).
  schema: JSONSchema;
  spec: unknown;
  onChange: (next: unknown) => void;
  label?: string;
  hints?: UIHints;
}

function Label({ id, children }: { id?: string; children: React.ReactNode }) {
  return (
    <label htmlFor={id} className="text-sm font-medium">
      {children}
    </label>
  );
}

// Split "registry/name:tag" into repository + tag. The tag separator is the FIRST
// ":" that appears AFTER the last "/", so a "registry:port" prefix is never
// mistaken for a tag. Returns tag=undefined when no such ":" is present so it's
// pruned rather than written as an empty string.
export function parseImage(raw: string): { repository?: string; tag?: string } {
  const value = raw.trim();
  if (value === "") return { repository: undefined, tag: undefined };
  const lastSlash = value.lastIndexOf("/");
  const colon = value.indexOf(":", lastSlash + 1);
  if (colon === -1) return { repository: value, tag: undefined };
  const repository = value.slice(0, colon);
  const tag = value.slice(colon + 1);
  return { repository: repository || undefined, tag: tag || undefined };
}

export function ImageField({ schema, spec, onChange, label }: Props) {
  const s = asSchema(schema);
  const repository = getAt(spec, ["image", "repository"]) as string | undefined;
  const tag = getAt(spec, ["image", "tag"]) as string | undefined;

  // Local text is the source of truth for the input, so a trailing ":" (colon
  // typed before the tag) is never stripped by reconstruction. Resync only when
  // the spec represents a DIFFERENT image than what is currently typed (external
  // load/reset), never on our own keystrokes.
  const derived = (repository ?? "") + (tag ? `:${tag}` : "");
  const [text, setText] = useState(derived);
  useEffect(() => {
    const cur = parseImage(text);
    if (cur.repository !== repository || cur.tag !== tag) setText(derived);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [repository, tag]);

  const onImageChange = (raw: string) => {
    setText(raw);
    const { repository: repo, tag: t } = parseImage(raw);
    let next = setAt(spec, ["image", "repository"], repo);
    next = setAt(next, ["image", "tag"], t);
    onChange(next);
  };

  // Pull policy: inline radio group. Enum values + default come from the XRD
  // schema (still schema-driven, not hardcoded).
  const ppSchema = s.properties?.pullPolicy ? asSchema(s.properties.pullPolicy) : undefined;
  const ppOptions = (ppSchema?.enum as string[] | undefined) ?? [];
  const ppValue = getAt(spec, ["image", "pullPolicy"]) as string | undefined;
  const ppDefault = ppSchema?.default as string | undefined;
  const setPullPolicy = (v: string | undefined) =>
    onChange(setAt(spec, ["image", "pullPolicy"], v));

  return (
    <div className="space-y-3">
      <div className="space-y-1">
        <Label id="f-image">{label ?? "Image"}</Label>
        <Input
          id="f-image"
          placeholder="ghcr.io/acme/api:1.2.3"
          value={text}
          onChange={(e) => onImageChange(e.target.value)}
        />
        <p className="text-xs text-muted-foreground">
          Container image as registry/name:tag (e.g. ghcr.io/acme/api:1.2.3). Registry
          optional (defaults to Docker Hub). Digests (@sha256:…) not yet supported.
        </p>
      </div>

      {ppOptions.length > 0 && (
        <div className="space-y-1">
          <Label>Pull policy</Label>
          <div className="flex flex-wrap gap-4">
            {ppOptions.map((opt) => (
              <label key={opt} className="flex items-center gap-1.5 text-sm">
                <input
                  type="radio"
                  name="image-pullPolicy"
                  className="accent-primary"
                  checked={ppValue === opt}
                  onChange={() => setPullPolicy(opt)}
                />
                {opt}
              </label>
            ))}
          </div>
          <p className="text-xs text-muted-foreground">
            {ppDefault ? `Defaults to ${ppDefault}.` : "Image pull policy."}
            {ppValue && (
              <>
                {" "}
                <button
                  type="button"
                  className="text-primary underline"
                  onClick={() => setPullPolicy(undefined)}
                >
                  reset to default
                </button>
              </>
            )}
          </p>
        </div>
      )}
    </div>
  );
}
