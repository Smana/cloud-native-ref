// Registrations for the App view plugin. Every register* call lives here; the
// pages and the map source are imported from their own modules.
import { registerSidebarEntry } from '@kinvolk/headlamp-plugin/lib';

registerSidebarEntry({
  name: 'ogenki-apps',
  label: 'Apps',
  icon: 'mdi:apps',
  url: '/apps',
});
