// Recursive, schema-driven field widget. Given a JSONSchema node + its path in
// the spec, it renders the right control and recurses for objects/arrays. It is
// entirely generic — no field is hardcoded (FR-001 / SC-002).
import type { FieldError } from "../api/types";
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

  // enum → select
  if (s.enum && s.enum.length > 0) {
    return (
      <div className="space-y-1">
        {label && <Label id={id}>{label}</Label>}
        <Select
          id={id}
          value={String(value ?? s.default ?? "")}
          onChange={(e) => onChange(setAt(spec, path, e.target.value || undefined))}
        >
          <option value="">— select —</option>
          {s.enum.map((opt) => (
            <option key={String(opt)} value={String(opt)}>
              {String(opt)}
            </option>
          ))}
        </Select>
        <Help text={help_} />
        {errorNode}
      </div>
    );
  }

  switch (s.type) {
    case "boolean":
      return (
        <div className="flex items-start justify-between gap-3">
          <div className="space-y-0.5">
            {label && <Label id={id}>{label}</Label>}
            <Help text={help_} />
          </div>
          <Switch
            id={id}
            checked={Boolean(value ?? s.default ?? false)}
            onCheckedChange={(v) => onChange(setAt(spec, path, v))}
          />
        </div>
      );

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
      // nested group of properties
      return (
        <fieldset className="space-y-3 rounded-md border border-border/60 p-3">
          {label && <legend className="px-1 text-sm font-medium">{label}</legend>}
          <Help text={help_} />
          {Object.entries(s.properties ?? {}).map(([k, child]) => {
            const childSchema = asSchema(child);
            return (
              <Field
                key={k}
                schema={childSchema}
                path={[...path, k]}
                spec={spec}
                onChange={onChange}
                errors={errors}
                label={humanize(k)}
              />
            );
          })}
          {errorNode}
        </fieldset>
      );

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
}: {
  schema: JSONSchema;
  path: PathSeg[];
  spec: unknown;
  onChange: (next: unknown) => void;
  errors: FieldError[];
  label?: string;
  help?: string;
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
