// Every App the viewer can see. The name links to the plugin's own page, which
// is the URL the App Wizard builds.
import { Link, ResourceListView, StatusLabel } from '@kinvolk/headlamp-plugin/lib/CommonComponents';
import { getCluster } from '@kinvolk/headlamp-plugin/lib/Utils';
import { type KubeJSON } from './app';
import { AppResource } from './appResource';
import { conditionOf } from './status';

function conditionChip(app: AppResource, type: string) {
  const c = conditionOf(app.jsonData as KubeJSON, type);
  const status = c?.status === 'True' ? 'success' : c?.status === 'False' ? 'error' : 'warning';
  return (
    <StatusLabel status={status} title={c?.message}>
      {c?.status ?? 'Unknown'}
    </StatusLabel>
  );
}

export function AppsListPage() {
  const cluster = getCluster();
  return (
    <ResourceListView
      title="Apps"
      resourceClass={AppResource}
      columns={[
        {
          id: 'name',
          label: 'Name',
          getValue: (app: AppResource) => app.metadata.name,
          render: (app: AppResource) => (
            <Link to={`/c/${cluster}/apps/${app.metadata.namespace}/${app.metadata.name}`}>
              {app.metadata.name}
            </Link>
          ),
        },
        'namespace',
        {
          id: 'ready',
          label: 'Ready',
          getValue: (app: AppResource) =>
            conditionOf(app.jsonData as KubeJSON, 'Ready')?.status ?? 'Unknown',
          render: (app: AppResource) => conditionChip(app, 'Ready'),
        },
        {
          id: 'synced',
          label: 'Synced',
          getValue: (app: AppResource) =>
            conditionOf(app.jsonData as KubeJSON, 'Synced')?.status ?? 'Unknown',
          render: (app: AppResource) => conditionChip(app, 'Synced'),
        },
        {
          id: 'image',
          label: 'Image',
          getValue: (app: AppResource) => {
            const img = (app.jsonData as KubeJSON).spec?.image;
            return img ? [img.repository, img.tag].filter(Boolean).join(':') : '';
          },
        },
        'age',
      ]}
    />
  );
}
