// Assemble the App claim object from form state and dump it to YAML (FR-012).
import yaml from "js-yaml";
import { prune } from "./model";

export interface ClaimInput {
  name: string;
  namespace?: string;
  spec: unknown;
}

export function buildClaim({ name, namespace, spec }: ClaimInput): Record<string, unknown> {
  const metadata: Record<string, unknown> = { name: name || "<app-name>" };
  if (namespace) metadata.namespace = namespace;
  return {
    apiVersion: "cloud.ogenki.io/v1alpha1",
    kind: "App",
    metadata,
    spec: prune(spec) ?? {},
  };
}

export function claimToYaml(input: ClaimInput): string {
  return yaml.dump(buildClaim(input), { noRefs: true, lineWidth: 100, sortKeys: false });
}
