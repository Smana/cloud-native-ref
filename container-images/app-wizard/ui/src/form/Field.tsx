// Recursive, schema-driven field widget. Given a JSONSchema node + its path in
// the spec, it renders the right control and recurses for objects/arrays. It is
// entirely generic — no field is hardcoded (FR-001 / SC-002).
import type { FieldError, UIHints } from "../api/types";
import { Alert, AlertDescription } from "../components/ui/alert";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Input, Textarea } from "../components/ui/input";
import { Select } from "../components/ui/select";
import { Switch } from "../components/ui/collapsible";
import { asSchema, type JSONSchema } from "./jsonSchema";
import { deleteAt, getAt, pathToString, setAt, type PathSeg } from "./model";
import { errorMatchesPath } from "./validation";

interface FieldProps {
  schema: JSONSchema;
  path: PathSeg[];
  spec: unknown;
  onChange: (next: unknown) => void;
  errors: FieldError[];
  label?: string;
  help?: string;
  placeholder?: string;
  labelledById?: string;
  // Presentation overlay + basic-screen filtering (FIX 3). When basicScreen is
  // true, object children are limited to basic-tier or required keys; when
  // false/undefined, ALL children render (advanced/expert groups).
  hints?: UIHints;
  basicScreen?: boolean;
}

function Label({ id, children }: { id?: string; children: React.ReactNode }) {
  return (
    <label htmlFor={id} className="text-sm font-medium">
      {children}
    </label>
  );
}

function Help({ text }: { text?: string }) {
  if (!text) return null;
  return <p className="text-xs text-muted-foreground">{text}</p>;
}

function fieldErrors(errors: FieldError[], path: PathSeg[]): FieldError[] {
  const s = pathToString(path);
  return errors.filter((e) => errorMatchesPath(e.path, s));
}

function humanize(key: string): string {
  return key
    .replace(/([A-Z])/g, " $1")
    .replace(/^./, (c) => c.toUpperCase())
    .trim();
}

export function Field({
  schema,
  path,
  spec,
  onChange,
  errors,
  label,
  help,
  placeholder,
  labelledById,
  hints,
  basicScreen,
}: FieldProps) {
  const s = asSchema(schema);
  const value = getAt(spec, path);
  const id = labelledById ?? `f-${pathToString(path)}`;
  const errs = fieldErrors(errors, path);
  const help_ = help ?? s.description;

  const errorNode =
    errs.length > 0 ? (
      <ul className="text-xs text-destructive">
        {errs.map((e, i) => (
          <li key={i}>{e.message}</li>
        ))}
      </ul>
    ) : null;

  // enum → select. Do NOT pre-select the schema default: an unset field shows the
  // "— select —" option so the form never looks pre-filled (FIX 1). When unset and
  // a default exists, surface it in the help text instead of writing it to state.
  if (s.enum && s.enum.length > 0) {
    const isUnset = value === undefined || value === null || value === "";
    const enumHelp =
      isUnset && s.default != null
        ? [help_, `Default: ${String(s.default)}`].filter(Boolean).join(" ")
        : help_;
    return (
      <div className="space-y-1">
        {label && <Label id={id}>{label}</Label>}
        <Select
          id={id}
          value={String(value ?? "")}
          onChange={(e) => onChange(setAt(spec, path, e.target.value || undefined))}
        >
          <option value="">— select —</option>
          {s.enum.map((opt) => (
            <option key={String(opt)} value={String(opt)}>
              {String(opt)}
            </option>
          ))}
        </Select>
        <Help text={enumHelp} />
        {errorNode}
      </div>
    );
  }

  switch (s.type) {
    case "boolean": {
      const boolChecked = Boolean(value ?? s.default ?? false);
      // Generic public-exposure guardrail: any boolean whose path ends with
      // `internetFacing` shows a warning when toggled ON (FIX 2).
      const isInternetFacing = path[path.length - 1] === "internetFacing";
      return (
        <div className="space-y-2">
          <div className="flex items-start justify-between gap-3">
            <div className="space-y-0.5">
              {label && <Label id={id}>{label}</Label>}
              <Help text={help_} />
            </div>
            <Switch
              id={id}
              checked={boolChecked}
              onCheckedChange={(v) => onChange(setAt(spec, path, v))}
            />
          </div>
          {isInternetFacing && boolChecked && (
            <Alert variant="warning">
              <AlertDescription>
                ⚠ Public exposure — this serves the app on the public internet
                (…cloud.ogenki.io). Use a private (Tailscale) route unless public
                access is required.
              </AlertDescription>
            </Alert>
          )}
          {errorNode}
        </div>
      );
    }

    case "integer":
    case "number":
      return (
        <div className="space-y-1">
          {label && <Label id={id}>{label}</Label>}
          <Input
            id={id}
            type="number"
            inputMode="numeric"
            min={s.minimum}
            max={s.maximum}
            placeholder={placeholder ?? (s.default != null ? String(s.default) : undefined)}
            value={value === undefined || value === null ? "" : String(value)}
            onChange={(e) => {
              const raw = e.target.value;
              onChange(setAt(spec, path, raw === "" ? undefined : Number(raw)));
            }}
          />
          <Help text={help_} />
          {errorNode}
        </div>
      );

    case "array":
      return (
        <ArrayField
          schema={s}
          path={path}
          spec={spec}
          onChange={onChange}
          errors={errors}
          label={label}
          help={help_}
          hints={hints}
        />
      );

    case "object":
      // object with additionalProperties → key/value editor
      if (
        (!s.properties || Object.keys(s.properties).length === 0) &&
        s.additionalProperties
      ) {
        return (
          <KeyValueField
            path={path}
            spec={spec}
            onChange={onChange}
            label={label}
            help={help_}
          />
        );
      }
      // nested group of properties. Children are ordered by their hint.order
      // (the backend serializes Go maps alphabetically, so insertion order is
      // NOT meaningful) and — on the basic screen only — filtered to basic-tier
      // or required keys (FIX 3).
      {
        const required = new Set(s.required ?? []);
        const children = Object.entries(s.properties ?? {})
          .map(([k, child]) => {
            const hintKey = [...path, k].join(".");
            const hint = hints?.fields[hintKey];
            return { k, child: asSchema(child), hint };
          })
          .filter(({ k, hint }) => {
            if (!basicScreen) return true; // advanced/expert: render everything
            return hint?.tier === "basic" || required.has(k);
          })
          .sort(
            (a, b) =>
              (a.hint?.order ?? 500) - (b.hint?.order ?? 500) ||
              a.k.localeCompare(b.k),
          );
        return (
          <fieldset className="space-y-3 rounded-md border border-border/60 p-3">
            {label && <legend className="px-1 text-sm font-medium">{label}</legend>}
            <Help text={help_} />
            {children.map(({ k, child, hint }) => (
              <Field
                key={k}
                schema={child}
                path={[...path, k]}
                spec={spec}
                onChange={onChange}
                errors={errors}
                label={hint?.label ?? humanize(k)}
                help={hint?.help ?? child.description}
                placeholder={hint?.example}
                hints={hints}
                basicScreen={basicScreen}
              />
            ))}
            {errorNode}
          </fieldset>
        );
      }

    default: {
      // string (with pattern validation) — textarea for long content fields.
      const isMultiline = /content|description|body/i.test(pathToString(path));
      const commonProps = {
        id,
        value: value === undefined || value === null ? "" : String(value),
        placeholder,
        onChange: (
          e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
        ) => onChange(setAt(spec, path, e.target.value || undefined)),
      };
      const patternInvalid =
        s.pattern && value != null && value !== "" && !new RegExp(s.pattern).test(String(value));
      return (
        <div className="space-y-1">
          {label && <Label id={id}>{label}</Label>}
          {isMultiline ? (
            <Textarea {...commonProps} />
          ) : (
            <Input {...commonProps} pattern={s.pattern} />
          )}
          <Help text={help_} />
          {patternInvalid && (
            <p className="text-xs text-destructive">Value must match pattern {s.pattern}</p>
          )}
          {errorNode}
        </div>
      );
    }
  }
}

function ArrayField({
  schema,
  path,
  spec,
  onChange,
  errors,
  label,
  help,
  hints,
}: {
  schema: JSONSchema;
  path: PathSeg[];
  spec: unknown;
  onChange: (next: unknown) => void;
  errors: FieldError[];
  label?: string;
  help?: string;
  hints?: UIHints;
}) {
  const item = asSchema(schema.items);
  const arr = (getAt(spec, path) as unknown[] | undefined) ?? [];
  const emptyItem = () => (item.type === "object" ? {} : undefined);
  return (
    <div className="space-y-2">
      {label && <Label>{label}</Label>}
      <Help text={help} />
      <div className="space-y-3">
        {arr.map((_, i) => (
          <div key={i} className="rounded-md border border-border/60 p-3">
            <div className="mb-2 flex items-center justify-between">
              <Badge variant="secondary">#{i + 1}</Badge>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                onClick={() => onChange(deleteAt(spec, [...path, i]))}
              >
                Remove
              </Button>
            </div>
            <Field
              schema={item}
              path={[...path, i]}
              spec={spec}
              onChange={onChange}
              errors={errors}
              hints={hints}
            />
          </div>
        ))}
      </div>
      <Button
        type="button"
        size="sm"
        variant="outline"
        onClick={() => onChange(setAt(spec, [...path, arr.length], emptyItem()))}
      >
        + Add item
      </Button>
    </div>
  );
}

function KeyValueField({
  path,
  spec,
  onChange,
  label,
  help,
}: {
  path: PathSeg[];
  spec: unknown;
  onChange: (next: unknown) => void;
  label?: string;
  help?: string;
}) {
  const map = (getAt(spec, path) as Record<string, string> | undefined) ?? {};
  const entries = Object.entries(map);
  const setEntries = (next: [string, string][]) => {
    const obj: Record<string, string> = {};
    for (const [k, v] of next) if (k) obj[k] = v;
    onChange(setAt(spec, path, Object.keys(obj).length ? obj : undefined));
  };
  return (
    <div className="space-y-2">
      {label && <Label>{label}</Label>}
      <Help text={help} />
      {entries.map(([k, v], i) => (
        <div key={i} className="flex gap-2">
          <Input
            placeholder="key"
            value={k}
            onChange={(e) => {
              const next = [...entries] as [string, string][];
              next[i] = [e.target.value, v];
              setEntries(next);
            }}
          />
          <Input
            placeholder="value"
            value={v}
            onChange={(e) => {
              const next = [...entries] as [string, string][];
              next[i] = [k, e.target.value];
              setEntries(next);
            }}
          />
          <Button
            type="button"
            size="sm"
            variant="ghost"
            onClick={() => setEntries(entries.filter((_, j) => j !== i) as [string, string][])}
          >
            ✕
          </Button>
        </div>
      ))}
      <Button
        type="button"
        size="sm"
        variant="outline"
        onClick={() => setEntries([...entries, ["", ""]] as [string, string][])}
      >
        + Add pair
      </Button>
    </div>
  );
}
