// Shared shapes. `App` is a Crossplane v2 namespaced composite resource: its
// children are listed in spec.crossplane.resourceRefs by apiVersion, kind and
// name — no namespace, no uid — which is why resolving the tree needs API
// discovery rather than a simple lookup.
//
// Kept free of any Headlamp/Kubernetes import on purpose: tree.ts (and its
// tests) import resourceRefs as a value, which means evaluating this module —
// a live import of the toolkit's KubeObject would drag that evaluation into
// vitest, which has no cluster and no host `pluginLib` global to satisfy it.
// The AppResource KubeObject subclass lives in ./appResource instead.

export interface KubeJSON {
  apiVersion: string;
  kind: string;
  metadata: {
    name: string;
    namespace?: string;
    uid: string;
    creationTimestamp?: string;
    labels?: Record<string, string>;
    ownerReferences?: Array<{ uid: string; kind: string; name: string }>;
  };
  spec?: Record<string, any>;
  status?: Record<string, any>;
}

export interface ResourceRef {
  apiVersion: string;
  kind: string;
  name: string;
  namespace?: string;
}

/**
 * The composed-resource references of a composite resource. Crossplane v2 puts
 * them under spec.crossplane.resourceRefs; v1 put them at spec.resourceRefs.
 * Both are read so a nested XR from an older composition still expands.
 */
export function resourceRefs(obj: KubeJSON): ResourceRef[] {
  const raw = obj.spec?.crossplane?.resourceRefs ?? obj.spec?.resourceRefs;
  if (!Array.isArray(raw)) return [];
  return raw
    .filter(
      r =>
        r &&
        typeof r.apiVersion === 'string' &&
        typeof r.kind === 'string' &&
        typeof r.name === 'string'
    )
    .map(r => ({ apiVersion: r.apiVersion, kind: r.kind, name: r.name, namespace: r.namespace }));
}
