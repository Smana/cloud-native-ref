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


if __name__ == "__main__":
    unittest.main(verbosity=2)
