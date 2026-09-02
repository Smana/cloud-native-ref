#!/usr/bin/env python3
"""Fail when a Flux Kustomization's variable substitution is wired wrong.

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

Also checked: whether each `${var}` is a key of the ConfigMap named in
`substituteFrom`. This was previously left out on the grounds that parsing HCL
to find out would trade a precise check for a fragile one -- true of a general
HCL parser, but the two `flux_cluster_vars` resources this needs
(`opentofu/*/configure/kubernetes.tf`) share a shape with no heredoc, nested
brace, ternary or list in their `data = {}` block, so an anchored read of
`key = value` lines is exactly as precise as the postBuild-wiring check above,
not a looser approximation of one. An undefined variable does not fail to
render -- Flux substitutes an empty string, which is schema-valid and silently
wrong. `substitute` (inline key/values in postBuild, as opposed to
`substituteFrom`) is a separate mechanism and is not checked here.

A `substituteFrom` entry may also name a `kind: Secret`. **No such case exists
repo-wide today**: the last one was `${cert_manager_approle_id}`, supplied by the
`cert-manager-openbao-approle` Secret, and it went away when cert-manager
switched to a projected ServiceAccount token against the per-cluster JWT mount.
The handling below is kept for the next one, and the run prints which
Kustomization carries it, so nobody has to hunt for a path from this docstring.
A Secret's keys are not on disk, so they cannot be checked the way a
ConfigMap's can. A Kustomization whose `substituteFrom` is ConfigMap-only still
fails strictly on a missing key; one that also names a Secret gets a printed
note instead of a failure when a variable is missing from every ConfigMap ref,
naming the variable and the Secret that may supply it -- reported, not silently
skipped, so a second such case does not vanish the way it did before this file
could see it at all.
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

# The two cluster vars ConfigMaps, and the OpenTofu that declares them. Only
# these two names appear in any substituteFrom in clusters/ (28 and 11 uses);
# an unrecognised name is a mistake, not a case to skip.
CONFIGMAP_SOURCES = {
    "eks-aws-0-vars": "opentofu/aws/eks/configure/kubernetes.tf",
    "gke-gcp-0-vars": "opentofu/gcp/gke/configure/kubernetes.tf",
}

# Anchored on the resource name and the `data = {` inside it, NOT a general HCL
# parse -- this file's own docstring rightly calls that fragile. The block is
# plain `key = value` lines: no heredocs, nested braces, ternaries or lists.
_RESOURCE_RE = re.compile(r'resource\s+"kubectl_manifest"\s+"flux_cluster_vars"\s*\{')
_KEY_RE = re.compile(r"^\s+([a-z_][a-z0-9_]*)\s*=")


def configmap_keys(name):
    """Keys of a cluster vars ConfigMap, read from the OpenTofu that creates it.

    Raises rather than returning an empty set. An empty set would make every
    variable look undefined; a silently skipped file would make every variable
    look fine. Both are worse failures than a crash, because both look like a
    passing gate.
    """
    rel = CONFIGMAP_SOURCES.get(name)
    if rel is None:
        raise SystemExit(
            f"error: no OpenTofu source known for ConfigMap {name!r}.\n"
            f"       Known: {', '.join(sorted(CONFIGMAP_SOURCES))}.\n"
            f"       A new cluster vars ConfigMap must be added to CONFIGMAP_SOURCES."
        )
    path = REPO_ROOT / rel
    text = path.read_text()

    m = _RESOURCE_RE.search(text)
    if not m:
        raise SystemExit(
            f"error: {rel} no longer contains "
            f'resource "kubectl_manifest" "flux_cluster_vars".\n'
            f"       This check reads that block for the ConfigMap's keys; it cannot\n"
            f"       verify anything without it. Update _RESOURCE_RE if the resource\n"
            f"       was renamed."
        )

    lines = text[m.end():].splitlines()
    keys, in_data = set(), False
    for line in lines:
        stripped = line.strip()
        if not in_data:
            if stripped.startswith("data") and stripped.endswith("{"):
                in_data = True
            continue
        if stripped == "}":
            break
        if stripped.startswith("#"):
            continue
        km = _KEY_RE.match(line)
        if km:
            keys.add(km.group(1))

    if not keys:
        raise SystemExit(
            f"error: found no keys in {rel}'s flux_cluster_vars data block.\n"
            f"       The block shape changed. Refusing to report every variable as\n"
            f"       undefined on the strength of a parse that found nothing."
        )
    return keys


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


def classify_missing(variables, refs, configmap_keys=configmap_keys):
    """Split applied `variables` that no ConfigMap ref in `refs` defines into
    (missing_failing, missing_unattributable).

    `refs` is a postBuild.substituteFrom list: [{"kind": ..., "name": ...}, ...].
    `configmap_keys` is injectable -- default is the module's real OpenTofu-backed
    lookup, but a test can pass a synthetic `name -> set-of-keys` callable instead,
    so this logic is testable without touching opentofu/ or clusters/.

    - Empty `refs` (a Kustomization wired only via inline `postBuild.substitute`,
      never via `substituteFrom`) is not checked here -- `substitute` is a
      separate mechanism -- so both lists come back empty.
    - `missing_failing`: variables absent from every ConfigMap ref, when EVERY
      ref in `refs` is kind: ConfigMap. This is the strict, no-false-positive
      case -- Flux would substitute an empty string for these.
    - `missing_unattributable`: variables absent from every ConfigMap ref, when
      at least one ref is kind: Secret. A Secret's keys are created in-cluster
      at runtime by External Secrets, so there is nothing on disk to compare
      against -- these might still be supplied, so they are reported, not
      failed.
    """
    if not refs:
        return [], []

    defined = set()
    for ref in refs:
        if ref.get("kind") == "ConfigMap":
            defined |= configmap_keys(ref["name"])
    missing = [v for v in variables if v not in defined]
    if not missing:
        return [], []

    if any(ref.get("kind") == "Secret" for ref in refs):
        return [], missing
    return missing, []


def main():
    failures = []
    checked = 0
    skipped = []
    unattributable = []

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
            continue

        refs = k["post_build"].get("substituteFrom", [])
        missing_failing, missing_unattributable = classify_missing(variables, refs)

        if missing_unattributable:
            # See classify_missing's docstring for why these are reported
            # rather than failed or silently skipped. NO Secret ref exists in
            # the repo today -- the last was cert-manager-openbao-approle
            # supplying ${cert_manager_approle_id}, dropped when cert-manager
            # switched to a projected ServiceAccount token -- so this branch
            # is unreachable until someone adds one. It stays because standing
            # down without a word is how the previous one went unnoticed: the
            # run prints the Kustomization and the Secret rather than naming
            # either here, since a hard-coded name is what went stale.
            secrets = [r["name"] for r in refs if r.get("kind") == "Secret"]
            unattributable.append(
                f"  Kustomization/{k['name']} ({k['path']}): "
                f"{', '.join('${' + v + '}' for v in missing_unattributable)} "
                f"not in any ConfigMap; may come from Secret {', '.join(secrets)}"
            )
            continue

        if missing_failing:
            names = ", ".join(
                r["name"] for r in refs if r.get("kind") == "ConfigMap"
            ) or "<no ConfigMap>"
            sources = ", ".join(
                sorted({CONFIGMAP_SOURCES[r["name"]] for r in refs if r.get("kind") == "ConfigMap"})
            ) or "the cluster's configure stack"
            failures.append(
                f"  {k['file']}\n"
                f"    Kustomization/{k['name']} path={k['path']}\n"
                f"    applies {len(missing_failing)} variable(s) that {names} "
                f"does not define: {', '.join('${' + v + '}' for v in missing_failing)}\n"
                f"    -> Flux substitutes an EMPTY STRING for these. That is"
                f" schema-valid and silently wrong.\n"
                f"    -> Add them to {sources}, or stop applying them from this path."
            )

    if skipped:
        print(f"note: {len(skipped)} Kustomization(s) not buildable from this repo, not checked:")
        for s in skipped:
            print(f"  - {s}")

    if unattributable:
        print(
            f"note: {len(unattributable)} Kustomization(s) apply variable(s) no ConfigMap "
            f"defines, but also substitute from a Secret this repo cannot read:"
        )
        for u in unattributable:
            print(u)

    if failures:
        print(
            f"\nFAIL: {len(failures)} Flux Kustomization(s) would apply a variable "
            f"Flux cannot substitute:\n",
            file=sys.stderr,
        )
        for f in failures:
            print(f, file=sys.stderr)
            print(file=sys.stderr)
        # Both failure kinds above are invisible to the manifest gate, for the
        # same underlying reason but with different consequences, so say both.
        print(
            "Neither kind is visible to validate-manifests.sh: render-bundle.py "
            "substitutes its fixtures unconditionally. The bundle therefore shows what "
            "Flux WOULD render given a correct ConfigMap and wired postBuild -- never "
            "whether postBuild is wired, nor whether the key exists. With postBuild "
            "missing Flux applies the literal ${var}; with the key missing it applies "
            "an empty string, which is schema-valid and silently wrong.",
            file=sys.stderr,
        )
        return 1

    print(f"==> {checked} Flux Kustomization(s) checked; substitution wiring is consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
