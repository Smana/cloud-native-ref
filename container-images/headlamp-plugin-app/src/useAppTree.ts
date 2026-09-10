// One App's tree, kept fresh. Objects reached through ApiProxy are polled
// (Headlamp's own hooks are live, but a hand-rolled fetch is not), which is
// enough for a page someone is looking at.
import { K8s } from '@kinvolk/headlamp-plugin/lib';
import { useEffect, useMemo, useState } from 'react';
import { type KubeJSON } from './app';
import { APP_API_VERSION } from './appResource';
import { makeApiClient } from './client';
import { type AppTree, attachOwned, buildAppTree } from './tree';

const REFRESH_MS = 10_000;

export function useAppTree(namespace: string, name: string) {
  const [app, setApp] = useState<KubeJSON | null>(null);
  const [tree, setTree] = useState<AppTree | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  // Live, via Headlamp's own watch: pods and replicasets of the namespace.
  const [pods] = K8s.ResourceClasses.Pod.useList({ namespace });
  const [replicaSets] = K8s.ResourceClasses.ReplicaSet.useList({ namespace });
  const [jobs] = K8s.ResourceClasses.Job.useList({ namespace });

  useEffect(() => {
    const id = setInterval(() => setTick(t => t + 1), REFRESH_MS);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    let live = true;
    const client = makeApiClient();
    (async () => {
      const root = await client.getObject(APP_API_VERSION, 'apps', namespace, name);
      if (!live) return;
      if (!root) {
        setApp(null);
        setTree(null);
        setError(
          `No App "${name}" in namespace "${namespace}" on this cluster. If it was just declared, its pull request may not be merged or reconciled yet.`
        );
        return;
      }
      const built = await buildAppTree(root, client);
      if (!live) return;
      setApp(root);
      setTree(built);
      setError(null);
    })().catch(e => {
      if (live) setError(String(e?.message ?? e));
    });
    return () => {
      live = false;
    };
  }, [namespace, name, tick]);

  const withOwned = useMemo(() => {
    if (!tree) return null;
    const candidates = [...(replicaSets ?? []), ...(jobs ?? []), ...(pods ?? [])].map(
      o => (o as unknown as { jsonData: KubeJSON }).jsonData
    );
    return attachOwned(tree, candidates);
  }, [tree, pods, replicaSets, jobs]);

  return { app, tree: withOwned, error };
}
