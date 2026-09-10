// The App claim as a Headlamp KubeObject. Split out of app.ts because this
// import only resolves inside a running Headlamp host (it is a virtual path:
// backed by a tsconfig `paths` entry for tsc and a Rollup `external` + global
// for the production bundle, with no real file on disk for either) — pulling
// it into app.ts would make tree.ts's import of `resourceRefs` drag this
// module's evaluation into vitest, which has neither. Nothing here is unit
// tested for the same reason; see src/tree.test.ts for what is.
import { KubeObject } from '@kinvolk/headlamp-plugin/lib/K8s/cluster';

export const APP_API_VERSION = 'cloud.ogenki.io/v1alpha1';
export const APP_KIND = 'App';

/**
 * The App claim, as a Headlamp KubeObject so useList/useGet work on it.
 *
 * No `<KubeJSON>` type argument: KubeJSON.metadata.creationTimestamp is
 * optional (part of the documented contract tree.ts and its tests rely on),
 * while Headlamp's own KubeMetadata requires it — the two are structurally
 * incompatible. KubeObject's generic defaults to `any`, which this relies on.
 */
export class AppResource extends KubeObject {
  static apiVersion = APP_API_VERSION;
  static apiName = 'apps';
  static kind = APP_KIND;
  static isNamespaced = true;
}
