// Mapping a Kubernetes object to one of the map's three node states. Kinds
// differ in where they keep the truth: composites and managed resources use a
// Ready condition, Deployments use Available, HTTPRoutes report per parent,
// Pods have a phase, Jobs use Complete/Failed (never Ready), and Gateways use
// Programmed/Accepted on the object itself. A kind with no health semantics
// (Service, ConfigMap, PodDisruptionBudget, CronJob) exists or it does not, so
// it is success.
import type { KubeJSON } from './app';

export type NodeStatus = 'success' | 'warning' | 'error';

export interface KubeCondition {
  type: string;
  status: string;
  reason?: string;
  message?: string;
}

export function conditionOf(obj: KubeJSON, type: string): KubeCondition | undefined {
  const conditions = obj.status?.conditions;
  if (!Array.isArray(conditions)) return undefined;
  return conditions.find((c: KubeCondition) => c?.type === type);
}

/** Kinds whose health lives in a condition other than Ready. */
const CONDITION_BY_KIND: Record<string, string> = {
  Deployment: 'Available',
  StatefulSet: 'Available',
};

/**
 * Kinds that carry no health at all: present is healthy. Exported so tests can
 * pin every member rather than a hand-picked sample — the CronJob gap (real
 * batch/v1 CronJobStatus has no conditions field, so the default Ready lookup
 * left it stuck on 'warning' forever) would have been caught by that.
 */
export const NO_HEALTH = new Set([
  'Service',
  'ServiceAccount',
  'ConfigMap',
  'Secret',
  'PodDisruptionBudget',
  'HorizontalPodAutoscaler',
  'CiliumNetworkPolicy',
  'VMServiceScrape',
  'VMRule',
  'PersistentVolumeClaim',
  'ReplicaSet',
  'CronJob',
]);

function fromStatus(status: string | undefined): NodeStatus {
  if (status === 'True') return 'success';
  if (status === 'False') return 'error';
  return 'warning';
}

export function nodeStatus(obj: KubeJSON): NodeStatus {
  if (obj.kind === 'Pod') {
    const phase = obj.status?.phase;
    if (phase === 'Running' || phase === 'Succeeded') return 'success';
    if (phase === 'Failed') return 'error';
    return 'warning';
  }

  if (obj.kind === 'HTTPRoute') {
    const parents = obj.status?.parents;
    if (!Array.isArray(parents) || parents.length === 0) return 'warning';
    const accepted = parents.some((p: { conditions?: KubeCondition[] }) =>
      p?.conditions?.some(c => c.type === 'Accepted' && c.status === 'True'),
    );
    return accepted ? 'success' : 'error';
  }

  if (obj.kind === 'Job') {
    if (conditionOf(obj, 'Failed')?.status === 'True') return 'error';
    if (conditionOf(obj, 'Complete')?.status === 'True') return 'success';
    // Still running. A Job only gets the Failed condition once backoffLimit is
    // exhausted, so failed attempts are the only earlier signal there is — and
    // a long-running Job that is simply working must not sit at warning, or
    // every scheduled run would repaint the graph.
    return (obj.status?.failed ?? 0) > 0 ? 'warning' : 'success';
  }

  if (obj.kind === 'Gateway') {
    // Unlike HTTPRoute, these conditions are on the object itself, not per
    // parent. Prefer Programmed; fall back to Accepted; neither present means
    // still settling, which is a genuine warning here since a Gateway does
    // acquire them.
    const programmed = conditionOf(obj, 'Programmed') ?? conditionOf(obj, 'Accepted');
    return programmed ? fromStatus(programmed.status) : 'warning';
  }

  if (NO_HEALTH.has(obj.kind)) return 'success';

  const conditionType = CONDITION_BY_KIND[obj.kind] ?? 'Ready';
  const condition = conditionOf(obj, conditionType);
  // No condition yet on a kind that should have one means "still settling",
  // which is a warning rather than a failure — a freshly created XR looks
  // exactly like this for a few seconds.
  return condition ? fromStatus(condition.status) : 'warning';
}
