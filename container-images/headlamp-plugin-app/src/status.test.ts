import { describe, expect, it } from 'vitest';
import type { KubeJSON } from './app';
import { conditionOf, nodeStatus } from './status';

function withConditions(kind: string, conditions: any[], apiVersion = 'cloud.ogenki.io/v1alpha1'): KubeJSON {
  return { apiVersion, kind, metadata: { name: 'x', namespace: 'demo', uid: 'u' }, status: { conditions } } as KubeJSON;
}

describe('nodeStatus', () => {
  it('reads Ready on a composite or managed resource', () => {
    expect(nodeStatus(withConditions('SQLInstance', [{ type: 'Ready', status: 'True' }]))).toBe('success');
    expect(nodeStatus(withConditions('SQLInstance', [{ type: 'Ready', status: 'False' }]))).toBe('error');
    expect(nodeStatus(withConditions('SQLInstance', [{ type: 'Ready', status: 'Unknown' }]))).toBe('warning');
  });

  it('reads Available on a Deployment', () => {
    expect(nodeStatus(withConditions('Deployment', [{ type: 'Available', status: 'True' }], 'apps/v1'))).toBe('success');
    expect(nodeStatus(withConditions('Deployment', [{ type: 'Available', status: 'False' }], 'apps/v1'))).toBe('error');
  });

  it('accepts an HTTPRoute when any parent accepted it', () => {
    const route = {
      apiVersion: 'gateway.networking.k8s.io/v1',
      kind: 'HTTPRoute',
      metadata: { name: 'r', namespace: 'demo', uid: 'u' },
      status: { parents: [{ conditions: [{ type: 'Accepted', status: 'False' }] }, { conditions: [{ type: 'Accepted', status: 'True' }] }] },
    } as unknown as KubeJSON;
    expect(nodeStatus(route)).toBe('success');
  });

  it('errors an HTTPRoute with no accepted parent', () => {
    const route = {
      apiVersion: 'gateway.networking.k8s.io/v1',
      kind: 'HTTPRoute',
      metadata: { name: 'r', namespace: 'demo', uid: 'u' },
      status: { parents: [{ conditions: [{ type: 'Accepted', status: 'False' }] }] },
    } as unknown as KubeJSON;
    expect(nodeStatus(route)).toBe('error');
  });

  it('reads a Pod phase', () => {
    const pod = (phase: string) => ({ apiVersion: 'v1', kind: 'Pod', metadata: { name: 'p', namespace: 'demo', uid: 'u' }, status: { phase } }) as unknown as KubeJSON;
    expect(nodeStatus(pod('Running'))).toBe('success');
    expect(nodeStatus(pod('Succeeded'))).toBe('success');
    expect(nodeStatus(pod('Pending'))).toBe('warning');
    expect(nodeStatus(pod('Failed'))).toBe('error');
  });

  it('is success for kinds with no health semantics', () => {
    const svc = { apiVersion: 'v1', kind: 'Service', metadata: { name: 's', namespace: 'demo', uid: 'u' }, spec: { clusterIP: '10.0.0.1' } } as KubeJSON;
    expect(nodeStatus(svc)).toBe('success');
  });

  it('warns when a resource that should have conditions has none yet', () => {
    const fresh = { apiVersion: 'cloud.ogenki.io/v1alpha1', kind: 'SQLInstance', metadata: { name: 'q', namespace: 'demo', uid: 'u' } } as KubeJSON;
    expect(nodeStatus(fresh)).toBe('warning');
  });
});

describe('conditionOf', () => {
  it('returns the matching condition, or undefined', () => {
    const o = withConditions('App', [{ type: 'Synced', status: 'True', reason: 'ReconcileSuccess' }]);
    expect(conditionOf(o, 'Synced')?.reason).toBe('ReconcileSuccess');
    expect(conditionOf(o, 'Ready')).toBeUndefined();
  });
});
