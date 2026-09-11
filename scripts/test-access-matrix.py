#!/usr/bin/env python3
"""Tests for the access matrix parser, renderer and drift validator.

Run: python3 scripts/test-access-matrix.py
Style matches scripts/flux-schema/test-check-substitution.py -- stdlib
unittest, no pytest, so a bare runner needs nothing installed but PyYAML.
"""
import json
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
    mountAccess: all
    grafana: Admin
    fluxUI: cluster-admin
  - team: data
    googleGroup: data-eng@ogenki.io
    kubernetes: view
    mountAccess: own
    grafana: Editor
    fluxUI: view
"""

ROOT = pathlib.Path(__file__).resolve().parent.parent


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
        self.assertEqual(teams[1].flux_ui, "view")

    def test_the_real_matrix_loads(self):
        teams = {t.team: t for t in access_matrix.load(ROOT / access_matrix.MATRIX_PATH)}
        # The owner's decision, 2026-09-11: service teams are read-only on the
        # cluster and change it through GitOps only.
        for name in ("backend", "data"):
            self.assertEqual(teams[name].kubernetes, "view", name)
            self.assertEqual(teams[name].flux_ui, "view", name)

    def _row(self, kubernetes, flux_ui):
        return VALID.replace(
            "    kubernetes: view\n    mountAccess: own\n    grafana: Editor\n    fluxUI: view\n",
            f"    kubernetes: {kubernetes}\n    mountAccess: own\n"
            f"    grafana: Editor\n    fluxUI: {flux_ui}\n",
        )

    def test_rejects_flux_ui_above_kubernetes(self):
        # Both columns bind the SAME group and RBAC is a union: a Flux UI grant
        # above the Kubernetes one silently raises the Kubernetes one.
        for kubernetes, flux_ui in [("view", "edit"), ("none", "view"),
                                    ("view", "cluster-admin")]:
            with self.subTest(kubernetes=kubernetes, flux_ui=flux_ui):
                with self.assertRaises(access_matrix.MatrixError) as cm:
                    access_matrix.load(write(self._row(kubernetes, flux_ui)))
                msg = str(cm.exception)
                self.assertIn("'data'", msg)
                self.assertIn(repr(kubernetes), msg)
                self.assertIn(repr(flux_ui), msg)

    def test_equal_levels_pass(self):
        for level in ("none", "view"):
            with self.subTest(level=level):
                teams = access_matrix.load(write(self._row(level, level)))
                self.assertEqual((teams[1].kubernetes, teams[1].flux_ui), (level, level))

    def test_rejects_malformed_team_name(self):
        # A space breaks the reconciler's "<team> <group>" line parsing.
        for bad in ("Data", "back end", "back/end", "1data", "data\n", "-data", ""):
            with self.subTest(team=bad):
                with self.assertRaises(access_matrix.MatrixError):
                    access_matrix.load(write(VALID.replace("team: data", f"team: {json.dumps(bad)}")))

    def test_rejects_malformed_google_group(self):
        # The group is interpolated into the Directory API URL path.
        for bad in ("data-eng", "data-eng@ogenki.io/x", "data-eng@ogenki.io?x=1",
                    "data#eng@ogenki.io", "data%2Feng@ogenki.io", "data eng@ogenki.io",
                    "data-eng@ogenki.io\t", "a@b@ogenki.io", "@ogenki.io"):
            with self.subTest(group=bad):
                doc = VALID.replace("googleGroup: data-eng@ogenki.io",
                                    f"googleGroup: {json.dumps(bad)}")
                with self.assertRaises(access_matrix.MatrixError):
                    access_matrix.load(write(doc))

    def test_rejects_duplicate_team(self):
        doc = VALID + """
  - team: platform
    googleGroup: other@ogenki.io
    kubernetes: none
    mountAccess: none
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
        # The zero-admins guard and the mountAccess: all row both key off it.
        doc = VALID.replace("team: platform", "team: infra")
        with self.assertRaises(access_matrix.MatrixError):
            access_matrix.load(write(doc))


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
        doc = (VALID.replace("kubernetes: view", "kubernetes: none")
               .replace("fluxUI: view", "fluxUI: none"))
        teams = access_matrix.load(write(doc))
        out = render_access_matrix.render_rbac(teams, "aws")
        self.assertIn("ogenki-platform", out)
        self.assertNotIn("ogenki-data", out)

    def test_carries_a_do_not_edit_header(self):
        out = render_access_matrix.render_rbac(self.teams, "aws")
        self.assertIn("GENERATED FILE", out.split("\n")[0])


class TestRenderFluxUI(unittest.TestCase):
    def setUp(self):
        self.teams = access_matrix.load(write(VALID))

    def test_binding_per_team_with_flux_access(self):
        out = render_access_matrix.render_flux_rbac(self.teams)
        self.assertIn("name: flux-ui-platform", out)
        self.assertIn("name: cluster-admin", out)
        self.assertIn("name: flux-ui-data", out)
        self.assertIn("  name: view\n", out)
        self.assertNotIn("  name: edit\n", out)
        # The SUBJECT, not just metadata/roleRef: the Flux UI impersonates the
        # bare `groups` claim on both clouds, so a principalSet:// subject here
        # would be a cluster-admin binding that silently matches nobody.
        self.assertIn("  - kind: Group\n    name: platform\n", out)
        self.assertIn("  - kind: Group\n    name: data\n", out)
        self.assertNotIn("principalSet", out)

    def test_none_renders_no_binding(self):
        doc = VALID.replace("fluxUI: view", "fluxUI: none")
        teams = access_matrix.load(write(doc))
        out = render_access_matrix.render_flux_rbac(teams)
        self.assertNotIn("flux-ui-data", out)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
