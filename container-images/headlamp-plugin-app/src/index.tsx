// Registrations for the App view plugin. Every register* call lives here; the
// pages and the map source are imported from their own modules.
import { Icon } from '@iconify/react';
import {
  registerKindIcon,
  registerRoute,
  registerSidebarEntry,
} from '@kinvolk/headlamp-plugin/lib';
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

// So an App is recognisable wherever a node is drawn.
registerKindIcon(APP_KIND, { icon: <Icon icon="mdi:apps" width="100%" height="100%" /> });

registerAppsMapSource();
