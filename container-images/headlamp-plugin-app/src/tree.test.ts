import { describe, expect, it, vi } from 'vitest';
import type { KubeJSON } from './app';
import { type ApiClient, type ApiResourceInfo, attachOwned, buildAppTree } from './tree';

function obj(
  kind: string,
  name: string,
  uid: string,
  extra: Partial<KubeJSON> = {},
  apiVersion = 'cloud.ogenki.io/v1alpha1'
): KubeJSON {
  return {
    apiVersion,
    kind,
    metadata: { name, namespace: 'demo', uid, ...(extra.metadata ?? {}) },
    spec: extra.spec,
    status: extra.status,
  } as KubeJSON;
}

function refs(...items: Array<[string, string, string]>) {
  return {
    crossplane: {
      resourceRefs: items.map(([apiVersion, kind, name]) => ({ apiVersion, kind, name })),
    },
  };
}

// The App and one nested XR (SQLInstance) that has refs of its own.
const app = obj('App', 'podinfo', 'uid-app', {
  spec: refs(
    ['apps/v1', 'Deployment', 'xplane-podinfo'],
    ['v1', 'Service', 'xplane-podinfo'],
    ['cloud.ogenki.io/v1alpha1', 'SQLInstance', 'xplane-podinfo-db']
  ),
});
const deployment = obj('Deployment', 'xplane-podinfo', 'uid-deploy', {}, 'apps/v1');
const service = obj('Service', 'xplane-podinfo', 'uid-svc', {}, 'v1');
const sql = obj('SQLInstance', 'xplane-podinfo-db', 'uid-sql', {
  spec: refs(['postgresql.sql.crossplane.io/v1alpha1', 'Database', 'xplane-podinfo-db']),
});
const database = obj(
  'Database',
  'xplane-podinfo-db',
  'uid-db',
  {},
  'postgresql.sql.crossplane.io/v1alpha1'
);

const catalog: Record<string, ApiResourceInfo[]> = {
  'cloud.ogenki.io/v1alpha1': [
    { kind: 'App', name: 'apps', namespaced: true },
    { kind: 'SQLInstance', name: 'sqlinstances', namespaced: true },
  ],
  'apps/v1': [{ kind: 'Deployment', name: 'deployments', namespaced: true }],
  v1: [{ kind: 'Service', name: 'services', namespaced: true }],
  'postgresql.sql.crossplane.io/v1alpha1': [
    { kind: 'Database', name: 'databases', namespaced: false },
  ],
};
const store: Record<string, KubeJSON> = {
  'deployments/xplane-podinfo': deployment,
  'services/xplane-podinfo': service,
  'sqlinstances/xplane-podinfo-db': sql,
  'databases/xplane-podinfo-db': database,
};

function fakeClient(overrides: Partial<ApiClient> = {}): ApiClient {
  return {
    discover: vi.fn(async (apiVersion: string) => catalog[apiVersion] ?? []),
    getObject: vi.fn(async (_av, plural, _ns, name) => store[`${plural}/${name}`] ?? null),
    ...overrides,
  };
}

describe('buildAppTree', () => {
  it('walks resourceRefs and recurses into a nested XR', async () => {
    const tree = await buildAppTree(app, fakeClient());

    expect(tree.nodes.map(n => n.id).sort()).toEqual(
      ['uid-app', 'uid-db', 'uid-deploy', 'uid-sql', 'uid-svc'].sort()
    );
    expect(tree.nodes.find(n => n.id === 'uid-app')!.depth).toBe(0);
    expect(tree.nodes.find(n => n.id === 'uid-sql')!.depth).toBe(1);
    expect(tree.nodes.find(n => n.id === 'uid-db')!.depth).toBe(2);
    expect(tree.edges).toContainEqual({
      id: 'uid-app-uid-sql',
      source: 'uid-app',
      target: 'uid-sql',
    });
    expect(tree.edges).toContainEqual({
      id: 'uid-sql-uid-db',
      source: 'uid-sql',
      target: 'uid-db',
    });
    expect(tree.unresolved).toEqual([]);
  });

  it('discovers each apiVersion at most once', async () => {
    const client = fakeClient();
    await buildAppTree(app, client);
    const seen = (client.discover as ReturnType<typeof vi.fn>).mock.calls.map(c => c[0]);
    expect(new Set(seen).size).toBe(seen.length);
  });

  it('resolves a cluster-scoped ref with no namespace', async () => {
    const client = fakeClient();
    await buildAppTree(app, client);
    const call = (client.getObject as ReturnType<typeof vi.fn>).mock.calls.find(
      c => c[1] === 'databases'
    );
    expect(call![2]).toBeUndefined();
  });

  it('records a ref it cannot resolve and still returns the rest', async () => {
    const orphan = obj('App', 'x', 'uid-x', { spec: refs(['v1', 'Service', 'missing']) });
    const tree = await buildAppTree(orphan, fakeClient());
    expect(tree.nodes.map(n => n.id)).toEqual(['uid-x']);
    expect(tree.unresolved).toEqual([{ apiVersion: 'v1', kind: 'Service', name: 'missing' }]);
  });

  it('records a ref whose kind is not in discovery', async () => {
    const weird = obj('App', 'x', 'uid-x', { spec: refs(['nope.example.com/v1', 'Ghost', 'g']) });
    const tree = await buildAppTree(weird, fakeClient());
    expect(tree.unresolved).toHaveLength(1);
    expect(tree.nodes).toHaveLength(1);
  });

  it('visits a repeated ref once', async () => {
    const dup = obj('App', 'x', 'uid-x', {
      spec: refs(['v1', 'Service', 'xplane-podinfo'], ['v1', 'Service', 'xplane-podinfo']),
    });
    const tree = await buildAppTree(dup, fakeClient());
    expect(tree.nodes.filter(n => n.id === 'uid-svc')).toHaveLength(1);
    expect(tree.edges).toHaveLength(1);
  });

  it('stops at maxDepth', async () => {
    const tree = await buildAppTree(app, fakeClient(), 1);
    expect(tree.nodes.map(n => n.id).sort()).toEqual(
      ['uid-app', 'uid-deploy', 'uid-sql', 'uid-svc'].sort()
    );
  });
});

describe('attachOwned', () => {
  it('adds transitively owned objects with their edges', async () => {
    const tree = await buildAppTree(app, fakeClient());
    const rs = obj(
      'ReplicaSet',
      'xplane-podinfo-abc',
      'uid-rs',
      {
        metadata: {
          name: 'xplane-podinfo-abc',
          namespace: 'demo',
          uid: 'uid-rs',
          ownerReferences: [{ uid: 'uid-deploy', kind: 'Deployment', name: 'xplane-podinfo' }],
        },
      } as Partial<KubeJSON>,
      'apps/v1'
    );
    const pod = obj(
      'Pod',
      'xplane-podinfo-abc-1',
      'uid-pod',
      {
        metadata: {
          name: 'xplane-podinfo-abc-1',
          namespace: 'demo',
          uid: 'uid-pod',
          ownerReferences: [{ uid: 'uid-rs', kind: 'ReplicaSet', name: 'xplane-podinfo-abc' }],
        },
      } as Partial<KubeJSON>,
      'v1'
    );
    const unrelated = obj('Pod', 'other', 'uid-other', {}, 'v1');

    const withPods = attachOwned(tree, [pod, rs, unrelated]);

    expect(withPods.nodes.map(n => n.id)).toContain('uid-rs');
    expect(withPods.nodes.map(n => n.id)).toContain('uid-pod');
    expect(withPods.nodes.map(n => n.id)).not.toContain('uid-other');
    expect(withPods.edges).toContainEqual({
      id: 'uid-deploy-uid-rs',
      source: 'uid-deploy',
      target: 'uid-rs',
    });
    expect(withPods.edges).toContainEqual({
      id: 'uid-rs-uid-pod',
      source: 'uid-rs',
      target: 'uid-pod',
    });
  });

  it('is order-independent and never duplicates a node', async () => {
    const tree = await buildAppTree(app, fakeClient());
    const rs = obj(
      'ReplicaSet',
      'rs',
      'uid-rs',
      {
        metadata: {
          name: 'rs',
          namespace: 'demo',
          uid: 'uid-rs',
          ownerReferences: [{ uid: 'uid-deploy', kind: 'Deployment', name: 'xplane-podinfo' }],
        },
      } as Partial<KubeJSON>,
      'apps/v1'
    );
    const a = attachOwned(tree, [rs, rs]);
    expect(a.nodes.filter(n => n.id === 'uid-rs')).toHaveLength(1);
    expect(a.edges.filter(e => e.id === 'uid-deploy-uid-rs')).toHaveLength(1);
  });
});
