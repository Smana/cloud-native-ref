// Registrations for the App view plugin. Every register* call lives here; the
// pages and the map source are imported from their own modules.
import { Icon } from '@iconify/react';
import {
  registerDetailsViewHeaderAction,
  registerKindIcon,
  registerRoute,
  registerSidebarEntry,
} from '@kinvolk/headlamp-plugin/lib';
import { ActionButton } from '@kinvolk/headlamp-plugin/lib/CommonComponents';
import { getCluster } from '@kinvolk/headlamp-plugin/lib/Utils';
import { AppPage } from './AppPage';
import { APP_KIND } from './appResource';
import { AppsListPage } from './AppsListPage';
import { registerAppsMapSource } from './mapSource';

registerSidebarEntry({
  name: 'ogenki-apps',
  label: 'Apps',
  icon: 'mdi:apps',
  url: '/apps',
});

registerRoute({
  path: '/apps',
  exact: true,
  name: 'Apps',
  sidebar: 'ogenki-apps',
  component: AppsListPage,
});

registerRoute({
  path: '/apps/:namespace/:name',
  exact: true,
  name: 'App',
  sidebar: 'ogenki-apps',
  component: AppPage,
});

// So an App is recognisable wherever a node is drawn.
registerKindIcon(APP_KIND, { icon: <Icon icon="mdi:apps" width="100%" height="100%" /> });

registerAppsMapSource();

// On Headlamp's own page for an App resource, offer the richer view.
function OpenAppViewAction({ item }: { item: any }) {
  if (!item || item.kind !== APP_KIND) return null;
  const cluster = getCluster();
  return (
    <ActionButton
      description="Open App view"
      icon="mdi:sitemap-outline"
      onClick={() => {
        window.location.href = `/c/${cluster}/apps/${item.metadata.namespace}/${item.metadata.name}`;
      }}
    />
  );
}

registerDetailsViewHeaderAction(OpenAppViewAction);
