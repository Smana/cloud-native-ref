# Access Matrix and Reconciler Implementation Plan (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `security/base/access-matrix/matrix.yaml` the single source of every team's platform permissions, and reconcile ZITADEL role grants from Google Workspace group membership so that adding or removing someone in Workspace is the only action needed.

**Architecture:** One YAML matrix, one row per team, one column per consumer. A Python renderer turns it into the ZITADEL role list and three RBAC manifests, with a `--check` mode CI runs so a hand-edit of a rendered file fails the build. A Bash CronJob reads Workspace group membership over the Admin SDK Directory API and reconciles ZITADEL project-role grants to match, behind four safety guards. Everything downstream keeps consuming the existing `groups` claim unchanged.

**Tech Stack:** Python 3 (stdlib + PyYAML, matching `scripts/flux-schema/*.py`); Bash + `jq` + `curl` (matching `scripts/zitadel-oidc-clients.sh`); Kubernetes `CronJob`; Google Admin SDK Directory API; ZITADEL management API; Flux; VictoriaMetrics for alerting.

**Spec:** [`docs/superpowers/specs/2026-09-11-workspace-access-matrix-design.md`](../specs/2026-09-11-workspace-access-matrix-design.md). Read its "Target" and "Failure modes" sections before starting.

## Status

| Phase | Tasks | Needs a cluster? |
|---|---|---|
| 1 — The matrix and its renderers | 1-5 | No |
| 2 — The reconciler | 6-9 | No (all tests use fixtures) |
| 3 — Rollout, three gates | 10-12 | **Yes — deferred** |

**The platform is torn down.** Phases 1 and 2 are complete work that merges on
its own: a matrix, rendered manifests Flux will apply on the next deploy, and a
CronJob that ships **suspended**. Every `[LIVE]` step is in Phase 3 and waits for
the next rebuild. Do not claim a Phase 3 step is done from a dry run.

## Global Constraints

- **Worktree.** Work in `.claude/worktrees/workspace-access-matrix`, branch
  `worktree-workspace-access-matrix`. Never commit on `main`.
- **Never add a `Co-Authored-By` trailer, and never add "Generated with Claude
  Code" to a PR** (user rule).
- **Commit with an explicit pathspec** — `git commit -F <msgfile> -- <paths>`. A
  bare `git commit` commits the whole index. Write the message to a **file**: a
  backtick in a `-m "..."` string is command substitution.
- **A NEW file must be staged before a pathspec commit.** `git commit -- <path>`
  only considers *tracked* paths, so a newly created file is silently skipped and
  the commit succeeds without it.
- **The team set is exactly** `platform`, `backend`, `data`, `frontend`. `admin`
  is renamed to `platform` — there is no team called `admin` after Task 5.
- **`kubernetes: view`, not `edit`,** for `backend` and `data`. Namespace-scoped
  `edit` waits on per-team namespaces and is out of scope.
- **The reconciler never writes to OpenBao.** Secrets are Plan B.
- **No service-account key on disk.** Task 8 proves the keyless path or stops and
  reports; it does not fall back silently.
- **Validators** (from the repo root, exit 0 expected):
  - `python3 scripts/render_access_matrix.py --check` — after any matrix or
    rendered-file change.
  - `python3 scripts/validate_access_matrix.py` — the Grafana drift check.
  - `bash scripts/test-access-matrix-sync.sh` — the reconciler's fixture tests.
  - `./scripts/validate-manifests.sh` — after any change under `security/`,
    `flux/`, `clusters/`. Report must end `Invalid: 0, Skipped: 0`.
  - `python3 scripts/flux-schema/check-substitution.py` — after any `${var}`
    change in a manifest.
  - `shellcheck -x -S warning scripts/<script>.sh` — CI's exact flags.
  - `./scripts/validate-links.sh`, `./scripts/validate-doc-claims.sh`,
    `./scripts/verify-doc-paths.sh` — after any doc change.
- **Live values** (do not invent alternatives):

  | Thing | Value |
  |---|---|
  | ZITADEL PAT | secret-store key `zitadel/iam-admin-pat` |
  | ZITADEL project name | `ZITADEL_PROJECT_NAME` in `scripts/zitadel-oidc-clients.sh` |
  | Directory API scope | `https://www.googleapis.com/auth/admin.directory.group.readonly` |
  | Namespace for the CronJob | `security` |
  | Existing role list to replace | `ZITADEL_PROJECT_ROLES=(admin backend frontend data)`, `scripts/zitadel-oidc-clients.sh:90` |

## File Structure

| File | Responsibility |
|---|---|
| `security/base/access-matrix/matrix.yaml` | **The source of truth.** Teams × consumers. |
| `security/base/access-matrix/kustomization.yaml` | Makes the rendered RBAC and the CronJob part of `security`. |
| `scripts/access_matrix.py` | Parse + validate the matrix. Imported by the renderer and the validator; no I/O beyond reading the file. |
| `scripts/render_access_matrix.py` | Renders the three RBAC manifests. `--check` diffs instead of writing. |
| `scripts/validate_access_matrix.py` | Asserts Grafana's `role_attribute_path` matches the matrix. |
| `scripts/test-access-matrix.py` | Tests for the three above. |
| `scripts/access-matrix-sync.sh` | The reconciler. Directory API → ZITADEL grants, with the guards. |
| `scripts/test-access-matrix-sync.sh` | Fixture tests for the reconciler, no network. |
| `security/base/access-matrix/cronjob.yaml` | Runs the reconciler. Ships **suspended**. |
| `security/base/access-matrix/vmrule.yaml` | Alerts when the reconciler stops succeeding. |

**Generated, never hand-edited** (each carries a header saying so):
`security/base/rbac/teams.yaml`, `security/gcp-0/rbac/teams.yaml`,
`flux/operator/rbac.yaml`.

---

## Phase 1 — The matrix and its renderers

### Task 1: The matrix file and its parser

**Files:**
- Create: `security/base/access-matrix/matrix.yaml`
- Create: `scripts/access_matrix.py`
- Create: `scripts/test-access-matrix.py`

**Interfaces:**
- Produces: `access_matrix.load(path) -> list[Team]`, where `Team` is a
  `dataclass` with fields `team: str`, `google_group: str`, `kubernetes: str`,
  `secrets: str`, `grafana: str`, `flux_ui: str`. Raises `MatrixError` on any
  invalid input. Tasks 2, 3 and 4 import this and nothing else.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-access-matrix.py`:

```python
#!/usr/bin/env python3
"""Tests for the access matrix parser, renderer and drift validator.

Run: python3 scripts/test-access-matrix.py
Style matches scripts/flux-schema/test-check-substitution.py -- stdlib
unittest, no pytest, so a bare runner needs nothing installed but PyYAML.
"""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import access_matrix  # noqa: E402

VALID = """
teams:
  - team: platform
    googleGroup: platform@ogenki.io
    kubernetes: cluster-admin
    secrets: all
    grafana: Admin
    fluxUI: cluster-admin
  - team: data
    googleGroup: data-eng@ogenki.io
    kubernetes: view
    secrets: own
    grafana: Editor
    fluxUI: edit
"""


def write(text):
    fh = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
    fh.write(text)
    fh.close()
    return fh.name


class TestLoad(unittest.TestCase):
    def test_parses_every_column(self):
        teams = access_matrix.load(write(VALID))
        self.assertEqual([t.team for t in teams], ["platform", "data"])
        self.assertEqual(teams[0].kubernetes, "cluster-admin")
        self.assertEqual(teams[1].google_group, "data-eng@ogenki.io")
        self.assertEqual(teams[1].flux_ui, "edit")

    def test_rejects_duplicate_team(self):
        doc = VALID + """
  - team: platform
    googleGroup: other@ogenki.io
    kubernetes: none
    secrets: none
    grafana: Viewer
    fluxUI: none
"""
        with self.assertRaises(access_matrix.MatrixError):
            access_matrix.load(write(doc))

    def test_rejects_unknown_permission_value(self):
        doc = VALID.replace("kubernetes: view", "kubernetes: superuser")
        with self.assertRaises(access_matrix.MatrixError):
            access_matrix.load(write(doc))

    def test_rejects_missing_column(self):
        doc = VALID.replace("    grafana: Editor\n", "")
        with self.assertRaises(access_matrix.MatrixError):
            access_matrix.load(write(doc))

    def test_requires_a_team_named_platform(self):
        # The zero-admins guard and the secrets: all row both key off it.
        doc = VALID.replace("team: platform", "team: infra")
        with self.assertRaises(access_matrix.MatrixError):
            access_matrix.load(write(doc))


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 scripts/test-access-matrix.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'access_matrix'`

- [ ] **Step 3: Write the parser**

Create `scripts/access_matrix.py`:

```python
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
    "secrets": {"all", "own", "none"},
    "grafana": {"Admin", "Editor", "Viewer", "none"},
    "flux_ui": {"cluster-admin", "edit", "none"},
}

# `platform` is required: the reconciler's zero-members guard names it, and it
# is the row that carries `secrets: all`.
REQUIRED_TEAM = "platform"

# The secrets entry below carries an allowlist pragma: detect-secrets' keyword
# heuristic fires on a quoted key/value pair whose name looks credential-ish,
# and this is a column-name mapping. Keep the pragma -- the pre-commit hook
# rejects the file without it. (Do not restate the flagged pair in a comment
# either; the heuristic reads comments too.)
COLUMNS = {
    "team": "team",
    "googleGroup": "google_group",
    "kubernetes": "kubernetes",
    "secrets": "secrets",  # pragma: allowlist secret
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
    secrets: str
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
            "zero-members guard and the secrets: all row both key off it."
        )
    return teams
```

- [ ] **Step 4: Run the tests**

Run: `python3 scripts/test-access-matrix.py`
Expected: PASS, 5 tests

- [ ] **Step 5: Write the matrix**

Create `security/base/access-matrix/matrix.yaml`:

```yaml
# The single source of every team's permissions on this platform.
#
# Rows are teams, columns are consumers. scripts/render_access_matrix.py turns
# this into the ZITADEL project role list and three RBAC manifests; CI fails if
# a rendered file was edited by hand. scripts/access-matrix-sync.sh reconciles
# ZITADEL role grants from each team's Google Workspace group.
#
# To change what a team may do, change it HERE and re-render. Editing a
# generated file is the one thing this design exists to stop.
#
# See docs/superpowers/specs/2026-09-11-workspace-access-matrix-design.md.
teams:
  # Runs the platform. `secrets: all` is what used to be the hand-written
  # openbao-admin identity group.
  - team: platform
    googleGroup: platform@ogenki.io
    kubernetes: cluster-admin
    secrets: all
    grafana: Admin
    fluxUI: cluster-admin

  # Service teams. `kubernetes: view` rather than `edit` on purpose: `edit` is
  # only meaningful scoped to a namespace and every app shares `apps` today.
  # Namespace-scoped edit waits on per-team namespaces.
  - team: backend
    googleGroup: backend@ogenki.io
    kubernetes: view
    secrets: own
    grafana: Editor
    fluxUI: edit

  - team: data
    googleGroup: data-eng@ogenki.io
    kubernetes: view
    secrets: own
    grafana: Editor
    fluxUI: edit

  # Dashboards only -- no Kubernetes, no secrets.
  - team: frontend
    googleGroup: frontend@ogenki.io
    kubernetes: none
    secrets: none
    grafana: Editor
    fluxUI: none
```

- [ ] **Step 6: Verify the real matrix parses**

Run: `python3 -c "import sys; sys.path.insert(0,'scripts'); import access_matrix; print([t.team for t in access_matrix.load()])"`
Expected: `['platform', 'backend', 'data', 'frontend']`

- [ ] **Step 7: Commit**

```bash
git add scripts/access_matrix.py scripts/test-access-matrix.py \
        security/base/access-matrix/matrix.yaml
git commit -F /tmp/msg1.txt -- scripts/access_matrix.py \
  scripts/test-access-matrix.py security/base/access-matrix/matrix.yaml
```

Message: `feat(access): the matrix, and the one module that reads it`

---

### Task 2: Render the Kubernetes RBAC

**Files:**
- Create: `scripts/render_access_matrix.py`
- Modify: `scripts/test-access-matrix.py` (add `TestRender`)
- Create: `security/base/rbac/teams.yaml` (generated)
- Create: `security/gcp-0/rbac/teams.yaml` (generated)

**Interfaces:**
- Consumes: `access_matrix.load()` from Task 1.
- Produces: `render_rbac(teams, cloud) -> str` where `cloud` is `"aws"` or
  `"gcp"`; and a CLI `--check` that exits 1 on any difference. Task 3 and Task 5
  both call the CLI, not the function.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-access-matrix.py`, above the `__main__` block:

```python
import render_access_matrix  # noqa: E402


class TestRender(unittest.TestCase):
    def setUp(self):
        self.teams = access_matrix.load(write(VALID))

    def test_aws_uses_the_bare_group_name(self):
        out = render_access_matrix.render_rbac(self.teams, "aws")
        self.assertIn("name: platform\n", out)
        self.assertNotIn("principalSet", out)

    def test_gcp_uses_the_principalset_path(self):
        out = render_access_matrix.render_rbac(self.teams, "gcp")
        self.assertIn(
            "principalSet://iam.googleapis.com/locations/global/"
            "workforcePools/${workforce_pool_id}/group/platform",
            out,
        )

    def test_none_renders_no_binding(self):
        doc = VALID.replace("kubernetes: view", "kubernetes: none")
        teams = access_matrix.load(write(doc))
        out = render_access_matrix.render_rbac(teams, "aws")
        self.assertIn("ogenki-platform", out)
        self.assertNotIn("ogenki-data", out)

    def test_carries_a_do_not_edit_header(self):
        out = render_access_matrix.render_rbac(self.teams, "aws")
        self.assertIn("GENERATED FILE", out.split("\n")[0])
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 scripts/test-access-matrix.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'render_access_matrix'`

- [ ] **Step 3: Write the renderer**

Create `scripts/render_access_matrix.py`. Underscores, not dashes: the test
imports it as a module, and `import render-access-matrix` is a syntax error.

```python
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
```

- [ ] **Step 4: Run the tests**

Run: `python3 scripts/test-access-matrix.py`
Expected: PASS, 9 tests

- [ ] **Step 5: Render for real**

Run: `python3 scripts/render_access_matrix.py`
Expected: `rendered security/base/rbac/teams.yaml` and
`rendered security/gcp-0/rbac/teams.yaml`

- [ ] **Step 6: Verify `--check` is clean immediately after**

Run: `python3 scripts/render_access_matrix.py --check`
Expected: `==> 2 rendered file(s) match the matrix`, exit 0

- [ ] **Step 7: Prove `--check` actually fails on a hand-edit**

```bash
sed -i 's/name: ogenki-platform/name: ogenki-tampered/' security/base/rbac/teams.yaml
python3 scripts/render_access_matrix.py --check; echo "exit=$?"
git checkout security/base/rbac/teams.yaml
```

Expected: a unified diff, `exit=1`. A `--check` that cannot fail is worse than
no check, so this step is not optional.

- [ ] **Step 8: Commit**

```bash
git add scripts/render_access_matrix.py scripts/test-access-matrix.py \
        security/base/rbac/teams.yaml security/gcp-0/rbac/teams.yaml
git commit -F /tmp/msg2.txt -- scripts/render_access_matrix.py \
  scripts/test-access-matrix.py security/base/rbac/teams.yaml \
  security/gcp-0/rbac/teams.yaml
```

Message: `feat(access): render the cluster RBAC from the matrix`

---

### Task 3: Render the Flux UI RBAC

**Files:**
- Modify: `scripts/render_access_matrix.py`
- Modify: `scripts/test-access-matrix.py`
- Modify: `flux/operator/rbac.yaml` (becomes generated)

**Interfaces:**
- Produces: `render_flux_rbac(teams) -> str`, and `flux/operator/rbac.yaml`
  added to `TARGETS` so `--check` covers it.

**Found during planning:** `flux/operator/rbac.yaml` already contains **four**
`ClusterRoleBinding`s (`flux-ui-admins`, `-backend`, `-frontend`, `-data`)
naming all four teams. The design called the Flux UI a validator target; it is a
*render* target. Its CEL is `groups: "claims.groups"` and names no team, so
there is nothing there to validate.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-access-matrix.py`:

```python
class TestRenderFluxUI(unittest.TestCase):
    def setUp(self):
        self.teams = access_matrix.load(write(VALID))

    def test_binding_per_team_with_flux_access(self):
        out = render_access_matrix.render_flux_rbac(self.teams)
        self.assertIn("name: flux-ui-platform", out)
        self.assertIn("name: cluster-admin", out)
        self.assertIn("name: flux-ui-data", out)
        self.assertIn("name: edit", out)

    def test_none_renders_no_binding(self):
        doc = VALID.replace("fluxUI: edit", "fluxUI: none")
        teams = access_matrix.load(write(doc))
        out = render_access_matrix.render_flux_rbac(teams)
        self.assertNotIn("flux-ui-data", out)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 scripts/test-access-matrix.py`
Expected: FAIL — `AttributeError: module 'render_access_matrix' has no attribute 'render_flux_rbac'`

- [ ] **Step 3: Implement**

Add to `scripts/render_access_matrix.py`, after `render_rbac`:

```python
def render_flux_rbac(teams):
    """Flux UI bindings. Same shape as the cluster RBAC, different name prefix.

    The Flux UI impersonates the user with `groups: "claims.groups"`, so these
    are ordinary Kubernetes bindings against the same group names -- which is
    why they are rendered from the same matrix rather than maintained beside it.
    """
    out = [HEADER]
    for t in teams:
        if t.flux_ui == "none":
            continue
        out.append(_binding(f"flux-ui-{t.team}", t.team, t.flux_ui))
    return "".join(out)
```

And extend `main()` — replace the `for cloud, path in TARGETS.items():` loop
body's `want = render_rbac(teams, cloud)` by building the work list first:

```python
    work = [(path, render_rbac(teams, cloud)) for cloud, path in TARGETS.items()]
    work.append(("flux/operator/rbac.yaml", render_flux_rbac(teams)))

    stale = []
    for path, want in work:
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
```

Update the success line to `print(f"==> {len(work)} rendered file(s) match the matrix")`.

- [ ] **Step 4: Run the tests**

Run: `python3 scripts/test-access-matrix.py`
Expected: PASS, 11 tests

- [ ] **Step 5: Render and inspect the Flux diff before accepting it**

```bash
python3 scripts/render_access_matrix.py
git diff flux/operator/rbac.yaml
```

Expected: `admin` → `platform` on the binding name and group; `frontend`'s
binding **removed** (matrix says `fluxUI: none`); `backend` and `data`
unchanged but for the header. Read it — this is the first generated file that
replaces hand-written content, and a surprise here means the matrix is wrong.

- [ ] **Step 6: Commit**

```bash
git add scripts/render_access_matrix.py scripts/test-access-matrix.py \
        flux/operator/rbac.yaml
git commit -F /tmp/msg3.txt -- scripts/render_access_matrix.py \
  scripts/test-access-matrix.py flux/operator/rbac.yaml
```

Message: `feat(access): render the Flux UI RBAC from the matrix too`

---

### Task 4: The Grafana drift validator

**Files:**
- Create: `scripts/validate_access_matrix.py`
- Modify: `scripts/test-access-matrix.py`

**Interfaces:**
- Consumes: `access_matrix.load()`.
- Produces: a CLI exiting 1 when Grafana's `role_attribute_path` and the matrix
  disagree. Task 11 in CI runs it.

Grafana's mapping is a JMESPath expression that changes rarely; generating it
would put a generator bug in the login-authorisation path. A validator catches
drift without owning the file.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-access-matrix.py`:

```python
import validate_access_matrix  # noqa: E402


class TestGrafanaDrift(unittest.TestCase):
    def setUp(self):
        self.teams = access_matrix.load(write(VALID))

    def test_agreement_is_clean(self):
        expr = ("contains(roles[*], 'platform') && 'Admin' || "
                "contains(roles[*], 'data') && 'Editor' || 'Viewer'")
        self.assertEqual(validate_access_matrix.check(self.teams, expr), [])

    def test_missing_team_is_reported(self):
        expr = "contains(roles[*], 'platform') && 'Admin' || 'Viewer'"
        problems = validate_access_matrix.check(self.teams, expr)
        self.assertTrue(any("data" in p for p in problems))

    def test_unknown_team_is_reported(self):
        expr = ("contains(roles[*], 'platform') && 'Admin' || "
                "contains(roles[*], 'data') && 'Editor' || "
                "contains(roles[*], 'ghost') && 'Editor' || 'Viewer'")
        problems = validate_access_matrix.check(self.teams, expr)
        self.assertTrue(any("ghost" in p for p in problems))

    def test_wrong_grafana_role_is_reported(self):
        expr = ("contains(roles[*], 'platform') && 'Editor' || "
                "contains(roles[*], 'data') && 'Editor' || 'Viewer'")
        problems = validate_access_matrix.check(self.teams, expr)
        self.assertTrue(any("platform" in p and "Admin" in p for p in problems))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 scripts/test-access-matrix.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'validate_access_matrix'`

- [ ] **Step 3: Implement**

Create `scripts/validate_access_matrix.py` (underscores, for the same import reason):

```python
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
```

- [ ] **Step 4: Run the tests**

Run: `python3 scripts/test-access-matrix.py`
Expected: PASS, 15 tests

- [ ] **Step 5: Run against the real file — expect it to FAIL**

Run: `python3 scripts/validate_access_matrix.py`
Expected: exit 1, reporting `platform` absent and `admin` unknown. **This is
correct** — Grafana still says `admin`, and Task 5 is what fixes it. Do not
"fix" it here; the validator having caught the real drift is the evidence that
it works.

- [ ] **Step 6: Commit**

```bash
git add scripts/validate_access_matrix.py scripts/test-access-matrix.py
git commit -F /tmp/msg4.txt -- scripts/validate_access_matrix.py \
  scripts/test-access-matrix.py
```

Message: `feat(access): catch Grafana drifting from the matrix`

---

### Task 5: The rename, in one commit

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`
- Modify: `scripts/zitadel-oidc-clients.sh:90`
- Delete: `security/base/rbac/admin.yaml`, `security/gcp-0/rbac/admin.yaml`
- Modify: `security/base/rbac/kustomization.yaml`, `security/gcp-0/rbac/kustomization.yaml`

A rename split across commits leaves half the repo on each name. This is one
commit.

- [ ] **Step 1: Fix Grafana's expression**

In the values ConfigMap, replace the `role_attribute_path` block with:

```yaml
          role_attribute_path: >
            contains(roles[*], 'platform') && 'Admin' ||
            contains(roles[*], 'backend') && 'Editor' ||
            contains(roles[*], 'frontend') && 'Editor' ||
            contains(roles[*], 'data') && 'Editor' ||
            'Viewer'
```

- [ ] **Step 2: Make the ZITADEL role list read the matrix**

In `scripts/zitadel-oidc-clients.sh`, replace line 90
(`ZITADEL_PROJECT_ROLES=(admin backend frontend data)`) with:

```bash
# The project roles come from the access matrix, not from a list maintained
# here. They diverged once already: ADR-0036 shipped OpenBao groups aliased to
# `app-<name>` roles while this list stayed at four entries, so those groups
# could never match a token.
_matrix="$(cd "$(dirname "$0")/.." && pwd)/security/base/access-matrix/matrix.yaml"
if [ ! -r "$_matrix" ]; then
    echo "[FAILED ] cannot read the access matrix at ${_matrix}" >&2
    exit 1
fi
mapfile -t ZITADEL_PROJECT_ROLES < <(
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as fh:
    for t in (yaml.safe_load(fh) or {}).get("teams", []):
        print(t["team"])
' "$_matrix"
)
[ "${#ZITADEL_PROJECT_ROLES[@]}" -gt 0 ] || {
    echo "[FAILED ] the access matrix yielded no roles" >&2; exit 1; }
```

- [ ] **Step 3: Delete the superseded RBAC files and update the kustomizations**

```bash
git rm security/base/rbac/admin.yaml security/gcp-0/rbac/admin.yaml
```

In both `kustomization.yaml` files, replace the `admin.yaml` entry with
`teams.yaml`.

- [ ] **Step 4: Re-render and confirm nothing is stale**

Run: `python3 scripts/render_access_matrix.py --check`
Expected: `==> 3 rendered file(s) match the matrix`, exit 0

- [ ] **Step 5: The Grafana validator now passes**

Run: `python3 scripts/validate_access_matrix.py`
Expected: `==> Grafana's role_attribute_path matches the access matrix`, exit 0

- [ ] **Step 6: No `admin` remains as a role or group name**

```bash
grep -rnE "name: admin$|group/admin|'admin'|\(admin " \
  --include='*.yaml' --include='*.sh' \
  security/ flux/ observability/ scripts/ | grep -viE 'admin-password|iam-admin|pki-admin|secrets-admin|cluster-admin|proxyclass-admin'
```

Expected: no output. Any hit is a half-finished rename.

- [ ] **Step 7: Full validation**

Run: `shellcheck -x -S warning scripts/zitadel-oidc-clients.sh`
Run: `python3 scripts/flux-schema/check-substitution.py`
Run: `./scripts/validate-manifests.sh`
Expected: exit 0; the report ends `Invalid: 0, Skipped: 0`

- [ ] **Step 8: Commit**

```bash
git add -A security/ flux/ observability/ scripts/
git commit -F /tmp/msg5.txt
```

Message: `refactor(access): admin becomes the platform team, everywhere at once`

---

## Phase 2 — The reconciler

### Task 6: Credentials — prove the keyless path first

**Files:**
- Create: `docs/superpowers/specs/2026-09-11-workspace-access-matrix-credentials.md`

**This task produces a finding, not code.** The spec flags keyless
domain-wide delegation as the one part of the credential path not already in use
in this repo, and requires it be proven rather than assumed. Doing this first
means a negative result costs one task instead of invalidating three.

- [ ] **Step 1: Confirm the Google-side prerequisites exist**

```bash
gcloud services list --enabled --project <project> | grep -E 'admin|cloudidentity'
gcloud iam service-accounts list --project <project> | grep -i access-matrix
```

Expected: the Admin SDK (or Cloud Identity) API enabled, and a service account.
If absent, stop — these are the manual prerequisites in the spec and are the
owner's to create.

- [ ] **Step 2: Mint a delegated token with no key on disk**

```bash
SA=access-matrix-sync@<project>.iam.gserviceaccount.com
SUBJECT=<a-workspace-admin@ogenki.io>
SCOPE=https://www.googleapis.com/auth/admin.directory.group.readonly

now=$(date +%s)
claim=$(jq -nc --arg iss "$SA" --arg sub "$SUBJECT" --arg scope "$SCOPE" \
  --argjson iat "$now" --argjson exp "$((now+3600))" \
  '{iss:$iss, sub:$sub, scope:$scope, aud:"https://oauth2.googleapis.com/token",
    iat:$iat, exp:$exp}')

assertion=$(gcloud iam service-accounts sign-jwt --iam-account="$SA" \
  <(printf '%s' "$claim") /dev/stdout)

curl -s -X POST https://oauth2.googleapis.com/token \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  -d "assertion=${assertion}" | jq -r '.access_token // .'
```

Expected: an access token. `sign-jwt` uses the IAM Credentials API, so no key
material touches disk.

- [ ] **Step 3: Prove the token can actually list a group**

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" \
  'https://admin.googleapis.com/admin/directory/v1/groups/platform@ogenki.io/members' \
  | jq '{count: (.members // [] | length)}'
```

Expected: a member count. A 403 here means domain-wide delegation was not
authorised for that scope in the admin console — that is the prerequisite, not a
code bug.

- [ ] **Step 4: Record the outcome**

Write the design note with: the exact commands that worked, the IAM roles the
calling identity needed (`roles/iam.serviceAccountTokenCreator` on the SA), and
the Workspace-side client-ID/scope pair that was authorised.

**If Steps 2-3 could not be made to work, STOP and report.** The fallback is a
service-account key in the secret store, and the spec requires that to be a
decision rather than a discovery. Do not proceed to Task 7 having quietly
adopted it.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-09-11-workspace-access-matrix-credentials.md
git commit -F /tmp/msg6.txt -- docs/superpowers/specs/2026-09-11-workspace-access-matrix-credentials.md
```

Message: `docs(access): prove the keyless delegation path before building on it`

---

### Task 7: The reconciler's guards, tested offline

**Files:**
- Create: `scripts/access-matrix-sync.sh`
- Create: `scripts/test-access-matrix-sync.sh`

**Interfaces:**
- Consumes: the matrix (via `python3`, as in Task 5).
- Produces: `reconcile_team <team> <members_json> <grants_json>` printing one
  line per action — `grant <email>` / `revoke <email>` / `skip-no-user <email>`
  — or `GUARD <reason>` on stdout and returning non-zero. Task 8 wraps it; the
  tests drive it directly.

The guards are the whole point, so they are written before any network code.
`reconcile_team` is pure: two JSON inputs, a list of actions out, no I/O.

- [ ] **Step 1: Write the failing tests**

Create `scripts/test-access-matrix-sync.sh`:

```bash
#!/usr/bin/env bash
# Fixture tests for access-matrix-sync.sh's reconcile_team -- the four safety
# guards, with no network. These are the behaviours that decide whether a Google
# outage is a non-event or a platform-wide lockout, so they are tested first and
# directly.
#
# access-matrix-sync.sh is sourceable: it guards its CLI behind
# `[ "${BASH_SOURCE[0]}" = "$0" ]` precisely so this file can call one function.
set -uo pipefail
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# shellcheck source=/dev/null
source "$(dirname "$0")/access-matrix-sync.sh"

MEMBERS='["a@ogenki.io","b@ogenki.io"]'
GRANTS='[{"email":"a@ogenki.io","userId":"1"},{"email":"c@ogenki.io","userId":"3"}]'

echo "== grants what is missing, revokes what left =="
out="$(reconcile_team data "$MEMBERS" "$GRANTS" 2>&1)"; rc=$?
check "exit 0"            0 "$rc"
check "grants b"          1 "$(grep -c '^grant b@ogenki.io$'  <<<"$out")"
check "revokes c"         1 "$(grep -c '^revoke c@ogenki.io$' <<<"$out")"
check "leaves a alone"    0 "$(grep -c 'a@ogenki.io' <<<"$out")"

echo "== a member with no ZITADEL user is skipped, not fatal =="
out="$(reconcile_team data '["a@ogenki.io","ghost@ogenki.io"]' \
        '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"; rc=$?
check "exit 0"            0 "$rc"
check "skip-no-user"      1 "$(grep -c '^skip-no-user ghost@ogenki.io$' <<<"$out")"

echo "== an UNREADABLE group never revokes =="
out="$(reconcile_team data "__UNREADABLE__" "$GRANTS" 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD unreadable' <<<"$out")"

echo "== blast radius: >half or >2 stops =="
out="$(reconcile_team data '[]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
    {"email":"c@ogenki.io","userId":"3"},{"email":"d@ogenki.io","userId":"4"}]' 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD blast-radius' <<<"$out")"

echo "== two members, both leaving, still trips (the >2 half) =="
out="$(reconcile_team data '[]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"}]' 2>&1)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"

echo "== platform is never left empty =="
out="$(reconcile_team platform '[]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD zero-members' <<<"$out")"

echo "== idempotent: nothing to do =="
out="$(reconcile_team data '["a@ogenki.io"]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"
check "no actions"        0 "$(grep -cE '^(grant|revoke)' <<<"$out")"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/test-access-matrix-sync.sh`
Expected: FAIL — cannot source `access-matrix-sync.sh`

- [ ] **Step 3: Implement the guards**

Create `scripts/access-matrix-sync.sh`:

```bash
#!/usr/bin/env bash
# Reconcile ZITADEL project-role grants from Google Workspace group membership.
#
# The matrix (security/base/access-matrix/matrix.yaml) says which Workspace
# group backs which team; this makes ZITADEL agree. Adding or removing someone
# in Workspace becomes the only action needed.
#
# DRY RUN BY DEFAULT. --apply writes.
#
# Sourceable: the CLI is guarded at the bottom so scripts/test-access-matrix-
# sync.sh can call reconcile_team directly with fixtures and no network.
set -uo pipefail

# A run may revoke at most half a team's grants, and never more than two, unless
# --max-revocations raises it. The "never more than two" half is not redundant:
# on a two-member team a pure fraction lets both go one at a time without ever
# tripping.
MAX_REVOKE_FRACTION=2      # denominator: 1/2
MIN_REVOKE_FLOOR=2

# Teams that must never be left with zero members. The platform team is the
# break-glass path for Kubernetes, which has no equivalent of OpenBao's
# userpass login.
PROTECTED_TEAMS="platform"

# reconcile_team <team> <members-json|__UNREADABLE__> <grants-json>
#
# Pure: no network, no writes. Prints one action per line and returns non-zero
# when a guard stops the run. Every caller must treat a non-zero return as "do
# nothing for this team", never as "continue with what was printed".
reconcile_team() {
    local team="$1" members="$2" grants="$3"

    # GUARD 1 -- an unreadable group is not an empty group.
    #
    # This is the guard that stops a Google outage becoming a lockout. Treating
    # a failed list as "nobody is in this group" would revoke every grant on the
    # platform, and every downstream consumer would start denying at once.
    if [ "$members" = "__UNREADABLE__" ]; then
        echo "GUARD unreadable: could not list the Workspace group for ${team}; making no change"
        return 1
    fi

    local current want to_grant to_revoke n_revoke n_current
    want="$(jq -r '.[]' <<<"$members" | sort -u)"
    current="$(jq -r '.[].email' <<<"$grants" | sort -u)"

    to_grant="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$current"))"
    to_revoke="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$current"))"

    n_current="$(grep -c . <<<"$current")"
    n_revoke="$(grep -c . <<<"$to_revoke")"

    # GUARD 2 -- never empty a protected team.
    if [[ " $PROTECTED_TEAMS " == *" $team "* ]] \
       && [ "$n_revoke" -ge "$n_current" ] && [ "$n_current" -gt 0 ]; then
        echo "GUARD zero-members: refusing to leave ${team} with no members"
        return 1
    fi

    # GUARD 3 -- blast radius.
    if [ "$n_revoke" -gt 0 ]; then
        local allowed=$(( n_current / MAX_REVOKE_FRACTION ))
        [ "$allowed" -lt "$MIN_REVOKE_FLOOR" ] && allowed="$MIN_REVOKE_FLOOR"
        if [ "$n_revoke" -gt "$allowed" ] || [ "$n_revoke" -ge "$n_current" ]; then
            echo "GUARD blast-radius: ${n_revoke} of ${n_current} grants for ${team} would be revoked (max ${allowed}); making no change"
            return 1
        fi
    fi

    # GUARD 4 -- a member with no ZITADEL user is normal, not an error. A user
    # exists only after their first login, so the grant simply lands on a later
    # run.
    local email
    while read -r email; do
        [ -z "$email" ] && continue
        if zitadel_user_id "$email" >/dev/null 2>&1; then
            echo "grant ${email}"
        else
            echo "skip-no-user ${email}"
        fi
    done <<<"$to_grant"

    while read -r email; do
        [ -z "$email" ] && continue
        echo "revoke ${email}"
    done <<<"$to_revoke"

    return 0
}

# Overridden by the tests. The real implementation lands in Task 8.
if ! declare -F zitadel_user_id >/dev/null; then
    zitadel_user_id() { case "$1" in ghost@*) return 1 ;; *) echo "stub" ;; esac; }
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "CLI lands in Task 8; this file is currently sourceable only." >&2
    exit 64
fi
```

- [ ] **Step 4: Run the tests**

Run: `bash scripts/test-access-matrix-sync.sh`
Expected: `PASS`, every check `ok`

- [ ] **Step 5: Lint**

Run: `shellcheck -x -S warning scripts/access-matrix-sync.sh scripts/test-access-matrix-sync.sh`
Expected: clean

- [ ] **Step 6: Commit**

```bash
git add scripts/access-matrix-sync.sh scripts/test-access-matrix-sync.sh
git commit -F /tmp/msg7.txt -- scripts/access-matrix-sync.sh \
  scripts/test-access-matrix-sync.sh
```

Message: `feat(access): the reconciler's four guards, tested before any network code`

---

### Task 8: The reconciler's network halves and CLI

**Files:**
- Modify: `scripts/access-matrix-sync.sh`
- Modify: `scripts/test-access-matrix-sync.sh`

**Interfaces:**
- Produces: `google_token`, `list_group_members <group>`,
  `zitadel_user_id <email>`, `zitadel_grants <role>`, `zitadel_grant`,
  `zitadel_revoke`, and `main` with `--apply`, `--team <name>`,
  `--max-revocations <n>`. Task 9 invokes `main`.

- [ ] **Step 1: Write the failing test for dry-run**

Append to `scripts/test-access-matrix-sync.sh`, before the final summary:

```bash
echo "== dry run performs no writes =="
WROTE=0
zitadel_grant()  { WROTE=$((WROTE+1)); }
zitadel_revoke() { WROTE=$((WROTE+1)); }
APPLY=false
apply_actions data <<'ACTIONS'
grant b@ogenki.io
revoke c@ogenki.io
ACTIONS
check "no writes in dry run" 0 "$WROTE"

echo "== --apply performs them =="
WROTE=0; APPLY=true
apply_actions data <<'ACTIONS'
grant b@ogenki.io
revoke c@ogenki.io
ACTIONS
check "two writes with --apply" 2 "$WROTE"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/test-access-matrix-sync.sh`
Expected: FAIL — `apply_actions: command not found`

- [ ] **Step 3: Implement**

Add to `scripts/access-matrix-sync.sh`, above the `BASH_SOURCE` guard.

`zitadel_api` is defined here rather than reused: `api()` lives inside
`scripts/zitadel-oidc-clients.sh`, which parses `--cluster`/`--cloud` at the top
of the file and so cannot be sourced — the same constraint
`scripts/test-zitadel-idp-convergence.sh` documents for its own restatement. The
*authentication* half is reused via `scripts/lib/zitadel-pat.sh`, which is
already a library, so only a six-line curl wrapper is duplicated. Extracting a
shared `scripts/lib/zitadel-api.sh` would be better and is deliberately not done
here: it would rewrite the API plumbing of a heavily-tested script for a
different plan's benefit.

```bash
APPLY="${APPLY:-false}"

# shellcheck source=lib/zitadel-pat.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/zitadel-pat.sh"

# Resolved once per run, not per call.
ZITADEL_PAT="${ZITADEL_PAT:-$(resolve_zitadel_pat)}"

# curl -K reads the credential from a file descriptor rather than argv, so the
# PAT never appears in the process table. scripts/test-no-secret-argv.sh gates
# this class of mistake repo-wide.
zitadel_api() {
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" "${IDP_URL}${path}" \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$ZITADEL_PAT") \
        -H "Content-Type: application/json" \
        "$@"
}

# Keyless delegated token -- see the Task 6 note for why there is no key file.
google_token() {
    local now claim assertion
    now="$(date +%s)"
    claim="$(jq -nc --arg iss "$GOOGLE_SA" --arg sub "$GOOGLE_SUBJECT" \
        --arg scope "https://www.googleapis.com/auth/admin.directory.group.readonly" \
        --argjson iat "$now" --argjson exp "$((now + 3600))" \
        '{iss:$iss, sub:$sub, scope:$scope,
          aud:"https://oauth2.googleapis.com/token", iat:$iat, exp:$exp}')"
    assertion="$(gcloud iam service-accounts sign-jwt --quiet \
        --iam-account="$GOOGLE_SA" <(printf '%s' "$claim") /dev/stdout)" || return 1
    curl -sf -X POST https://oauth2.googleapis.com/token \
        -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
        -d "assertion=${assertion}" | jq -r '.access_token'
}

# Prints a JSON array of member emails, or the literal __UNREADABLE__ on any
# failure. The sentinel is load-bearing: reconcile_team's first guard turns it
# into "change nothing", and returning an empty array here instead would revoke
# the whole team.
list_group_members() {
    local group="$1" body
    body="$(curl -sf -H "Authorization: Bearer ${GOOGLE_TOKEN}" \
        "https://admin.googleapis.com/admin/directory/v1/groups/${group}/members")" \
        || { printf '__UNREADABLE__'; return 0; }
    jq -c '[.members // [] | .[] | select(.status == "ACTIVE") | .email]' <<<"$body" \
        || printf '__UNREADABLE__'
}

zitadel_user_id() {
    local email="$1"
    zitadel_api POST /management/v1/users/_search \
        -d "$(jq -nc --arg e "$email" \
              '{queries:[{emailQuery:{emailAddress:$e}}]}')" \
        | jq -er '.result[0].id // empty'
}

zitadel_grants() {
    local role="$1"
    zitadel_api POST "/management/v1/users/grants/_search" \
        -d "$(jq -nc --arg p "$ZITADEL_PROJECT_ID" --arg r "$role" \
              '{queries:[{projectIdQuery:{projectId:$p}},{roleKeyQuery:{roleKey:$r}}]}')" \
        | jq -c '[.result // [] | .[] | {email: .email, userId: .userId, grantId: .id}]'
}

zitadel_grant() {
    local user_id="$1" role="$2"
    zitadel_api POST "/management/v1/users/${user_id}/grants" \
        -d "$(jq -nc --arg p "$ZITADEL_PROJECT_ID" --arg r "$role" \
              '{projectId:$p, roleKeys:[$r]}')" >/dev/null
}

zitadel_revoke() {
    local user_id="$1" grant_id="$2"
    zitadel_api DELETE "/management/v1/users/${user_id}/grants/${grant_id}" >/dev/null
}

# apply_actions <team>, reading action lines on stdin.
apply_actions() {
    local team="$1" verb email
    while read -r verb email; do
        case "$verb" in
            grant)
                if [ "$APPLY" = true ]; then
                    zitadel_grant "$(zitadel_user_id "$email")" "$team"
                    echo "[granted] ${email} -> ${team}"
                else
                    echo "[dry-run] would grant ${email} -> ${team}"
                fi ;;
            revoke)
                if [ "$APPLY" = true ]; then
                    zitadel_revoke "$(zitadel_user_id "$email")" \
                        "$(jq -r --arg e "$email" '.[]|select(.email==$e)|.grantId' \
                           <<<"${GRANTS_JSON:-[]}")"
                    echo "[revoked] ${email} -> ${team}"
                else
                    echo "[dry-run] would revoke ${email} -> ${team}"
                fi ;;
            skip-no-user)
                echo "[skip   ] ${email} has no ZITADEL user yet (first login pending)" ;;
        esac
    done
}
```

Replace the `BASH_SOURCE` guard with a `main` that, for each team in the matrix:

1. sets `GRANTS_JSON="$(zitadel_grants "$team")"` — `apply_actions` reads it to
   map an email back to its `grantId` for revocation, so it must be in scope
   before `apply_actions` is called and re-read per team;
2. sets `members="$(list_group_members "$googleGroup")"`;
3. runs `reconcile_team "$team" "$members" "$GRANTS_JSON" | apply_actions "$team"`;
4. records whether the team's `reconcile_team` returned non-zero.

`main` exits non-zero if **any** team tripped a guard, so a partial failure is
visible to the CronJob rather than averaged away — and because `reconcile_team`
prints no `grant`/`revoke` lines when it trips, a tripped team writes nothing
even though the run continues to the others.

Note the pipeline in (3) puts `apply_actions` in a subshell, so `WROTE`-style
counters set inside it do not propagate — which is why the Step 1 tests call
`apply_actions` directly with a heredoc rather than through a pipe.

- [ ] **Step 4: Run the tests**

Run: `bash scripts/test-access-matrix-sync.sh`
Expected: `PASS`

- [ ] **Step 5: Lint**

Run: `shellcheck -x -S warning scripts/access-matrix-sync.sh`
Expected: clean

- [ ] **Step 6: Add both suites to CI**

In `.github/workflows/`, extend the existing loop (the one listing
`scripts/test-zitadel-*.sh`) with `scripts/test-access-matrix-sync.sh`, and add
a step running `python3 scripts/test-access-matrix.py`,
`python3 scripts/render_access_matrix.py --check` and
`python3 scripts/validate_access_matrix.py`.

- [ ] **Step 7: Commit**

```bash
git add scripts/access-matrix-sync.sh scripts/test-access-matrix-sync.sh .github/
git commit -F /tmp/msg8.txt -- scripts/access-matrix-sync.sh \
  scripts/test-access-matrix-sync.sh .github/
```

Message: `feat(access): the reconciler's API halves, dry-run by default`

---

### Task 9: The CronJob and its alert

**Files:**
- Create: `security/base/access-matrix/cronjob.yaml`
- Create: `security/base/access-matrix/vmrule.yaml`
- Create: `security/base/access-matrix/kustomization.yaml`
- Modify: `security/aws-0/kustomization.yaml` (or the primary cloud's overlay)

- [ ] **Step 1: Write the CronJob**

Model it on `security/base/openbao-snapshot/snapshot-cronjob.yaml`:
`concurrencyPolicy: Forbid`, `startingDeadlineSeconds: 3600`,
`activeDeadlineSeconds: 600`, `ttlSecondsAfterFinished: 86400`,
`schedule: "*/15 * * * *"`, restricted `securityContext`
(`runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`,
`capabilities: {drop: [ALL]}`, `seccompProfile: {type: RuntimeDefault}`), an
`emptyDir` for `/tmp`, and resource requests **and** limits — all constitution
mandates.

**It ships `suspend: true`.** Gate 1 is a manual run; the schedule is enabled in
Task 11.

- [ ] **Step 2: Write the alert**

`VMRule` firing when the CronJob has not completed successfully in 1 hour
(four missed runs), `severity: warning`. A sync with nothing to do and a sync
that is broken look identical from outside, which is the reason this exists.

- [ ] **Step 3: Wire it into the primary cloud's overlay only**

The reconciler is a primary-cloud singleton (ADR-0027). Add the directory to the
primary cluster's `security` kustomization and **not** the other's.

- [ ] **Step 4: Validate**

Run: `./scripts/validate-manifests.sh`
Expected: exit 0, `Invalid: 0, Skipped: 0`
Run: `python3 scripts/flux-schema/check-substitution.py`
Expected: consistent

- [ ] **Step 5: Commit**

```bash
git add security/base/access-matrix/ security/aws-0/kustomization.yaml
git commit -F /tmp/msg9.txt -- security/base/access-matrix/ security/aws-0/kustomization.yaml
```

Message: `feat(access): run the reconciler on a schedule, suspended until proven`

---

## Phase 3 — Rollout [LIVE, deferred to the next rebuild]

**None of these can be done now.** Do not tick them from a dry run against
fixtures.

### Task 10: Gate 1 — dry run

- [ ] **Step 1 [LIVE]: Run by hand and read every line**

```bash
kubectl create job -n security --from=cronjob/access-matrix-sync matrix-dryrun
kubectl logs -n security job/matrix-dryrun
```

- [ ] **Step 2 [LIVE]: Every line must be explainable**

Expected: `[dry-run] would grant …` for real Workspace members, `[skip   ]` for
those who have never logged in, and **no `GUARD` lines**. A `GUARD` line at this
stage means the matrix disagrees with Workspace — fix the matrix, not the guard.

- [ ] **Step 3 [LIVE]: Confirm nothing was written**

```bash
./scripts/zitadel-oidc-clients.sh --list-grants   # or the ZITADEL console
```

Expected: grants unchanged from before the run.

### Task 11: Gate 2 — grants only

- [ ] **Step 1 [LIVE]: Enable with revocation disabled**

Set `--apply` and `--max-revocations 0` in the CronJob args, and
`suspend: false`. With the cap at zero every revocation trips the blast-radius
guard, so the run can only ever widen access.

- [ ] **Step 2 [LIVE]: Verify a real grant lands**

Add yourself to a Workspace team group, wait one interval, confirm the ZITADEL
grant appears and the corresponding consumer authorises you.

### Task 12: Gate 3 — revocation on

- [ ] **Step 1 [LIVE]: Remove the cap**

Drop `--max-revocations 0` so the default guard applies.

- [ ] **Step 2 [LIVE]: Verify a real revocation**

Remove a test account from a Workspace group, wait one interval, confirm the
grant disappears and access is denied.

- [ ] **Step 3 [LIVE]: Verify the guards on live data**

Temporarily point one team at a non-existent Workspace group. Expected: a
`GUARD unreadable` line, a non-zero exit, and **zero revocations**. Revert.

- [ ] **Step 4: Records**

Write the ADR superseding ADR-0036, amend ADR-0034, update
`secrets.md` / `authentication.md` / `per-user-rbac.md`, and add the doc claim
binding the "who gets what" table to the matrix.

Run: `./scripts/validate-links.sh`, `./scripts/validate-doc-claims.sh`,
`./scripts/verify-doc-paths.sh`
Expected: all exit 0

---

## Appendix: what this plan does NOT do

- **Team-scoped secrets** — Plan B. No OpenBao resource is touched here; the
  matrix's `secrets:` column is parsed and validated but not yet rendered.
- **Actions V1 → V2.** `groupsFromRoles` stays a v1 Action. It is a ZITADEL V6
  blocker and takes every consumer with it when it breaks, but it is not made
  better or worse by this plan.
- **GKE `authenticator_groups_config`.** Would let GKE resolve Workspace groups
  natively and could retire the ADR-0032 token-exchange shim. Separate design.
- **Harbor.** Its OIDC group wiring was never located; it is not treated as a
  consumer, and if it turns out to read `groups` it becomes a fifth render
  target.
