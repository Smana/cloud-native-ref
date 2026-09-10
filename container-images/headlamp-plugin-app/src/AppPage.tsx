// One App, everything about it. The graph comes first because it is the answer
// to "what does this app actually consist of, and is any of it unhealthy".
import { Icon } from '@iconify/react';
import {
  ActionButton,
  Link,
  LogsButton,
  ObjectEventList,
  SectionBox,
  SimpleTable,
  StatusLabel,
} from '@kinvolk/headlamp-plugin/lib/CommonComponents';
import { getCluster } from '@kinvolk/headlamp-plugin/lib/Utils';
import { Alert, Box, Button, Chip, Typography } from '@mui/material';
import { useMemo } from 'react';
import { useParams } from 'react-router-dom';
import type { KubeJSON } from './app';
import { useConfigLinks } from './client';
import { wrapKubeObject } from './kubeWrap';
import { expandLink } from './links';
import { appTreeSource } from './mapSource';
import { conditionOf, nodeStatus } from './status';
import { useAppTree } from './useAppTree';

// Headlamp 0.45.0 exports GraphView through pluginLib.ResourceMap; the pinned
// plugin toolkit (0.14.0) predates that, so a bare import resolves to
// undefined. Read the runtime global instead — see headlamp-plugin.d.ts.
const GraphView = window.pluginLib?.ResourceMap?.GraphView;

function ConditionChip({ app, type }: { app: KubeJSON; type: string }) {
  const c = conditionOf(app, type);
  const status = c?.status === 'True' ? 'success' : c?.status === 'False' ? 'error' : 'warning';
  return (
    <StatusLabel status={status} title={c?.message}>
      {type}: {c?.status ?? 'Unknown'}
    </StatusLabel>
  );
}

export function AppPage() {
  const { namespace, name } = useParams<{ namespace: string; name: string }>();
  const cluster = getCluster();
  const { app, tree, error } = useAppTree(namespace, name);
  const links = useConfigLinks();

  const source = useMemo(() => appTreeSource(tree), [tree]);
  const namespaceFilter = useMemo(
    () => [{ type: 'namespace' as const, namespaces: new Set([namespace]) }],
    [namespace],
  );

  if (error) {
    return (
      <SectionBox title={`App: ${name}`}>
        <Alert severity="warning">{error}</Alert>
        <Box mt={2}>
          <Link to={`/c/${cluster}/apps`}>Back to Apps</Link>
        </Box>
      </SectionBox>
    );
  }

  if (!app || !tree) {
    return <SectionBox title={`App: ${name}`}>Loading…</SectionBox>;
  }

  const image = app.spec?.image ? [app.spec.image.repository, app.spec.image.tag].filter(Boolean).join(':') : '';
  const hostname = app.spec?.route?.enabled ? app.spec.route.hostname : undefined;

  // Everything except the App itself and its Pods: the composed inventory.
  const composed = tree.nodes.filter(n => n.id !== app.metadata.uid && n.object.kind !== 'Pod');
  const pods = tree.nodes.filter(n => n.object.kind === 'Pod');
  const workloads = tree.nodes.filter(n => n.object.kind === 'Deployment' || n.object.kind === 'CronJob');

  return (
    <>
      <SectionBox title={`App: ${app.metadata.name}`} backLink={`/c/${cluster}/apps`}>
        <Box display="flex" flexWrap="wrap" alignItems="center" gap={1} mb={1}>
          <ConditionChip app={app} type="Ready" />
          <ConditionChip app={app} type="Synced" />
          <Chip size="small" label={`namespace: ${namespace}`} />
          {image && <Chip size="small" label={image} />}
          <ActionButton
            description="Open the raw App resource"
            icon="mdi:code-braces"
            onClick={() => {
              window.location.href = `/c/${cluster}/customresources/apps.cloud.ogenki.io/${namespace}/${name}`;
            }}
          />
          {hostname && (
            <Chip
              size="small"
              icon={<Icon icon="mdi:web" />}
              label={hostname}
              component="a"
              href={`https://${hostname}`}
              target="_blank"
              rel="noopener noreferrer"
              clickable
            />
          )}
        </Box>
        {tree.unresolved.length > 0 && (
          <Alert severity="info">
            {tree.unresolved.length} composed resource
            {tree.unresolved.length === 1 ? '' : 's'} could not be read (not created yet, or not
            permitted): {tree.unresolved.map(r => `${r.kind}/${r.name}`).join(', ')}
          </Alert>
        )}
      </SectionBox>

      <SectionBox title="Map">
        {GraphView ? (
          <GraphView
            height="60vh"
            defaultSources={[source]}
            defaultNodeSelection={app.metadata.uid}
            defaultFilters={namespaceFilter}
          />
        ) : (
          <Alert severity="warning">
            This Headlamp is older than 0.45.0, which is the release that lets a plugin embed the
            resource map. Falling back to the global map.{' '}
            <Link to={`/c/${cluster}/map?namespace=${namespace}&node=${app.metadata.uid}`}>
              Open this app in the map
            </Link>
          </Alert>
        )}
      </SectionBox>

      <SectionBox title={`Composed resources (${composed.length})`}>
        <SimpleTable
          columns={[
            { label: 'Kind', getter: (n: (typeof composed)[0]) => n.object.kind },
            {
              label: 'Name',
              getter: (n: (typeof composed)[0]) => (
                <Link kubeObject={wrapKubeObject(n.object)}>{n.object.metadata.name}</Link>
              ),
            },
            {
              label: 'Status',
              getter: (n: (typeof composed)[0]) => (
                <StatusLabel status={nodeStatus(n.object)}>{nodeStatus(n.object)}</StatusLabel>
              ),
            },
            { label: 'Age', getter: (n: (typeof composed)[0]) => n.object.metadata.creationTimestamp ?? '' },
          ]}
          data={composed}
          emptyMessage="No composed resources resolved."
        />
      </SectionBox>

      <SectionBox title={`Pods (${pods.length})`}>
        <SimpleTable
          columns={[
            {
              label: 'Name',
              getter: (n: (typeof pods)[0]) => (
                <Link kubeObject={wrapKubeObject(n.object)}>{n.object.metadata.name}</Link>
              ),
            },
            { label: 'Phase', getter: (n: (typeof pods)[0]) => n.object.status?.phase ?? '' },
            {
              label: 'Restarts',
              getter: (n: (typeof pods)[0]) =>
                (n.object.status?.containerStatuses ?? []).reduce(
                  (sum: number, c: { restartCount?: number }) => sum + (c.restartCount ?? 0),
                  0,
                ),
            },
          ]}
          data={pods}
          emptyMessage="No pods."
        />
        {workloads.map(w => (
          <Box key={w.id} mt={2} display="flex" alignItems="center" gap={1}>
            <Typography variant="subtitle2">{`${w.object.kind}/${w.object.metadata.name}`}</Typography>
            <LogsButton item={wrapKubeObject(w.object)} />
          </Box>
        ))}
      </SectionBox>

      <SectionBox title="Events">
        <ObjectEventList object={wrapKubeObject(app)} />
      </SectionBox>

      {links.length > 0 && (
        <SectionBox title="Links">
          <Box display="flex" flexWrap="wrap" gap={1}>
            {links.map(l => (
              <Button
                key={l.label}
                variant="outlined"
                size="small"
                href={expandLink(l.url, { namespace, name })}
                target="_blank"
                rel="noopener noreferrer"
                endIcon={<Icon icon="mdi:open-in-new" />}
              >
                {l.label}
              </Button>
            ))}
          </Box>
        </SectionBox>
      )}
    </>
  );
}
