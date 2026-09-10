// Jump-off links, supplied by an optional ConfigMap so they are GitOps-managed
// and per-cluster. JSON rather than YAML: a ConfigMap value is a string either
// way, and JSON needs no parser in the bundle. Anything malformed yields no
// links — the section simply does not render.
export interface LinkTemplate {
  label: string;
  url: string;
}

export function parseLinks(raw: string | undefined): LinkTemplate[] {
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const out: LinkTemplate[] = [];
  for (const entry of parsed) {
    const label = (entry as LinkTemplate)?.label;
    const url = (entry as LinkTemplate)?.url;
    if (typeof label !== 'string' || typeof url !== 'string' || !label || !url) return [];
    if (!/^https?:\/\//.test(url)) continue;
    out.push({ label, url });
  }
  return out;
}

export function expandLink(url: string, app: { namespace: string; name: string }): string {
  const values: Record<string, string> = { namespace: app.namespace, name: app.name };
  return url.replace(/\{(namespace|name)\}/g, (_m, key: string) => encodeURIComponent(values[key]));
}
