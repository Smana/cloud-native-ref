// The live side of the resolver: Headlamp's API proxy, plus the ConfigMap read.
// Kept apart from tree.ts so the traversal stays a pure function over an
// injected client and can be tested without a cluster.
import { ApiProxy } from '@kinvolk/headlamp-plugin/lib';
import { useEffect, useState } from 'react';
import type { KubeJSON } from './app';
import { type LinkTemplate, parseLinks } from './links';
import type { ApiClient, ApiResourceInfo } from './tree';

/** /apis/<group>/<version>, or /api/v1 for core resources. */
function apiBase(apiVersion: string): string {
  return apiVersion.includes('/') ? `/apis/${apiVersion}` : `/api/${apiVersion}`;
}

export function makeApiClient(): ApiClient {
  return {
    async discover(apiVersion: string): Promise<ApiResourceInfo[]> {
      const res = await ApiProxy.request(apiBase(apiVersion));
      const list = (res?.resources ?? []) as Array<{
        kind: string;
        name: string;
        namespaced: boolean;
      }>;
      // Subresources ("pods/log") are never fetchable objects.
      return list
        .filter(r => !r.name.includes('/'))
        .map(r => ({ kind: r.kind, name: r.name, namespaced: r.namespaced }));
    },
    async getObject(apiVersion, plural, namespace, name): Promise<KubeJSON | null> {
      // Every request here runs as the viewer through Headlamp's own proxy,
      // so this isn't an escalation either way — encoding is just correct.
      const encodedName = encodeURIComponent(name);
      const path = namespace
        ? `${apiBase(apiVersion)}/namespaces/${encodeURIComponent(namespace)}/${plural}/${encodedName}`
        : `${apiBase(apiVersion)}/${plural}/${encodedName}`;
      try {
        return (await ApiProxy.request(path)) as KubeJSON;
      } catch {
        // 404 (not created yet) and 403 (RBAC) are both "not available to
        // this viewer"; the caller records the ref as unresolved.
        return null;
      }
    },
  };
}

const LINKS_NAMESPACE = 'tooling';
const LINKS_CONFIGMAP = 'headlamp-plugin-app';

/**
 * Reads the optional links ConfigMap once per mount. A missing ConfigMap or a
 * viewer without `get` on it yields no links and no error: the section is
 * simply not rendered.
 */
export function useConfigLinks(): LinkTemplate[] {
  const [links, setLinks] = useState<LinkTemplate[]>([]);
  useEffect(() => {
    let live = true;
    ApiProxy.request(`/api/v1/namespaces/${LINKS_NAMESPACE}/configmaps/${LINKS_CONFIGMAP}`)
      .then(cm => {
        if (live) setLinks(parseLinks(cm?.data?.['links.json']));
      })
      .catch(() => {
        if (live) setLinks([]);
      });
    return () => {
      live = false;
    };
  }, []);
  return links;
}
