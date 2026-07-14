// Bespoke "Image" field (FIX 2+3). Replaces the generic image object on the
// basic screen with a single guided text input (registry/name:tag), parsing the
// string back into spec.image.repository + spec.image.tag. Pull policy moves to
// an inner "Advanced image options" collapsible, still rendered schema-driven via
// the generic Field so its enum/default keep coming from the XRD.
import type { FieldError, UIHints } from "../api/types";
import { Collapsible } from "../components/ui/collapsible";
import { Input } from "../components/ui/input";
import { Field } from "./Field";
import { asSchema, type JSONSchema } from "./jsonSchema";
import { getAt, setAt } from "./model";

interface Props {
  // The `image` object schema from the XRD (has repository/tag/pullPolicy).
  schema: JSONSchema;
  spec: unknown;
  onChange: (next: unknown) => void;
  errors: FieldError[];
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

export function ImageField({ schema, spec, onChange, errors, label, hints }: Props) {
  const s = asSchema(schema);
  const repository = getAt(spec, ["image", "repository"]) as string | undefined;
  const tag = getAt(spec, ["image", "tag"]) as string | undefined;
  const display = (repository ?? "") + (tag ? `:${tag}` : "");

  const onImageChange = (raw: string) => {
    const { repository: repo, tag: t } = parseImage(raw);
    let next = setAt(spec, ["image", "repository"], repo);
    next = setAt(next, ["image", "tag"], t);
    onChange(next);
  };

  const pullPolicySchema = s.properties?.pullPolicy;
  const pullPolicyHint = hints?.fields["image.pullPolicy"];

  return (
    <div className="space-y-2">
      <div className="space-y-1">
        <Label id="f-image">{label ?? "Image"}</Label>
        <Input
          id="f-image"
          placeholder="ghcr.io/acme/api:1.2.3"
          value={display}
          onChange={(e) => onImageChange(e.target.value)}
        />
        <p className="text-xs text-muted-foreground">
          Container image as registry/name:tag (e.g. ghcr.io/acme/api:1.2.3).
          Registry optional (defaults to Docker Hub). Digests (@sha256:…) not yet
          supported.
        </p>
      </div>

      {pullPolicySchema && (
        <Collapsible title="Advanced image options">
          <Field
            schema={asSchema(pullPolicySchema)}
            path={["image", "pullPolicy"]}
            spec={spec}
            onChange={onChange}
            errors={errors}
            label={pullPolicyHint?.label ?? "Pull policy"}
            help={pullPolicyHint?.help ?? asSchema(pullPolicySchema).description}
            hints={hints}
          />
        </Collapsible>
      )}
    </div>
  );
}
