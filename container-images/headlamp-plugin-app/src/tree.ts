// Resolving an App into a graph. Breadth-first over resourceRefs: each ref
// names an apiVersion and a kind, so the plural and the scope come from API
// discovery (cached per apiVersion). A resolved object that carries refs of its
// own is a nested XR — SQLInstance, KVStore, EPI — and is expanded the same way.
import { type KubeJSON, type ResourceRef, resourceRefs } from './app';

export interface ApiResourceInfo {
  kind: string;
  /** The plural resource name used in the URL path. */
  name: string;
  namespaced: boolean;
}

export interface ApiClient {
  discover(apiVersion: string): Promise<ApiResourceInfo[]>;
  getObject(
    apiVersion: string,
    plural: string,
    namespace: string | undefined,
    name: string
  ): Promise<KubeJSON | null>;
}

export interface TreeNode {
  id: string;
  object: KubeJSON;
  depth: number;
  /**
   * The plural resource name this node was fetched as — API discovery
   * already resolves it once per apiVersion while walking resourceRefs, so
   * threading it onto the node is free. Used to build a details link for a
   * kind Headlamp has no registered class for. Absent for the root App
   * (never fetched by ref) and for anything attachOwned adds (Headlamp's own
   * typed Pod/ReplicaSet/Job lists always have a matching built-in class, so
   * nothing needs it there).
   */
  plural?: string;
}

export interface TreeEdge {
  id: string;
  source: string;
  target: string;
}

export interface AppTree {
  nodes: TreeNode[];
  edges: TreeEdge[];
  /** Refs that could not be fetched — absent, forbidden, or an unknown kind. */
  unresolved: ResourceRef[];
}

/** Guards a pathological composition; nothing here nests more than 2 deep. */
const DEFAULT_MAX_DEPTH = 6;

export async function buildAppTree(
  root: KubeJSON,
  client: ApiClient,
  maxDepth: number = DEFAULT_MAX_DEPTH
): Promise<AppTree> {
  const nodes: TreeNode[] = [{ id: root.metadata.uid, object: root, depth: 0 }];
  const edges: TreeEdge[] = [];
  const unresolved: ResourceRef[] = [];
  const seen = new Set<string>([root.metadata.uid]);

  // One discovery call per apiVersion, whatever the tree's shape.
  const discovered = new Map<string, Promise<ApiResourceInfo[]>>();
  const infoFor = async (
    apiVersion: string,
    kind: string
  ): Promise<ApiResourceInfo | undefined> => {
    let p = discovered.get(apiVersion);
    if (!p) {
      p = client.discover(apiVersion).catch(() => [] as ApiResourceInfo[]);
      discovered.set(apiVersion, p);
    }
    return (await p).find(r => r.kind === kind);
  };

  let frontier: TreeNode[] = nodes.slice();
  for (let depth = 1; depth <= maxDepth && frontier.length > 0; depth++) {
    const next: TreeNode[] = [];
    for (const parent of frontier) {
      for (const ref of resourceRefs(parent.object)) {
        const info = await infoFor(ref.apiVersion, ref.kind);
        if (!info) {
          unresolved.push(ref);
          continue;
        }
        const namespace = info.namespaced
          ? ref.namespace ?? parent.object.metadata.namespace
          : undefined;
        let child: KubeJSON | null = null;
        try {
          child = await client.getObject(ref.apiVersion, info.name, namespace, ref.name);
        } catch {
          child = null;
        }
        if (!child?.metadata?.uid) {
          unresolved.push(ref);
          continue;
        }
        const id = child.metadata.uid;
        if (!seen.has(id)) {
          seen.add(id);
          const node = { id, object: child, depth, plural: info.name };
          nodes.push(node);
          next.push(node);
        }
        const edgeId = `${parent.id}-${id}`;
        if (!edges.some(e => e.id === edgeId)) {
          edges.push({ id: edgeId, source: parent.id, target: id });
        }
      }
    }
    frontier = next;
  }

  return { nodes, edges, unresolved };
}

/**
 * Adds the objects that are transitively owned by something already in the
 * tree: Deployment → ReplicaSet → Pod, CronJob → Job → Pod. Candidates are
 * whole-namespace listings, so most of them belong to other apps and are
 * dropped. Repeated until nothing new attaches, which is what makes the result
 * independent of the order candidates arrive in.
 */
export function attachOwned(tree: AppTree, candidates: KubeJSON[]): AppTree {
  const nodes = tree.nodes.slice();
  const edges = tree.edges.slice();
  const byId = new Map(nodes.map(n => [n.id, n]));
  const edgeIds = new Set(edges.map(e => e.id));

  let added = true;
  while (added) {
    added = false;
    for (const c of candidates) {
      const uid = c.metadata?.uid;
      if (!uid) continue;
      for (const owner of c.metadata.ownerReferences ?? []) {
        const parent = byId.get(owner.uid);
        if (!parent) continue;
        if (!byId.has(uid)) {
          const node = { id: uid, object: c, depth: parent.depth + 1 };
          nodes.push(node);
          byId.set(uid, node);
          added = true;
        }
        const edgeId = `${owner.uid}-${uid}`;
        if (!edgeIds.has(edgeId)) {
          edges.push({ id: edgeId, source: owner.uid, target: uid });
          edgeIds.add(edgeId);
          added = true;
        }
      }
    }
  }

  return { nodes, edges, unresolved: tree.unresolved };
}
