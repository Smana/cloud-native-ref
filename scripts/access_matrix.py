#!/usr/bin/env python3
"""Parse and validate security/base/access-matrix/matrix.yaml.

The matrix is the single source of every team's platform permissions. This
module is the only thing that reads it; the renderer and the drift validator
both import from here so a column can never mean two different things.
"""
import dataclasses

import yaml

MATRIX_PATH = "security/base/access-matrix/matrix.yaml"

# A permission column's allowed values. An unknown value is an error rather
# than a pass-through: a typo in `kubernetes:` would otherwise render a
# ClusterRoleBinding to a ClusterRole that does not exist, which Kubernetes
# accepts and which authorises nobody.
ALLOWED = {
    "kubernetes": {"cluster-admin", "view", "none"},
    "mount_access": {"all", "own", "none"},
    "grafana": {"Admin", "Editor", "Viewer", "none"},
    "flux_ui": {"cluster-admin", "edit", "none"},
}

# `platform` is required: the reconciler's zero-members guard names it, and it
# is the row that carries `mountAccess: all`.
REQUIRED_TEAM = "platform"

COLUMNS = {
    "team": "team",
    "googleGroup": "google_group",
    "kubernetes": "kubernetes",
    "mountAccess": "mount_access",
    "grafana": "grafana",
    "fluxUI": "flux_ui",
}


class MatrixError(Exception):
    """The matrix is malformed. Always fatal -- never fall back to a default."""


@dataclasses.dataclass(frozen=True)
class Team:
    team: str
    google_group: str
    kubernetes: str
    mount_access: str
    grafana: str
    flux_ui: str


def load(path=MATRIX_PATH):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}

    rows = doc.get("teams")
    if not isinstance(rows, list) or not rows:
        raise MatrixError(f"{path}: 'teams' must be a non-empty list")

    teams = []
    seen = set()
    for i, row in enumerate(rows):
        if not isinstance(row, dict):
            raise MatrixError(f"{path}: teams[{i}] is not a mapping")

        missing = [k for k in COLUMNS if k not in row]
        if missing:
            raise MatrixError(
                f"{path}: teams[{i}] is missing {', '.join(sorted(missing))}. "
                "Every column is required -- an absent column would render as a "
                "silent 'none' and remove access nobody asked to remove."
            )

        kwargs = {attr: row[key] for key, attr in COLUMNS.items()}
        for attr, allowed in ALLOWED.items():
            if kwargs[attr] not in allowed:
                raise MatrixError(
                    f"{path}: teams[{i}].{attr} is {kwargs[attr]!r}; "
                    f"allowed: {', '.join(sorted(allowed))}"
                )

        if kwargs["team"] in seen:
            raise MatrixError(f"{path}: duplicate team {kwargs['team']!r}")
        seen.add(kwargs["team"])
        teams.append(Team(**kwargs))

    if REQUIRED_TEAM not in seen:
        raise MatrixError(
            f"{path}: no team named {REQUIRED_TEAM!r}. The reconciler's "
            "zero-members guard and the mountAccess: all row both key off it."
        )
    return teams
