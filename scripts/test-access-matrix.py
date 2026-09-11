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
    mountAccess: all
    grafana: Admin
    fluxUI: cluster-admin
  - team: data
    googleGroup: data-eng@ogenki.io
    kubernetes: view
    mountAccess: own
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
        doc = VALID.replace("kubernetes: view", "kubernetes: none")
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
        self.assertIn("name: edit", out)

    def test_none_renders_no_binding(self):
        doc = VALID.replace("fluxUI: edit", "fluxUI: none")
        teams = access_matrix.load(write(doc))
        out = render_access_matrix.render_flux_rbac(teams)
        self.assertNotIn("flux-ui-data", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
