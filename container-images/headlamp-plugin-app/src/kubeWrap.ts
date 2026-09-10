import { K8s } from '@kinvolk/headlamp-plugin/lib';
import { KubeObject } from '@kinvolk/headlamp-plugin/lib/K8s/cluster';
import type { KubeJSON } from './app';

// Headlamp's hover glance calls Pod.isClassOf(...) on whatever a node carries,
// which reads the static apiVersion of the wrapper's own class. A bare
// KubeObject has none, so it throws mid-render. Its real classes do — and they
// also carry the accessors the kind-specific glance panels read, which a thin
// wrapper cannot supply. So prefer the real class; the fallback is only ever
// reached by kinds no glance matches.
const fallbackCache = new Map<string, typeof KubeObject>();

export function wrapKubeObject(o: KubeJSON): KubeObject {
  const known = (K8s.ResourceClasses as Record<string, any>)[o.kind];
  if (known) return new known(o as any);

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
