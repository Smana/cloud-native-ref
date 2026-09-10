// Two consumers, one shape: the page's embedded graph (the whole tree of one
// app) and the global Map's "Apps" source (every app plus its direct children).
import { registerMapSource } from '@kinvolk/headlamp-plugin/lib';
import { useEffect, useMemo, useState } from 'react';
import { type KubeJSON } from './app';
import { AppResource } from './appResource';
import { makeApiClient } from './client';
import { wrapKubeObject } from './kubeWrap';
import { nodeStatus } from './status';
import { type AppTree, buildAppTree } from './tree';

/** Turns a resolved tree into the node/edge shape GraphView consumes. */
export function graphNodesFrom(tree: AppTree) {
  return {
    nodes: tree.nodes.map(n => ({
      id: n.id,
      kubeObject: wrapKubeObject(n.object),
      status: nodeStatus(n.object),
    })),
    edges: tree.edges.map(e => ({ id: e.id, source: e.source, target: e.target })),
  };
}

/**
 * The source used by the App page: one app, its whole tree, nothing else.
 * Built as a source (rather than passed as raw nodes) because GraphView takes
 * sources, and because it keeps both graphs on one code path.
 */
export function appTreeSource(tree: AppTree | null) {
  return {
    id: 'ogenki-app-tree',
    label: 'App',
    useData() {
      return useMemo(() => (tree ? graphNodesFrom(tree) : null), [tree]);
    },
  };
}

/** The global Map's source: every visible App, expanded one level. */
export const appsMapSource = {
  id: 'ogenki-apps',
  label: 'Apps',
  useData() {
    const [apps] = AppResource.useList();
    const [tree, setTree] = useState<AppTree | null>(null);

    useEffect(() => {
      let live = true;
      if (!apps) {
        setTree(null);
        return;
      }
      const client = makeApiClient();
      Promise.all(
        apps.map(a => buildAppTree((a as unknown as { jsonData: KubeJSON }).jsonData, client, 1))
      )
        .then(trees => {
          if (!live) return;
          setTree({
            nodes: trees.flatMap(t => t.nodes),
            edges: trees.flatMap(t => t.edges),
            unresolved: [],
          });
        })
        .catch(() => live && setTree(null));
      return () => {
        live = false;
      };
    }, [apps]);

    return useMemo(() => (tree ? graphNodesFrom(tree) : null), [tree]);
  },
};

export function registerAppsMapSource() {
  registerMapSource(appsMapSource);
}
