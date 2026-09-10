import { K8s } from '@kinvolk/headlamp-plugin/lib';
import { KubeObject } from '@kinvolk/headlamp-plugin/lib/K8s/cluster';
import type { KubeJSON } from './app';

// Headlamp's hover glance calls Pod.isClassOf(...) on whatever a node carries,
// which reads the static apiVersion of the wrapper's own class. A bare
// KubeObject has none, so it throws mid-render. Its real classes do — and they
// also carry the accessors the kind-specific glance panels read, which a thin
// wrapper cannot supply. So prefer the real class; the fallback is only ever
// reached by kinds no glance matches — or by a kind whose registered class
// turns out to be from the wrong API group. A kind name alone is not unique
// across groups, and this platform really does compose one that collides: an
// App that requests object storage or a database reaches the nested EPI
// composite, which composes a Role from iam.aws.m.upbound.io — the same kind
// name as RBAC's Role (rbac.authorization.k8s.io). Wrapping it with the RBAC
// class points the details link at a nonexistent RBAC route and feeds the
// RBAC glance `.rules` off an IAM role that has none. So the registered class
// is only trusted once its own API group is checked against the object's.
const fallbackCache = new Map<string, typeof KubeObject>();

/** The part of an apiVersion before '/', or '' for a core resource like "v1". */
function groupOf(apiVersion: string): string {
  const i = apiVersion.indexOf('/');
  return i === -1 ? '' : apiVersion.slice(0, i);
}

/**
 * `KubeObject.apiGroupName` is a static getter that throws when the class has
 * no static `apiVersion` at all — exactly the situation this helper exists to
 * route around — so read it defensively rather than assume every registered
 * class carries one.
 */
function classGroup(cls: typeof KubeObject): string | undefined {
  try {
    return cls.apiGroupName;
  } catch {
    return undefined;
  }
}

export function wrapKubeObject(o: KubeJSON): KubeObject {
  const known = (K8s.ResourceClasses as Record<string, any>)[o.kind];
  if (known && (classGroup(known) ?? '') === groupOf(o.apiVersion)) {
    return new known(o as any);
  }

  const key = `${o.apiVersion}/${o.kind}`;
  let cls = fallbackCache.get(key);
  if (!cls) {
    cls = class extends KubeObject {
      static apiVersion = o.apiVersion;
      static kind = o.kind;
    };
    fallbackCache.set(key, cls);
  }
  return new cls(o as any);
}
