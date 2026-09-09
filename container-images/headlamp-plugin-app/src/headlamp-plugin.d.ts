/// <reference types="@kinvolk/headlamp-plugin" />

import type * as React from 'react';

// Headlamp 0.45.0 exports the resource map's renderer to plugins through
// pluginLib.ResourceMap (kubernetes-sigs/headlamp#6992). The published plugin
// toolkit (0.14.0, May 2026) predates that: its externals map does not know
// the module, so `import { GraphView } from '@kinvolk/headlamp-plugin/lib/...'`
// compiles and then resolves to undefined at runtime.
//
// Until a toolkit >= 0.15 ships the export, we read the runtime global and
// declare its shape here. DELETE THIS BLOCK, and import normally, on the first
// toolkit release that carries ResourceMap.
declare global {
  interface Window {
    pluginLib: {
      ResourceMap: {
        GraphView: React.ComponentType<{
          height?: string;
          defaultNodeSelection?: string;
          defaultSources?: unknown[];
          defaultRelations?: unknown[];
          defaultFilters?: Array<
            { type: 'hasErrors' } | { type: 'namespace'; namespaces: Set<string> }
          >;
        }>;
        KubeIcon: React.ComponentType<{ kind: string; width?: string; height?: string }>;
      };
    };
  }
}

export {};
