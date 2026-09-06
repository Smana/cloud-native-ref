#!/usr/bin/env python3
"""diagram-icons.py — the icon library behind docs/architecture/*.drawio.

Two jobs, because they share the same catalogue and would otherwise drift:

  style <name> [label]   emit a ready-to-paste ogenki label style with the logo
                         embedded, so a diagram never hand-rolls a data URI
  audit [--all]          list boxes that name a product and render without one

Why a library at all: the seventeen logos this platform uses were rasterised
once, for platform-overview.drawio, and were unreachable from any other file for
the life of the repo. Five of ten single-page diagrams had zero icons across 206
vertices as a result. Extracting them means a diagram references an asset rather
than re-fetching and re-rasterising its own copy.

PNG, not SVG, throughout: headless drawio export does not render SVG data URIs.
And the payload is joined with a comma (`data:image/png,<base64>`), never
`;base64,` — the semicolon terminates the mxCell style value and silently
produces a box with no image.

The audit is ADVISORY and deliberately not a CI gate. Whether a box wants a logo
is a judgment call — an icon on a box whose subject is a concept, not a product,
labels the wrong thing — and a gate that can go red on a judgment call gets
switched off. Run it when editing diagrams; act on what it finds, or don't.
"""
import argparse
import base64
import glob
import html
import json
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, 'docs', 'architecture', 'icons')
SRC = os.path.join(ROOT, 'docs', 'architecture')

# The ogenki preset's icon convention: logo left, text right.
LABEL_STYLE = (
    'shape=label;rounded=1;absoluteArcSize=1;arcSize=10;shadow=1;whiteSpace=wrap;html=1;'
    'image=data:image/png,{payload};'
    'imageAlign=left;imageVerticalAlign=middle;imageWidth=24;imageHeight=24;'
    'spacingLeft=42;align=left;'
    'fillColor={fill};strokeColor={stroke};strokeWidth=1.5;'
    'fontColor=#1E293B;fontFamily=Helvetica;fontSize=11;'
)

# ogenki palette, by role. Mirrors ~/.drawio-skill/styles/ogenki.json.
PALETTE = {
    'service': ('#EEF2FF', '#6366F1'),
    'security': ('#EDE9FE', '#7C3AED'),
    'data': ('#D1FAE5', '#059669'),
    'external': ('#F1F5F9', '#94A3B8'),
    'warning': ('#FEF3C7', '#F59E0B'),
}

# Products this platform draws, and where a logo comes from.
#   local  -> docs/architecture/icons/ (no network)
#   vendor -> an mxgraph stencil; no embedding at all, just a style string
#   cncf   -> github.com/cncf/artwork projects/<slug>/icon/color/
#   brand  -> the project's own brand page; aiicons.py resolves many of them
CATALOG = {
    'cert-manager': 'local', 'cilium': 'local', 'crossplane': 'local',
    'eks': 'local', 'envoy': 'local', 'flux': 'local', 'github': 'local',
    'grafana': 'local', 'harbor': 'local', 'karpenter': 'local',
    'keda': 'local', 'kyverno': 'local', 'openbao': 'local',
    'tailscale': 'local', 'victoriametrics': 'local', 'victorialogs': 'local',
    'victoriatraces': 'local', 'vllm': 'local',

    'kubernetes': 'vendor', 'gke': 'vendor', 'bottlerocket': 'vendor',
    's3': 'vendor', 'kms': 'vendor', 'route53': 'vendor', 'iam': 'vendor',
    'gcs': 'vendor', 'vpc': 'vendor', 'secrets manager': 'vendor',

    'opentofu': 'cncf', 'cloudnativepg': 'cncf', 'valkey': 'cncf',
    'prometheus': 'cncf', 'opentelemetry': 'cncf', 'gateway api': 'cncf',
    'helm': 'cncf', 'kustomize': 'cncf',
    'external secrets': 'cncf',  # pragma: allowlist secret
    'alertmanager': 'cncf', 'trivy': 'cncf',

    'terramate': 'brand', 'zitadel': 'brand', 'vector': 'brand',
    'postgres': 'brand', 'atlas': 'brand', 'renovate': 'brand',
    'slack': 'brand', 'huggingface': 'brand', 'nvidia': 'brand',
    'openwebui': 'brand', 'wireguard': 'brand', 'polaris': 'brand',
    'checkov': 'brand',
}


def load_manifest():
    with open(os.path.join(ICONS, 'manifest.json')) as fh:
        return json.load(fh)


def resolve(name):
    """Map a library name (following aliases) to its PNG path."""
    m = load_manifest()
    name = m.get('aliases', {}).get(name, name)
    entry = m['icons'].get(name)
    if not entry:
        known = ', '.join(sorted(list(m['icons']) + list(m.get('aliases', {}))))
        sys.exit(f"unknown icon '{name}'. Available: {known}")
    return os.path.join(ICONS, entry['file']), entry['label']


def cmd_style(args):
    path, default_label = resolve(args.name)
    with open(path, 'rb') as fh:
        payload = base64.b64encode(fh.read()).decode()
    fill, stroke = PALETTE[args.role]
    print(f"<!-- {args.label or default_label} · role={args.role} -->")
    print(LABEL_STYLE.format(payload=payload, fill=fill, stroke=stroke))


def cmd_audit(args):
    rows = defaultdict(list)
    for path in sorted(glob.glob(os.path.join(SRC, '*.drawio'))):
        doc = open(path).read()
        name = os.path.basename(path)[:-7]
        for m in re.finditer(r'<mxCell id="([^"]+)" value="([^"]{3,})" style="([^"]*)"', doc):
            cid, val, style = m.groups()
            if 'edgeStyle' in style or 'fillColor=' not in style:
                continue                      # edges and floating text are not boxes
            text = re.sub(r'<br\s*/?>|&#xa;|&#10;', '\n', val)
            text = html.unescape(re.sub(r'<[^>]+>', ' ', text))
            # A box's SUBJECT is its first line. A product named further down is
            # mentioned in passing, and an icon there labels the wrong thing --
            # unless --all is given, in which case report those too.
            scope = text.lower() if args.all else text.split('\n')[0].lower()
            if 'image=data:image' in style or 'mxgraph.' in style:
                continue
            hits = sorted({t for t in CATALOG
                           if re.search(r'(?<![a-z0-9])' + re.escape(t) + r'(?![a-z0-9])', scope)})
            if hits:
                rows[name].append((cid, hits, CATALOG[hits[0]]))

    by_source = defaultdict(int)
    total = 0
    for name in sorted(rows):
        print(f"\n{name}")
        for cid, hits, src in rows[name]:
            total += 1
            by_source[src] += 1
            print(f"   {cid:14} {src:7} {', '.join(hits)}")

    print(f"\n{total} boxes name a product with an available logo and render without one.")
    for src in ('local', 'vendor', 'cncf', 'brand'):
        if by_source[src]:
            how = {
                'local': "docs/architecture/icons/ — ./scripts/diagram-icons.py style <name>",
                'vendor': "an mxgraph stencil — shapesearch.py, no embedding needed",
                'cncf': "github.com/cncf/artwork — fetch, then rsvg-convert -w 64 -h 64",
                'brand': "the project's brand page — aiicons.py --embed, then rasterise",
            }[src]
            print(f"  {by_source[src]:>4} {src:7} {how}")
    print("\nAdvisory, not a gate: whether a box wants a logo is a judgment call.")


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('style', help='emit a paste-ready styled label with the logo embedded')
    s.add_argument('name', help='library name, e.g. cilium (see icons/manifest.json)')
    s.add_argument('label', nargs='?', help='override the comment label')
    s.add_argument('--role', default='service', choices=sorted(PALETTE),
                   help='ogenki palette role (default: service)')
    s.set_defaults(func=cmd_style)

    a = sub.add_parser('audit', help='list boxes that name a product and have no icon')
    a.add_argument('--all', action='store_true',
                   help='also report products named below the title line')
    a.set_defaults(func=cmd_audit)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
