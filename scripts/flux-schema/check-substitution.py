#!/usr/bin/env python3
"""Fail when a Flux Kustomization applies `${var}` but declares no postBuild.

The gap this closes, measured 2026-08-25:

`clusters/gcp-0/infrastructure/infrastructure.yaml` had no
`spec.postBuild.substituteFrom`. Its path then gained the first manifests under
it to reference `${project_id}` and `${private_domain_name}`. Flux applies the
literal text when substitution is not wired, so a `GCPWorkloadIdentity` claim
would have reached the API server with

    roles: ["projects/${project_id}/roles/xplane_dns_editor"]

which fails the XRD's `roles[]` pattern -- `$`, `{`, `}` are not in the allowed
charset -- taking the whole `infrastructure` Kustomization down with it.

`validate-manifests.sh` could not see it. render-bundle.py substitutes its
FIXTURE_VARS unconditionally, so the bundle shows what Flux WOULD render if
substitution were wired, never whether it is. The gate passed on an undeployable
manifest.

Fixing that inside the renderer would mean coupling it to the cluster's
Kustomization graph, which its own `top_most_overlays` docstring explains it
deliberately avoids. So this is a separate, narrow check that reads the
Kustomizations directly -- the source of truth the renderer only approximates.

WHY `kustomize build` RATHER THAN GREPPING THE DIRECTORY: a kustomization may
reference files outside its own tree (`../../base/foo.yaml`), which this repo
does deliberately and often. Grepping only the path's own directory misses
those, which is a false negative on exactly the interesting cases. Building the
overlay renders what Flux actually applies.

Deliberately NOT checked here: whether each `${var}` is a key of the ConfigMap
named in `substituteFrom`. Those keys come from OpenTofu
(`opentofu/*/configure/kubernetes.tf`), and parsing HCL to find out would trade
a precise check for a fragile one. An undefined variable is a different failure
with a different fix.
"""
import pathlib
import re
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CLUSTERS_DIR = REPO_ROOT / "clusters"
KUSTOMIZE_BIN = "kustomize"

# Matches ${var}. `$${var}` (the Grafana-dashboard escape that survives Flux
# substitution on purpose) also contains a `${var}`, so it is excluded first --
# otherwise every dashboard JSON would be a false positive.
VAR_RE = re.compile(r"(?<!\$)\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}")
ESCAPED_RE = re.compile(r"\$\$\{[a-zA-Z_][a-zA-Z0-9_]*\}")


def flux_kustomizations():
    """Every Flux Kustomization under clusters/, with its path and postBuild."""
    try:
        import yaml
    except ImportError:
        print("error: PyYAML is required", file=sys.stderr)
        sys.exit(2)

    for f in sorted(CLUSTERS_DIR.rglob("*.yaml")):
        for doc in yaml.safe_load_all(f.read_text()):
            if not isinstance(doc, dict):
                continue
            if doc.get("kind") != "Kustomization":
                continue
            if not str(doc.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io/"):
                continue
            spec = doc.get("spec") or {}
            yield {
                "file": f.relative_to(REPO_ROOT),
                "name": (doc.get("metadata") or {}).get("name", "<unnamed>"),
                "path": (spec.get("path") or "").lstrip("./"),
                "post_build": spec.get("postBuild") or {},
                "suspended": bool(spec.get("suspend")),
            }


def rendered_vars(path):
    """Variables in what Flux would apply for this path, or None if unreadable.

    Two shapes, because Flux accepts both:

    - A kustomize root (has kustomization.yaml) -- build it, because a
      kustomization may reference files outside its own tree
      (`../../base/foo.yaml`), which this repo does deliberately. Grepping the
      directory alone would miss those, a false negative on the interesting
      cases.
    - A plain directory of manifests (no kustomization.yaml) -- flux/sources,
      flux/notifications and flux/observability are applied this way. Scan the
      YAML directly. An earlier version of this check returned None for these
      and skipped them, which was a blind spot of exactly the kind it exists to
      remove.
    """
    target = REPO_ROOT / path
    if not target.is_dir():
        return None

    if (target / "kustomization.yaml").is_file():
        proc = subprocess.run(
            [KUSTOMIZE_BIN, "build", str(target), "--load-restrictor=LoadRestrictionsNone"],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            return None
        text = proc.stdout
    else:
        text = "\n".join(
            f.read_text(errors="replace") for f in sorted(target.rglob("*.yaml"))
        )

    text = ESCAPED_RE.sub("", text)
    return sorted(set(VAR_RE.findall(text)))


def main():
    failures = []
    checked = 0
    skipped = []

    for k in flux_kustomizations():
        if not k["path"]:
            continue
        variables = rendered_vars(k["path"])
        if variables is None:
            # Not a kustomize root in this repo (a remote source, or a path
            # built from an ExternalArtifact that is not on disk here).
            skipped.append(f"{k['name']} ({k['path']})")
            continue
        checked += 1
        if not variables:
            continue
        wired = bool(k["post_build"].get("substituteFrom") or k["post_build"].get("substitute"))
        if not wired:
            failures.append(
                f"  {k['file']}\n"
                f"    Kustomization/{k['name']} path={k['path']}\n"
                f"    renders {len(variables)} variable(s) with NO spec.postBuild: "
                f"{', '.join('${' + v + '}' for v in variables)}\n"
                f"    -> Flux would apply the literal text. Add:\n"
                f"         postBuild:\n"
                f"           substituteFrom:\n"
                f"             - kind: ConfigMap\n"
                f"               name: <cluster>-vars"
            )

    if skipped:
        print(f"note: {len(skipped)} Kustomization(s) not buildable from this repo, not checked:")
        for s in skipped:
            print(f"  - {s}")

    if failures:
        print(
            f"\nFAIL: {len(failures)} Flux Kustomization(s) apply substituted "
            f"manifests without postBuild wired:\n",
            file=sys.stderr,
        )
        for f in failures:
            print(f, file=sys.stderr)
            print(file=sys.stderr)
        print(
            "This is invisible to validate-manifests.sh: render-bundle.py substitutes "
            "its fixtures unconditionally, so the bundle shows what Flux WOULD render "
            "if substitution were wired, not whether it is.",
            file=sys.stderr,
        )
        return 1

    print(f"==> {checked} Flux Kustomization(s) checked; substitution wiring is consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
