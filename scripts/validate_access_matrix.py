#!/usr/bin/env python3
"""Assert Grafana's role_attribute_path agrees with the access matrix.

Grafana is the one consumer whose mapping is not rendered: role_attribute_path
is a JMESPath expression, it changes rarely, and a generator bug in it becomes a
login-authorisation bug. So it stays hand-written and this proves it has not
drifted from the matrix.
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import access_matrix
import yaml

GRAFANA_VALUES = (
    "observability/base/victoria-metrics-k8s-stack/"
    "vm-common-helm-values-configmap.yaml"
)

# contains(roles[*], 'team') && 'Role'
PAIR = re.compile(r"contains\(roles\[\*\],\s*'([^']+)'\)\s*&&\s*'([^']+)'")


def check(teams, expr):
    """Return a list of human-readable problems; empty means agreement."""
    found = dict(PAIR.findall(expr))
    expected = {t.team: t.grafana for t in teams if t.grafana != "none"}

    problems = []
    for team, role in sorted(expected.items()):
        if team not in found:
            problems.append(
                f"team {team!r} has grafana: {role} in the matrix but is absent "
                "from role_attribute_path"
            )
        elif found[team] != role:
            problems.append(
                f"team {team!r} is {found[team]!r} in role_attribute_path but "
                f"{role!r} in the matrix"
            )
    for team in sorted(set(found) - set(expected)):
        problems.append(
            f"role_attribute_path names {team!r}, which is not a team in the "
            "matrix (or has grafana: none)"
        )
    return problems


def extract_expr(path=GRAFANA_VALUES):
    """Pull role_attribute_path out of the Helm values ConfigMap.

    The values are a YAML string INSIDE a ConfigMap, so this parses twice. A
    grep would be shorter and would also match the same key in a comment.
    """
    with open(path, encoding="utf-8") as fh:
        cm = yaml.safe_load(fh)
    for value in (cm.get("data") or {}).values():
        doc = yaml.safe_load(value)
        if not isinstance(doc, dict):
            continue
        auth = (((doc.get("grafana") or {}).get("grafana.ini") or {})
                .get("auth.generic_oauth") or {})
        if "role_attribute_path" in auth:
            return auth["role_attribute_path"]
    raise SystemExit(f"{path}: no role_attribute_path found")


def main():
    problems = check(access_matrix.load(), extract_expr())
    if problems:
        print("==> Grafana's role_attribute_path disagrees with the matrix:",
              file=sys.stderr)
        for p in problems:
            print(f"    {p}", file=sys.stderr)
        print(f"\nFix {GRAFANA_VALUES} or the matrix, whichever is wrong.",
              file=sys.stderr)
        return 1
    print("==> Grafana's role_attribute_path matches the access matrix")
    return 0


if __name__ == "__main__":
    sys.exit(main())
