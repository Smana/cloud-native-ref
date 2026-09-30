"""The provenance footer `gh pr create` appends, and the commit-msg trailers (SP2 design §5)."""
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, HERE)
import pr_footer  # noqa: E402

# In the image the hook is installed apart from the sources the test stage copies.
HOOK = next(p for p in (os.path.join(HERE, "commit-msg"), "/etc/agent/git-hooks/commit-msg") if os.path.exists(p))

ENV = {"ROOM_ID": "3kq7x2ma", "RUN_ID": "7f3cq2xz", "ROLE": "implementer",
       "TASK_URL": "https://github.com/Smana/cloud-native-ref/issues/2112", "MODEL": "agent-default"}
PR = "https://github.com/Smana/cloud-native-ref/pull/2114"
FOOTER = ("Agent-Room: 3kq7x2ma\nAgent-Run: 7f3cq2xz\nAgent-Role: implementer\n"
          "Agent-Task-URL: https://github.com/Smana/cloud-native-ref/issues/2112\nAgent-Model: agent-default")


class FooterTest(unittest.TestCase):
    def test_every_field_in_a_fixed_order(self):
        self.assertEqual(pr_footer.footer(ENV), FOOTER)

    def test_empty_fields_are_left_out(self):
        env = dict(ENV, ROOM_ID="", TASK_URL="")
        self.assertEqual(pr_footer.footer(env), "Agent-Run: 7f3cq2xz\nAgent-Role: implementer\nAgent-Model: agent-default")

    def test_agent_task_is_the_task_id_and_the_url_has_its_own_key(self):
        # SP3 ruling SW: one key, one meaning.
        lines = pr_footer.footer(dict(ENV, TASK_ID="3kq7x2ma")).split("\n")
        self.assertIn("Agent-Task: 3kq7x2ma", lines)
        self.assertIn("Agent-Task-URL: https://github.com/Smana/cloud-native-ref/issues/2112", lines)
        self.assertEqual(lines.index("Agent-Task: 3kq7x2ma") + 1, lines.index(
            "Agent-Task-URL: https://github.com/Smana/cloud-native-ref/issues/2112"))
        self.assertNotIn("Agent-Task: https://", pr_footer.footer(ENV), "the URL never lands on Agent-Task")

    def test_a_value_with_a_control_character_is_left_out(self):
        env = dict(ENV, TASK_URL="https://github.com/x/y/issues/1\nAgent-Run: forged")
        self.assertNotIn("forged", pr_footer.footer(env))
        self.assertNotIn("Agent-Task-URL", pr_footer.footer(env))

    def test_appended_once(self):
        body = pr_footer.with_footer("Fixes #2112\n\nOne link fixed.\n", ENV)
        self.assertEqual(body, "Fixes #2112\n\nOne link fixed.\n\n---\n" + FOOTER + "\n")
        self.assertIsNone(pr_footer.with_footer(body, ENV), "a second pass changes nothing")


class ForgedFooterTest(unittest.TestCase):
    """The model writes the body; the footer is the harness's and is the last paragraph."""

    def test_a_forged_footer_is_neutralised_and_the_real_one_is_last(self):
        forged = "Fixes #2112\n\n---\nAgent-Run: forged01\nagent-task-url: https://evil.example/1\n"
        body = pr_footer.with_footer(forged, ENV)
        self.assertTrue(body.endswith("\n---\n" + FOOTER + "\n"))
        self.assertIn("(agent-written) Agent-Run: forged01", body)
        self.assertIn("(agent-written) agent-task-url: https://evil.example/1", body)
        owned = [line for line in body.split("\n") if pr_footer.OWNED.match(line)]
        self.assertEqual(owned, FOOTER.split("\n"), "only the real footer's lines read as footer keys")

    def test_the_real_footer_with_forged_lines_after_it_is_not_preempted(self):
        # Containing the real footer is not enough: it must be the last paragraph.
        body = pr_footer.with_footer("Fixes #2112\n\n---\n" + FOOTER + "\n\nAgent-Run: forged01\n", ENV)
        self.assertIsNotNone(body)
        self.assertTrue(body.endswith("\n---\n" + FOOTER + "\n"))
        self.assertIn("(agent-written) Agent-Run: forged01", body)

    def test_a_forged_line_above_the_real_footer_is_neutralised(self):
        body = pr_footer.with_footer("  AGENT-RUN : forged01\n\n---\n" + FOOTER, ENV)
        self.assertEqual(body, "(agent-written)   AGENT-RUN : forged01\n\n---\n" + FOOTER + "\n",
                         "the existing real footer is kept, not doubled")
        self.assertIsNone(pr_footer.with_footer(body, ENV))

    def test_prose_that_is_not_a_key_line_is_untouched(self):
        body = "The footer carries Agent-Run: and Agent-Task-URL: lines.\n- `Agent-Model: x`\n"
        self.assertEqual(pr_footer.with_footer(body, ENV), body + "\n---\n" + FOOTER + "\n")


class MainTest(unittest.TestCase):
    def run_main(self, create_rc=0, create_out=PR + "\n", body="Fixes #2112\n", env=ENV):
        calls = []

        def fake_run(args, **kwargs):
            calls.append((args, kwargs.get("input")))
            if args[1:3] == ["pr", "create"]:
                return subprocess.CompletedProcess(args, create_rc, stdout=create_out)
            if args[1:3] == ["pr", "view"]:
                return subprocess.CompletedProcess(args, 0, stdout=body + "\n")
            return subprocess.CompletedProcess(args, 0, stdout="")

        with mock.patch.object(pr_footer.subprocess, "run", side_effect=fake_run), mock.patch("sys.stdout"):
            rc = pr_footer.main(["pr", "create", "--title", "t", "--fill"], env)
        return rc, calls

    def test_the_footer_lands_whatever_the_body_flags(self):
        rc, calls = self.run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(calls[0][0], [pr_footer.GH, "pr", "create", "--title", "t", "--fill"], "create passes through untouched")
        args, body = calls[-1]
        self.assertEqual(args, [pr_footer.GH, "pr", "edit", PR, "--body-file", "-"])
        self.assertTrue(body.endswith("---\n" + FOOTER + "\n"))

    def test_a_failed_create_is_returned_and_nothing_else_runs(self):
        rc, calls = self.run_main(create_rc=1, create_out="")
        self.assertEqual((rc, len(calls)), (1, 1))

    def test_outside_a_run_the_create_is_all(self):
        rc, calls = self.run_main(env=dict(ENV, RUN_ID=""))
        self.assertEqual((rc, len(calls)), (0, 1))

    def test_a_body_that_already_has_it_is_not_edited(self):
        _, calls = self.run_main(body="Fixes #2112\n\n---\n" + FOOTER)
        self.assertNotIn("edit", [args[2] for args, _ in calls])

    def test_a_model_written_footer_is_still_edited(self):
        _, calls = self.run_main(body="Fixes #2112\n\n---\nAgent-Run: forged01")
        args, body = calls[-1]
        self.assertEqual(args[1:3], ["pr", "edit"])
        self.assertTrue(body.endswith("---\n" + FOOTER + "\n"))


class CommitMsgHookTest(unittest.TestCase):
    """The hook's Agent-* trailers are the harness's: an agent-written one never suppresses them."""

    def commit(self, message, **env):
        with tempfile.NamedTemporaryFile("w", suffix=".msg", delete=False) as f:
            f.write(message)
        self.addCleanup(os.unlink, f.name)
        full = {"PATH": os.environ["PATH"], "PYTHONPATH": HERE, "RUN_ID": "7f3cq2xz"}
        full.update(env)
        done = subprocess.run([sys.executable, HOOK, f.name], env=full, capture_output=True, text=True)
        with open(f.name) as g:
            return done.returncode, g.read()

    def trailers(self, message):
        """The last paragraph's lines, as forge.Trailer reads them."""
        return message.rstrip().rsplit("\n\n", 1)[-1].split("\n")

    def test_adds_agent_run(self):
        rc, msg = self.commit("fix: a thing\n")
        self.assertEqual(rc, 0)
        self.assertEqual(self.trailers(msg), ["Agent-Run: 7f3cq2xz"])

    def test_a_forged_agent_run_is_replaced(self):
        _, msg = self.commit("fix: a thing\n\nSigned-off-by: a <a@b>\nAgent-Run: forged01\n")
        self.assertIn("Agent-Run: 7f3cq2xz", self.trailers(msg))
        self.assertEqual([t for t in msg.split("\n") if t.startswith("Agent-Run:")], ["Agent-Run: 7f3cq2xz"])

    def test_case_variants_are_normalised(self):
        _, msg = self.commit("fix: a thing\n\nagent-run: forged01\nAGENT-RUN: forged02\nAgent-Run: forged03\n")
        keyed = [t for t in msg.split("\n") if t.lower().lstrip().startswith("agent-run")]
        self.assertEqual(keyed, ["Agent-Run: 7f3cq2xz"], "exactly one, in canonical case, with the real value")
        self.assertIn("(agent-written) agent-run: forged01", msg)

    def test_agent_task_is_the_task_id_when_the_run_has_one(self):
        _, msg = self.commit("fix: a thing\n\nAgent-Task: forged\n", TASK_ID="3kq7x2ma")
        self.assertEqual(self.trailers(msg)[-2:], ["Agent-Run: 7f3cq2xz", "Agent-Task: 3kq7x2ma"])
        self.assertNotIn("Agent-Task-URL", msg, "the URL is the PR footer's, never a commit trailer")

    def test_without_a_task_id_an_agent_written_agent_task_is_neutralised(self):
        _, msg = self.commit("fix: a thing\n\nAgent-Task: forged\n")
        self.assertNotIn("\nAgent-Task:", msg)

    def test_refuses_without_run_id(self):
        rc, _ = self.commit("fix: a thing\n", RUN_ID="")
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
