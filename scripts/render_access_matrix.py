#!/usr/bin/env python3
"""Render the access matrix into the manifests that enforce it.

Generated files are never hand-edited; `--check` is what makes that true, and
CI runs it. The alternative -- a matrix that describes permissions while the
real ones live in five other files -- is the problem this replaces.
"""
import argparse
import difflib
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import access_matrix

HEADER = """# GENERATED FILE -- DO NOT EDIT.
#
# Rendered from security/base/access-matrix/matrix.yaml by
# scripts/render_access_matrix.py. Change the matrix and re-render:
#
#     python3 scripts/render_access_matrix.py
#
# CI runs `--check` and fails if this file and the matrix disagree.
"""

# gcp-0's API server sees a Workforce Identity Federation principal, so the
# group carries the pool's full resource path. Same role, same ClusterRole,
# different spelling -- see security/gcp-0/rbac/ for the longer note.
GCP_GROUP = (
    "principalSet://iam.googleapis.com/locations/global/"
    "workforcePools/${workforce_pool_id}/group/%s"
)

TARGETS = {
    "aws": "security/base/rbac/teams.yaml",
    "gcp": "security/gcp-0/rbac/teams.yaml",
}


def _binding(name, group, cluster_role):
    return f"""---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {name}
subjects:
  - kind: Group
    name: {group}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: {cluster_role}
  apiGroup: rbac.authorization.k8s.io
"""


def render_rbac(teams, cloud):
    out = [HEADER]
    for t in teams:
        if t.kubernetes == "none":
            continue
        group = t.team if cloud == "aws" else GCP_GROUP % t.team
        out.append(_binding(f"ogenki-{t.team}", group, t.kubernetes))
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if any rendered file differs; write nothing")
    args = ap.parse_args()

    teams = access_matrix.load()
    stale = []
    for cloud, path in TARGETS.items():
        want = render_rbac(teams, cloud)
        p = pathlib.Path(path)
        have = p.read_text(encoding="utf-8") if p.exists() else ""
        if want == have:
            continue
        if args.check:
            stale.append((path, have, want))
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(want, encoding="utf-8")
            print(f"rendered {path}")

    if stale:
        for path, have, want in stale:
            print(f"==> STALE: {path}", file=sys.stderr)
            sys.stderr.writelines(
                difflib.unified_diff(
                    have.splitlines(True), want.splitlines(True),
                    fromfile=f"{path} (on disk)", tofile=f"{path} (from matrix)",
                )
            )
        print("\nRun: python3 scripts/render_access_matrix.py", file=sys.stderr)
        return 1
    if args.check:
        print(f"==> {len(TARGETS)} rendered file(s) match the matrix")
    return 0


if __name__ == "__main__":
    sys.exit(main())
