"""Shared PyYAML setup for the flux-schema scripts (render-bundle, diff-bundles).

libyaml-backed loader/dumper when the wheel ships it (5-10x faster on the
multi-MB bundles both scripts round-trip); pure-Python fallback keeps a
libyaml-less PyYAML build working.
"""
import yaml

YAML_LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
YAML_DUMPER = getattr(yaml, "CSafeDumper", yaml.SafeDumper)

# PyYAML 1.1-spec quirk, not a real document defect: a bare, unquoted `=`
# scalar (e.g. an enum member `- =`, as in the prometheus-operator-crds
# chart's AlertmanagerConfig CRD matchType enum: `!=`, `=`, `=~`, `!~`) is
# reserved as the special "default value" tag `tag:yaml.org,2002:value`, for
# which SafeLoader registers no constructor - loading then raises
# ConstructorError on an otherwise perfectly valid document. Treat it as the
# plain string it is; this is the standard workaround (see pyyaml/pyyaml#89).
YAML_LOADER.add_constructor(
    "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
)
