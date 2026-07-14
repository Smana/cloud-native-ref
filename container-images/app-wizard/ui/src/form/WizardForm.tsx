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
import { GitHubLinkRequiredError, ValidationError } from "../api/client";
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
import {
  buildLayout,
  clearInvalidForType,
  fieldVisibleForType,
  getAt,
  setAt,
  tierBadgeVariant,
  type TopField,
} from "./model";
import { claimToYaml } from "./claim";
import { useDebounced } from "./useDebounced";
import { validateAppName } from "./validation";
import { errorMessage } from "../lib/utils";

const EMPTY_VALIDATION: ValidateResponse = {
  valid: true,
  schemaErrors: [],
  celViolations: [],
  secretFindings: [],
};

// These keys are rendered by the bespoke SecretsEditor, not the generic widget.
const SECRET_KEYS = new Set(["env", "externalSecrets"]);

// When editing an existing app, the caller passes the loaded AppDetail here.
// `mode: "update"` puts the form in edit mode: name + stack are prefilled and
// read-only (renaming = create+delete), and the spec is fully hydrated.
export interface WizardInitial {
  mode: "create" | "update";
  appName: string;
  stack: string;
  spec: Record<string, unknown>;
}

interface Props {
  schema: SchemaPayload;
  user: User;
  initial?: WizardInitial;
  // Optional "back to inventory" affordance, shown in edit mode.
  onBack?: () => void;
}

export function WizardForm({ schema, user, initial, onBack }: Props) {
  const layout = useMemo(() => buildLayout(schema), [schema]);

  const mode = initial?.mode ?? "create";
  const isEdit = mode === "update";

  // Prefill from `initial` when editing. The full loaded spec is stored as-is —
  // including keys the generic renderer doesn't know about — so an update PR
  // re-submits every field (the backend patch is authoritative). Only the YAML
  // pane display prunes; state retains everything.
  const [name, setName] = useState(initial?.appName ?? "");
  const [stack, setStack] = useState(initial?.stack ?? "");
  const [description, setDescription] = useState("");
  const [spec, setSpec] = useState<unknown>(initial?.spec ?? {});

  const [validation, setValidation] = useState<ValidateResponse>(EMPTY_VALIDATION);
  const [validating, setValidating] = useState(false);
  const [preview, setPreview] = useState<RenderPreviewResponse | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [pr, setPr] = useState<PRResponse | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);
  // zitadel mode: set when a PR attempt returns 428 (GitHub not linked). Carries
  // the link URL so the alert can offer a "Connect GitHub" action.
  const [linkPrompt, setLinkPrompt] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [copied, setCopied] = useState(false);
  const nameError = name ? validateAppName(name) : null;
  const namespace = schema.stacks.find((s) => s.name === stack)?.namespace;

  // --- LLM assists (Phase 3, all optional; FR-011) ---
  // Availability gate: probe once on mount. Until it resolves `true`, NONE of the
  // assist affordances render. Any failure ⇒ unavailable (the form stays usable).
  const [assistAvailable, setAssistAvailable] = useState(false);
  // Top-level spec keys the prefill assist set, for the "AI-suggested" badge.
  const [prefilledKeys, setPrefilledKeys] = useState<string[]>([]);
  useEffect(() => {
    let cancelled = false;
    api
      .assistStatus()
      .then((s) => {
        if (!cancelled) setAssistAvailable(!!s.available);
      })
      .catch(() => {
        if (!cancelled) setAssistAvailable(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Workload type drives which top-level fields are valid (mirrors the App XRD
  // CEL rules). Default "web" when unset.
  const workloadType = (getAt(spec, ["type"]) as string | undefined) ?? "web";

  // Visibility filter by workload type (fieldVisibleForType is the shared
  // predicate in model.ts, mirroring the App XRD CEL rules). Applied to a set of
  // { group, fields } blocks, dropping any group that becomes empty (so e.g.
  // "Networking & exposure" disappears entirely for worker/cron, "Schedule"
  // appears only for cron). Memoised on [layout, workloadType] since layout is
  // already memoised on [schema].
  const { visibleBasicGroups, visibleGroups, visibleUngrouped } = useMemo(() => {
    const filterGroups = (
      groups: Array<{ group: (typeof layout.groups)[number]["group"]; fields: TopField[] }>,
    ) =>
      groups
        .map(({ group, fields }) => ({
          group,
          fields: fields.filter((f) => fieldVisibleForType(f.key, workloadType)),
        }))
        .filter(({ fields }) => fields.length > 0);

    return {
      visibleBasicGroups: filterGroups(layout.basicGroups),
      visibleGroups: filterGroups(layout.groups),
      visibleUngrouped: layout.ungrouped.filter((f) =>
        fieldVisibleForType(f.key, workloadType),
      ),
    };
  }, [layout, workloadType]);

  // Clear now-invalid values when the type changes so a hidden field can't leave a
  // stale value that trips CEL validation and blocks the PR. clearInvalidForType
  // returns the SAME reference when nothing changes, so this never loops.
  useEffect(() => {
    setSpec((s: unknown) => clearInvalidForType(s, workloadType));
  }, [workloadType]);

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

  // zitadel mode: PRs open under the user's GitHub identity, so a linked GitHub
  // token is required. github/dev modes always report githubLinked:true.
  const githubLinked = user.githubLinked !== false;

  const blocked =
    !name ||
    !!nameError ||
    !stack ||
    !githubLinked ||
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
    setLinkPrompt(null);
    setPr(null);
    try {
      const res = await api.openPR({
        stack,
        appName: name,
        mode,
        spec: (spec ?? {}) as Record<string, unknown>,
        description,
      });
      setPr(res);
    } catch (e) {
      if (e instanceof GitHubLinkRequiredError) {
        // zitadel mode: authenticated but GitHub not linked → prompt to connect.
        setLinkPrompt(e.linkUrl);
      } else if (e instanceof ValidationError) {
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

  const hasSecretFields = useMemo(
    () =>
      [
        ...layout.basic,
        ...layout.groups.flatMap((g) => g.fields),
        ...layout.ungrouped,
      ].some((f) => SECRET_KEYS.has(f.key)),
    [layout],
  );

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
      {/* ---- Form column ---- */}
      <div className="space-y-4" data-testid="form-column">
        {isEdit && onBack && (
          <Button type="button" variant="ghost" size="sm" onClick={onBack}>
            ← Back to my apps
          </Button>
        )}
        {isEdit && (
          <p className="text-sm text-muted-foreground">
            Editing <strong>{name}</strong> in stack <strong>{stack}</strong>.
          </p>
        )}
        {/* Describe-to-prefill (optional; only when the assist backend is up) */}
        {assistAvailable && (
          <DescribePrefill
            onPrefill={(spec, keys) => {
              // Shallow-merge the partial App spec the model returned. name/stack
              // are managed by the Basics fields, never by spec — drop them here.
              const { name: _n, stack: _s, ...rest } = spec as Record<string, unknown>;
              void _n;
              void _s;
              setSpec((prev: unknown) => ({
                ...((prev ?? {}) as Record<string, unknown>),
                ...rest,
              }));
              setPrefilledKeys(keys.filter((k) => k !== "name" && k !== "stack"));
              // Never auto-submit — the user still reviews and clicks Open PR.
            }}
            suggestedKeys={prefilledKeys}
          />
        )}

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
                readOnly={isEdit}
                disabled={isEdit}
                onChange={(e) => setName(e.target.value)}
              />
              {isEdit ? (
                <p className="text-xs text-muted-foreground">
                  Name can't be changed — to rename, decommission and create a new app.
                </p>
              ) : (
                nameError && <p className="text-xs text-destructive">{nameError}</p>
              )}
            </div>

            <div className="space-y-1">
              <label htmlFor="stack" className="text-sm font-medium">
                Stack
              </label>
              <Select
                id="stack"
                value={stack}
                disabled={isEdit}
                onChange={(e) => setStack(e.target.value)}
              >
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
        {visibleBasicGroups.map(({ group, fields }) => (
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
        {visibleGroups.map(({ group, fields }) => (
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

        {visibleUngrouped.length > 0 && (
          <Collapsible
            title="More options"
            badge={<Badge variant="secondary">advanced</Badge>}
            subtitle={`${visibleUngrouped.length} field${visibleUngrouped.length === 1 ? "" : "s"}`}
          >
            {visibleUngrouped.map((f) => renderField(f, false))}
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
            {submitting
              ? isEdit
                ? "Opening update PR…"
                : "Opening PR…"
              : isEdit
                ? "Open update PR"
                : "Open PR"}
          </Button>
          <span className="text-xs text-muted-foreground">
            Signed in as <strong>{user.login}</strong>
          </span>
        </div>
        {!githubLinked && (
          <p className="text-xs text-muted-foreground">
            Connect your GitHub account first —{" "}
            <a className="text-primary underline" href={api.githubLinkUrl()}>
              connect GitHub
            </a>
            .
          </p>
        )}

        {linkPrompt && (
          <Alert variant="warning">
            <AlertTitle>Connect your GitHub account to open pull requests</AlertTitle>
            <AlertDescription className="space-y-2">
              <p>
                Pull requests are opened under your own GitHub identity. Connect
                your GitHub account, then try again.
              </p>
              <Button type="button" size="sm" onClick={() => (window.location.href = linkPrompt)}>
                Connect GitHub
              </Button>
            </AlertDescription>
          </Alert>
        )}

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

        {/* Network-policy suggester (optional; expert helper). Writes into
            spec.networkPolicies (enabled + ingress + egress). */}
        {assistAvailable && (
          <PolicySuggester
            onSuggest={(ingress, egress) => {
              let next = setAt(spec, ["networkPolicies", "enabled"], true);
              next = setAt(next, ["networkPolicies", "ingress"], ingress);
              next = setAt(next, ["networkPolicies", "egress"], egress);
              setSpec(next);
            }}
          />
        )}
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

// --- LLM assist widgets (Phase 3, optional) --------------------------------

// Describe-to-prefill: free-text → partial App spec merged into the form. Never
// auto-submits. Badges which top-level fields the model set so the user reviews.
function DescribePrefill({
  onPrefill,
  suggestedKeys,
}: {
  onPrefill: (spec: Record<string, unknown>, keys: string[]) => void;
  suggestedKeys: string[];
}) {
  const [text, setText] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run() {
    if (!text.trim()) return;
    setLoading(true);
    setError(null);
    try {
      const res = await api.assistPrefill(text);
      onPrefill(res.spec ?? {}, res.keys ?? []);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }

  return (
    <Collapsible
      title="✨ Describe your app"
      subtitle="optional AI assist"
      badge={<Badge variant="secondary">beta</Badge>}
    >
      <div className="space-y-3">
        <p className="text-xs text-muted-foreground">
          Describe what you want in plain language and we'll prefill the form. You
          stay in control — review every field before opening a PR. Nothing is
          submitted automatically.
        </p>
        <Textarea
          aria-label="Describe your app"
          placeholder="A Python API on port 8000 with a small Postgres, private access"
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
        <div className="flex flex-wrap items-center gap-3">
          <Button type="button" size="sm" onClick={run} disabled={loading || !text.trim()}>
            {loading ? "Prefilling…" : "Prefill"}
          </Button>
          {suggestedKeys.length > 0 && (
            <span className="flex items-center gap-2 text-xs text-muted-foreground">
              <Badge variant="default">AI-suggested — review</Badge>
              Set: <code>{suggestedKeys.join(", ")}</code>
            </span>
          )}
        </div>
        {error && (
          <p className="text-xs text-destructive">
            Couldn't prefill ({error}). The form still works — fill it in manually.
          </p>
        )}
      </div>
    </Collapsible>
  );
}

// Network-policy suggester: free-text → ingress/egress rules written into
// spec.networkPolicies. Badged "AI-suggested — review" with a strong warning.
function PolicySuggester({
  onSuggest,
}: {
  onSuggest: (ingress: unknown[], egress: unknown[]) => void;
}) {
  const [text, setText] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [applied, setApplied] = useState(false);

  async function run() {
    if (!text.trim()) return;
    setLoading(true);
    setError(null);
    try {
      const res = await api.assistPolicies(text);
      onSuggest(res.ingress ?? [], res.egress ?? []);
      setApplied(true);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Network policy helper</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <Alert variant="warning">
          <AlertTitle>Review carefully</AlertTitle>
          <AlertDescription>
            Network policies control what your app can reach. Suggestions are a
            starting point — verify every rule against what your app actually needs
            before opening a PR.
          </AlertDescription>
        </Alert>
        <Textarea
          aria-label="Describe network access"
          placeholder="e.g. calls stripe.com and the payments database"
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
        <div className="flex flex-wrap items-center gap-3">
          <Button
            type="button"
            size="sm"
            variant="outline"
            onClick={run}
            disabled={loading || !text.trim()}
          >
            {loading ? "Suggesting…" : "Suggest policies"}
          </Button>
          {applied && !error && (
            <Badge variant="default">AI-suggested — review</Badge>
          )}
        </div>
        {applied && !error && (
          <p className="text-xs text-muted-foreground">
            Rules written to <code>networkPolicies</code>. Review them in the
            Networking section and the generated claim.
          </p>
        )}
        {error && (
          <p className="text-xs text-destructive">
            Couldn't suggest policies ({error}). You can still edit network policies
            manually.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
