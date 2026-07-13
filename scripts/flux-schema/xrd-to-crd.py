#!/usr/bin/env python3
"""Convert Crossplane CompositeResourceDefinitions into CustomResourceDefinitions.

`flux schema extract crd` reads CRDs, not XRDs. The shapes are nearly identical,
but Crossplane injects fields into the CRDs it generates that the XRD never
declares — notably `spec.crossplane`. Omitting them makes in-use manifests
(harbor/zitadel SQLInstance) fail validation with
`additional properties 'crossplane' not allowed`. See SPEC-007 FR-003.
"""
import sys
import pathlib
import yaml

# Fields Crossplane v2 injects into every generated composite/XR CRD.
CROSSPLANE_INJECTED = {
    "crossplane": {
        "type": "object",
        "properties": {
            "compositionRef": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
            },
            "compositionRevisionRef": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
            },
            "compositionSelector": {
                "type": "object",
                "properties": {
                    "matchLabels": {
                        "type": "object",
                        "additionalProperties": {"type": "string"},
                    }
                },
            },
            "compositionRevisionSelector": {
                "type": "object",
                "properties": {
                    "matchLabels": {
                        "type": "object",
                        "additionalProperties": {"type": "string"},
                    }
                },
            },
            "compositionUpdatePolicy": {"type": "string"},
            "resourceRefs": {"type": "array", "items": {"type": "object"}},
        },
    }
}


def convert(xrd):
    spec = xrd["spec"]
    versions = []
    for version in spec["versions"]:
        schema = version["schema"]["openAPIV3Schema"]
        props = schema.setdefault("properties", {})
        spec_props = props.setdefault("spec", {"type": "object"}).setdefault(
            "properties", {}
        )
        for name, definition in CROSSPLANE_INJECTED.items():
            spec_props.setdefault(name, definition)
        versions.append(
            {
                "name": version["name"],
                "served": version.get("served", True),
                "storage": True,
                "schema": {"openAPIV3Schema": schema},
            }
        )
    return {
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {"name": xrd["metadata"]["name"]},
        "spec": {
            "group": spec["group"],
            "scope": spec.get("scope", "Namespaced"),
            "names": spec["names"],
            "versions": versions,
        },
    }


def main():
    crds = []
    for path in sys.argv[1:]:
        for doc in yaml.safe_load_all(pathlib.Path(path).read_text()):
            if doc and doc.get("kind") == "CompositeResourceDefinition":
                crds.append(convert(doc))
    if not crds:
        print("error: no CompositeResourceDefinition found", file=sys.stderr)
        return 1
    yaml.safe_dump_all(crds, sys.stdout, sort_keys=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
