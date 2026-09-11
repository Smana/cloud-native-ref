#!/usr/bin/env python3
"""Parse and validate security/base/access-matrix/matrix.yaml.

The matrix is the single source of every team's platform permissions. This
module is the only thing that reads it; the renderer and the drift validator
both import from here so a column can never mean two different things.
"""
import dataclasses
import re

import yaml

MATRIX_PATH = "security/base/access-matrix/matrix.yaml"

# A permission column's allowed values. An unknown value is an error rather
# than a pass-through: a typo in `kubernetes:` would otherwise render a
# ClusterRoleBinding to a ClusterRole that does not exist, which Kubernetes
# accepts and which authorises nobody.
#
# `kubernetes` and `flux_ui` take the same values, and not by coincidence: the
# Flux UI impersonates the user's `groups` claim, so both columns render a
# ClusterRoleBinding on the SAME group, reachable with the same token from
# kubectl. Cluster-wide `edit` is allowed in neither -- it reads and writes
# every Secret and runs pods as any ServiceAccount, cluster-admin in all but
# name.
#
# Every value names the BUILT-IN ClusterRole of that name, and this set is what
# keeps it that way. For the Flux UI that means built-in `view` -- never the
# flux-operator chart's `flux-web-user`, which is get/list/watch on */* and so
# reads every Secret.
ALLOWED = {
    "kubernetes": {"cluster-admin", "view", "none"},
    "mount_access": {"all", "own", "none"},
    "grafana": {"Admin", "Editor", "Viewer", "none"},
    "flux_ui": {"cluster-admin", "view", "none"},
}

# The one ranking of Kubernetes ClusterRoles, least to most. RBAC is a union,
# so a `flux_ui` above `kubernetes` would silently raise the Kubernetes column
# to it; load() refuses that row.
#
# `none < view < edit < cluster-admin` means "no broader than" ONLY because
# both columns render to BUILT-IN ClusterRoles, and those nest: each grants
# everything the one before it does. If either column ever maps to a custom
# ClusterRole, the <= comparison no longer proves that, so revisit this guard
# rather than slotting the new role into the ranking.
RBAC_RANK = {level: i for i, level in enumerate(("none", "view", "edit", "cluster-admin"))}

# `team` becomes a group name, a ClusterRoleBinding name and one field of the
# reconciler's space-separated "<team> <group>" lines. `googleGroup` is
# interpolated into the Directory API URL path, so nothing that could end or
# re-shape a path segment is allowed in it.
TEAM_RE = re.compile(r"[a-z][a-z0-9-]*")
GOOGLE_GROUP_RE = re.compile(r"[^@\s/?#%]+@[^@\s/?#%]+\.[^@\s/?#%]+")

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
        team = kwargs["team"]
        if not isinstance(team, str) or not TEAM_RE.fullmatch(team):
            raise MatrixError(
                f"{path}: teams[{i}].team is {team!r}; it must match "
                f"{TEAM_RE.pattern} (it becomes a group and a binding name)"
            )
        group = kwargs["google_group"]
        if not isinstance(group, str) or not GOOGLE_GROUP_RE.fullmatch(group):
            raise MatrixError(
                f"{path}: team {team!r}: googleGroup is {group!r}; it must be a "
                "single email address with no whitespace, '/', '?', '#' or '%'"
            )

        # Before the allowed-values check, so `fluxUI: edit` -- the exact
        # regression this guards -- is refused with the reason, not a bare list.
        kube, flux = kwargs["kubernetes"], kwargs["flux_ui"]
        if kube in RBAC_RANK and flux in RBAC_RANK and RBAC_RANK[flux] > RBAC_RANK[kube]:
            raise MatrixError(
                f"{path}: team {team!r}: fluxUI {flux!r} exceeds kubernetes "
                f"{kube!r}. Both render a ClusterRoleBinding on the same group "
                "and RBAC is a union, so fluxUI would silently raise the "
                "team's Kubernetes access. fluxUI may never exceed kubernetes."
            )

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
