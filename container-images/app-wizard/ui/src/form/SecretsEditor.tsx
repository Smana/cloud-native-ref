// Secret guardrail editor (FR-010 / US-6). There is deliberately NO "secret
// value" input. Only two things can be added:
//   (a) non-sensitive literal env vars (name + value)
//   (b) ExternalSecret references (name + AWS Secrets Manager path)
// Secret *values* live in AWS Secrets Manager and are pulled at runtime by the
// External Secrets Operator — never committed to Git.
import type { PathSeg } from "./model";
import { deleteAt, getAt, setAt } from "./model";
import { Alert, AlertDescription, AlertTitle } from "../components/ui/alert";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";

interface EnvVar {
  name?: string;
  value?: string;
}
interface SecretRef {
  name?: string;
  remoteRef?: string;
}

interface Props {
  spec: unknown;
  onChange: (next: unknown) => void;
  envPath: PathSeg[];
  secretsPath: PathSeg[];
}

export function SecretsEditor({ spec, onChange, envPath, secretsPath }: Props) {
  const env = (getAt(spec, envPath) as EnvVar[] | undefined) ?? [];
  const secrets = (getAt(spec, secretsPath) as SecretRef[] | undefined) ?? [];

  return (
    <div className="space-y-4">
      <Alert variant="info">
        <AlertTitle>Secrets never transit the wizard</AlertTitle>
        <AlertDescription>
          Put <strong>non-sensitive</strong> configuration in literal env vars. For anything secret
          (tokens, passwords, keys), add an <strong>ExternalSecret reference</strong> pointing at an
          AWS Secrets Manager path — the value stays in Secrets Manager and is injected at runtime
          by the External Secrets Operator. This form has no field for a secret value.
        </AlertDescription>
      </Alert>

      <div className="space-y-2">
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium">Environment variables</span>
          <Badge variant="secondary">non-sensitive literals</Badge>
        </div>
        {env.map((row, i) => (
          <div key={i} className="flex gap-2">
            <Input
              placeholder="NAME"
              value={row.name ?? ""}
              onChange={(e) => onChange(setAt(spec, [...envPath, i, "name"], e.target.value || undefined))}
            />
            <Input
              placeholder="value"
              value={row.value ?? ""}
              onChange={(e) =>
                onChange(setAt(spec, [...envPath, i, "value"], e.target.value || undefined))
              }
            />
            <Button
              type="button"
              size="sm"
              variant="ghost"
              onClick={() => onChange(deleteAt(spec, [...envPath, i]))}
            >
              ✕
            </Button>
          </div>
        ))}
        <Button
          type="button"
          size="sm"
          variant="outline"
          onClick={() => onChange(setAt(spec, [...envPath, env.length], {}))}
        >
          + Add env var
        </Button>
      </div>

      <div className="space-y-2">
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium">Secret references</span>
          <Badge>AWS Secrets Manager</Badge>
        </div>
        {secrets.map((row, i) => (
          <div key={i} className="flex gap-2">
            <Input
              placeholder="ENV / secret name"
              value={row.name ?? ""}
              onChange={(e) =>
                onChange(setAt(spec, [...secretsPath, i, "name"], e.target.value || undefined))
              }
            />
            <Input
              placeholder="secretsmanager path e.g. myapp/db-password"
              value={row.remoteRef ?? ""}
              onChange={(e) =>
                onChange(setAt(spec, [...secretsPath, i, "remoteRef"], e.target.value || undefined))
              }
            />
            <Button
              type="button"
              size="sm"
              variant="ghost"
              onClick={() => onChange(deleteAt(spec, [...secretsPath, i]))}
            >
              ✕
            </Button>
          </div>
        ))}
        <Button
          type="button"
          size="sm"
          variant="outline"
          onClick={() => onChange(setAt(spec, [...secretsPath, secrets.length], {}))}
        >
          + Add secret reference
        </Button>
      </div>
    </div>
  );
}
