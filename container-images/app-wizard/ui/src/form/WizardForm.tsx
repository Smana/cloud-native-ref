// The whole product: a schema-driven create form with basic tier (≤8 inputs),
// expandable advanced/expert groups, live validation, a live YAML pane, render
// preview and PR submission.
import { useEffect, useMemo, useState } from "react";
import type {
  PRResponse,
  RenderPreviewResponse,
  SchemaPayload,
  User,
  ValidateResponse,
} from "../api/types";
import * as api from "../api/client";
import { ValidationError } from "../api/client";
import { Alert, AlertDescription, AlertTitle } from "../components/ui/alert";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Collapsible } from "../components/ui/collapsible";
import { Input, Textarea } from "../components/ui/input";
import { Select } from "../components/ui/select";
import { Field } from "./Field";
import { ImageField } from "./ImageField";
import { SecretsEditor } from "./SecretsEditor";
import { buildLayout, tierBadgeVariant, type TopField } from "./model";
import { claimToYaml } from "./claim";
import { useDebounced } from "./useDebounced";
import { validateAppName } from "./validation";

const EMPTY_VALIDATION: ValidateResponse = {
  valid: true,
  schemaErrors: [],
  celViolations: [],
  secretFindings: [],
};

// These keys are rendered by the bespoke SecretsEditor, not the generic widget.
const SECRET_KEYS = new Set(["env", "externalSecrets"]);

interface Props {
  schema: SchemaPayload;
  user: User;
}

export function WizardForm({ schema, user }: Props) {
  const layout = useMemo(() => buildLayout(schema), [schema]);

  const [name, setName] = useState("");
  const [stack, setStack] = useState("");
  const [description, setDescription] = useState("");
  const [spec, setSpec] = useState<unknown>({});

  const [validation, setValidation] = useState<ValidateResponse>(EMPTY_VALIDATION);
  const [validating, setValidating] = useState(false);
  const [preview, setPreview] = useState<RenderPreviewResponse | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [pr, setPr] = useState<PRResponse | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [copied, setCopied] = useState(false);
  const nameError = name ? validateAppName(name) : null;
  const namespace = schema.stacks.find((s) => s.name === stack)?.namespace;

  // The generated claim — exactly what gets committed. This is the minimal claim
  // (only values you set); the full effective resources (with composition
  // defaults like resources/limits) are shown by the render Preview below.
  const yamlText = useMemo(
    () => claimToYaml({ name, namespace, spec }),
    [name, namespace, spec],
  );

  // Live validation (FR-002): debounce the spec and POST /api/validate.
  const debouncedSpec = useDebounced(spec, 400);
  useEffect(() => {
    let cancelled = false;
    setValidating(true);
    api
      .validate({ spec: (debouncedSpec ?? {}) as Record<string, unknown> })
      .then((res) => {
        if (!cancelled) setValidation(res);
      })
      .catch((e) => {
        if (cancelled) return;
        if (e instanceof ValidationError && "valid" in e.body) {
          setValidation(e.body as ValidateResponse);
        }
        // Network / backend-down: keep last known validation, don't block UI.
      })
      .finally(() => {
        if (!cancelled) setValidating(false);
      });
    return () => {
      cancelled = true;
    };
  }, [debouncedSpec]);

  const blocked =
    !name ||
    !!nameError ||
    !stack ||
    !validation.valid ||
    validation.schemaErrors.length > 0 ||
    validation.celViolations.length > 0 ||
    validation.secretFindings.length > 0;

  async function onPreview() {
    setPreviewing(true);
    setPreview(null);
    try {
      const res = await api.renderPreview({
        spec: (spec ?? {}) as Record<string, unknown>,
        name,
        stack,
      });
      setPreview(res);
    } catch (e) {
      setPreview({ ok: false, resources: [], error: errorMessage(e) });
    } finally {
      setPreviewing(false);
    }
  }

  async function onOpenPR() {
    setSubmitting(true);
    setSubmitError(null);
    setPr(null);
    try {
      const res = await api.openPR({
        stack,
        appName: name,
        spec: (spec ?? {}) as Record<string, unknown>,
        description,
      });
      setPr(res);
    } catch (e) {
      if (e instanceof ValidationError) {
        if ("valid" in e.body) setValidation(e.body as ValidateResponse);
        setSubmitError(
          (e.body as { error?: string }).error ??
            "PR blocked by validation gates — see the errors above.",
        );
      } else {
        setSubmitError(errorMessage(e));
      }
    } finally {
      setSubmitting(false);
    }
  }

  async function copyYaml() {
    try {
      await navigator.clipboard.writeText(yamlText);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard unavailable */
    }
  }

  const renderField = (f: TopField, basicScreen = false) => {
    if (SECRET_KEYS.has(f.key)) return null; // handled by the secrets group
    return (
      <Field
        key={f.key}
        schema={f.schema}
        path={[f.key]}
        spec={spec}
        onChange={setSpec}
        errors={validation.schemaErrors}
        label={f.hint.label ?? f.key}
        help={f.hint.help ?? f.schema.description}
        placeholder={f.hint.example}
        hints={schema.hints}
        basicScreen={basicScreen}
      />
    );
  };

  const hasSecretFields = [...layout.basic, ...layout.groups.flatMap((g) => g.fields), ...layout.ungrouped].some(
    (f) => SECRET_KEYS.has(f.key),
  );

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
      {/* ---- Form column ---- */}
      <div className="space-y-4" data-testid="form-column">
        <Card>
          <CardHeader>
            <CardTitle>Basics</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-1">
              <label htmlFor="app-name" className="text-sm font-medium">
                App name
              </label>
              <Input
                id="app-name"
                placeholder="my-app"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
              {nameError && <p className="text-xs text-destructive">{nameError}</p>}
            </div>

            <div className="space-y-1">
              <label htmlFor="stack" className="text-sm font-medium">
                Stack
              </label>
              <Select id="stack" value={stack} onChange={(e) => setStack(e.target.value)}>
                <option value="" disabled>
                  — select a stack —
                </option>
                {schema.stacks.map((s) => (
                  <option key={s.name} value={s.name}>
                    {s.name} — {s.description}
                  </option>
                ))}
              </Select>
              {namespace && (
                <p className="text-xs text-muted-foreground">Namespace: {namespace}</p>
              )}
            </div>

            <div className="space-y-1">
              <label htmlFor="description" className="text-sm font-medium">
                Description
              </label>
              <Textarea
                id="description"
                placeholder="What does this app do? (feeds the PR body)"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>
          </CardContent>
        </Card>

        {/* Schema-driven basic-tier fields, grouped into always-open display
            blocks (Workload, Networking & exposure, …) by their ui-hints group.
            `image` is special-cased to the bespoke ImageField; everything else
            stays generic. */}
        {layout.basicGroups.map(({ group, fields }) => (
          <Card key={group.id}>
            <CardHeader>
              <CardTitle>{group.label}</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              {fields.map((f) =>
                f.key === "image" ? (
                  <ImageField
                    key={f.key}
                    schema={f.schema}
                    spec={spec}
                    onChange={setSpec}
                    label={f.hint.label ?? "Image"}
                  />
                ) : (
                  renderField(f, true)
                ),
              )}
            </CardContent>
          </Card>
        ))}

        {/* Advanced / expert groups */}
        {layout.groups.map(({ group, fields }) => (
          <Collapsible
            key={group.id}
            title={group.label}
            badge={
              <Badge variant={tierBadgeVariant(group.tier)}>{group.tier}</Badge>
            }
            subtitle={`${fields.length} field${fields.length === 1 ? "" : "s"}`}
          >
            {/* Secrets guardrail editor lives in the group that owns env/secrets */}
            {fields.some((f) => SECRET_KEYS.has(f.key)) && (
              <SecretsEditor
                spec={spec}
                onChange={setSpec}
                envPath={["env"]}
                secretsPath={["externalSecrets"]}
              />
            )}
            {fields.map((f) => renderField(f, false))}
          </Collapsible>
        ))}

        {layout.ungrouped.length > 0 && (
          <Collapsible
            title="More options"
            badge={<Badge variant="secondary">advanced</Badge>}
            subtitle={`${layout.ungrouped.length} field${layout.ungrouped.length === 1 ? "" : "s"}`}
          >
            {layout.ungrouped.map((f) => renderField(f, false))}
          </Collapsible>
        )}

        {/* Fallback: if env/secrets exist but weren't inside any rendered group */}
        {hasSecretFields &&
          !layout.groups.some((g) => g.fields.some((f) => SECRET_KEYS.has(f.key))) && (
            <Collapsible title="Environment & Secrets" defaultOpen>
              <SecretsEditor
                spec={spec}
                onChange={setSpec}
                envPath={["env"]}
                secretsPath={["externalSecrets"]}
              />
            </Collapsible>
          )}

        {/* Validation summary */}
        <ValidationSummary validation={validation} validating={validating} />

        {/* Actions */}
        <div className="flex flex-wrap items-center gap-3">
          <Button type="button" variant="outline" onClick={onPreview} disabled={previewing}>
            {previewing ? "Rendering…" : "Preview"}
          </Button>
          <Button type="button" onClick={onOpenPR} disabled={blocked || submitting}>
            {submitting ? "Opening PR…" : "Open PR"}
          </Button>
          <span className="text-xs text-muted-foreground">
            Signed in as <strong>{user.login}</strong>
          </span>
        </div>

        {submitError && (
          <Alert variant="destructive">
            <AlertTitle>Could not open PR</AlertTitle>
            <AlertDescription>{submitError}</AlertDescription>
          </Alert>
        )}
        {pr && (
          <Alert variant="success">
            <AlertTitle>Pull request opened</AlertTitle>
            <AlertDescription>
              <a className="text-primary underline" href={pr.url} target="_blank" rel="noreferrer">
                {pr.url}
              </a>{" "}
              (#{pr.number}, branch <code>{pr.branch}</code>)
            </AlertDescription>
          </Alert>
        )}

        {preview && <PreviewCard preview={preview} />}
      </div>

      {/* ---- Live YAML pane ---- */}
      <div className="lg:sticky lg:top-4 lg:self-start">
        <Card>
          <CardHeader className="flex-row items-center justify-between space-y-0">
            <CardTitle>Generated claim (live)</CardTitle>
            <Button type="button" size="sm" variant="outline" onClick={copyYaml}>
              {copied ? "Copied!" : "Copy YAML"}
            </Button>
          </CardHeader>
          <CardContent className="space-y-2">
            <p className="text-xs text-muted-foreground">
              Only the values you set — the platform fills in the rest. Use
              <strong> Preview </strong> to see the full resources that will be created.
            </p>
            <pre
              data-testid="yaml-pane"
              className="max-h-[70vh] overflow-auto rounded-md bg-muted p-3 text-xs leading-relaxed"
            >
              <code>{yamlText}</code>
            </pre>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function ValidationSummary({
  validation,
  validating,
}: {
  validation: ValidateResponse;
  validating: boolean;
}) {
  const clean =
    validation.schemaErrors.length === 0 &&
    validation.celViolations.length === 0 &&
    validation.secretFindings.length === 0;
  if (clean) {
    if (validating) {
      return <p className="text-xs text-muted-foreground">Validating…</p>;
    }
    return (
      <div className="flex items-center gap-2 text-xs">
        <Badge variant="success">Valid</Badge>
        <span className="text-muted-foreground">No validation issues.</span>
      </div>
    );
  }
  return (
    <div className="space-y-2">
      {validation.celViolations.length > 0 && (
        <Alert variant="warning">
          <AlertTitle>Policy (CEL) violations</AlertTitle>
          <AlertDescription>
            <ul className="list-disc pl-5">
              {validation.celViolations.map((v, i) => (
                <li key={i}>{v.message}</li>
              ))}
            </ul>
          </AlertDescription>
        </Alert>
      )}
      {validation.secretFindings.length > 0 && (
        <Alert variant="destructive">
          <AlertTitle>Possible secrets detected</AlertTitle>
          <AlertDescription>
            <ul className="list-disc pl-5">
              {validation.secretFindings.map((f, i) => (
                <li key={i}>
                  <code>{f.path}</code>: {f.reason}
                </li>
              ))}
            </ul>
            Move secret values to AWS Secrets Manager and reference them via the ExternalSecret
            flow.
          </AlertDescription>
        </Alert>
      )}
      {validation.schemaErrors.length > 0 && (
        <Alert variant="destructive">
          <AlertTitle>Schema errors</AlertTitle>
          <AlertDescription>
            <ul className="list-disc pl-5">
              {validation.schemaErrors.map((e, i) => (
                <li key={i}>
                  <code>{e.path}</code>: {e.message}
                </li>
              ))}
            </ul>
          </AlertDescription>
        </Alert>
      )}
    </div>
  );
}

function PreviewCard({ preview }: { preview: RenderPreviewResponse }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Render preview</CardTitle>
      </CardHeader>
      <CardContent>
        {preview.ok ? (
          <div className="space-y-2">
            <p className="text-xs text-muted-foreground">
              The full resources the platform will create — including defaults
              (resources, probes, security context) the composition fills in.
            </p>
            <div className="flex items-center gap-2 text-xs">
              <Badge variant="success">Rendered</Badge>
              <span className="text-muted-foreground">
                {preview.resources.length} resource
                {preview.resources.length === 1 ? "" : "s"} generated.
              </span>
            </div>
            <ul className="space-y-1 text-sm">
              {preview.resources.map((r, i) =>
                r.yaml ? (
                  <li key={i} className="rounded-md border border-border/60">
                    <details>
                      <summary className="flex cursor-pointer list-none items-center gap-2 px-3 py-2 hover:bg-muted">
                        <Badge variant="outline">{r.kind}</Badge>
                        <span className="font-mono">{r.name}</span>
                        {r.role && (
                          <span className="text-xs text-muted-foreground">— {r.role}</span>
                        )}
                      </summary>
                      <pre className="max-h-[50vh] overflow-auto border-t border-border/60 bg-muted p-3 text-xs leading-relaxed">
                        <code>{r.yaml}</code>
                      </pre>
                    </details>
                  </li>
                ) : (
                  <li key={i} className="flex items-center gap-2 px-3 py-2">
                    <Badge variant="outline">{r.kind}</Badge>
                    <span className="font-mono">{r.name}</span>
                    {r.role && <span className="text-xs text-muted-foreground">— {r.role}</span>}
                  </li>
                ),
              )}
            </ul>
          </div>
        ) : (
          <Alert variant="destructive">
            <AlertDescription>{preview.error ?? "Render failed."}</AlertDescription>
          </Alert>
        )}
      </CardContent>
    </Card>
  );
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
