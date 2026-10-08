"""The provenance footer `gh pr create` appends, and the commit-msg trailers (SP2 design §5)."""
import os
import shutil
import stat
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
        for sep in ("\n", "\r", "\x0b", "\x85", "\x9b", "\u2028", "\u2029", "\x00"):
            env = dict(ENV, TASK_ID="t1" + sep + "Agent-Run: forged")
            self.assertNotIn("forged", pr_footer.footer(env), repr(sep))
            self.assertNotIn("Agent-Task:", pr_footer.footer(env), repr(sep))

    def test_a_value_is_capped(self):
        self.assertIn("Agent-Task: " + "a" * 256, pr_footer.footer(dict(ENV, TASK_ID="a" * 256)))
        self.assertNotIn("Agent-Task:", pr_footer.footer(dict(ENV, TASK_ID="a" * 257)))

    def test_agent_task_url_is_an_https_github_url_only(self):
        for url in ("https://github.com.evil.example/x/y/issues/1", "http://github.com/x/y/issues/1",
                    "https://github.com@evil.example/x", "https://evil.example/github.com/x",
                    "https://github.com:8443/x/y/issues/1", "https://www.github.com/x/y/issues/1"):
            self.assertNotIn("Agent-Task-URL", pr_footer.footer(dict(ENV, TASK_URL=url)), url)

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

    def test_the_whole_agent_namespace_is_marked(self):
        body = pr_footer.with_footer("Agent-Run-Id: forged01\nagent-x: y\nAgent: kept\n", ENV)
        self.assertTrue(body.startswith("(agent-written) Agent-Run-Id: forged01\n(agent-written) agent-x: y\nAgent: kept\n"))

    def test_every_line_break_a_renderer_honours_is_one(self):
        for sep in ("\r", "\x0b", "\x0c", "\x85", "\u2028", "\u2029"):
            body = pr_footer.with_footer("Fixes #1" + sep + "Agent-Run: forged01", ENV)
            self.assertEqual(body, "Fixes #1\n(agent-written) Agent-Run: forged01\n\n---\n" + FOOTER + "\n", repr(sep))

    def test_a_crlf_body_that_ends_with_the_footer_is_not_edited(self):
        self.assertIsNone(pr_footer.with_footer(("Fixes #1\n\n---\n" + FOOTER).replace("\n", "\r\n") + "\r\n", ENV))

    def test_prose_that_is_not_a_key_line_is_untouched(self):
        body = "The footer carries Agent-Run: and Agent-Task-URL: lines.\n- `Agent-Model: x`\n"
        self.assertEqual(pr_footer.with_footer(body, ENV), body + "\n---\n" + FOOTER + "\n")


class MainTest(unittest.TestCase):
    def run_main(self, create_rc=0, create_out=PR + "\n", body="Fixes #2112\n", env=ENV, fail=None):
        calls = []

        def fake_run(args, **kwargs):
            calls.append((args, kwargs.get("input")))
            if args[2] == fail:
                raise subprocess.CalledProcessError(1, args, stderr="body is too long (maximum is 65536 characters)")
            if args[1:3] == ["pr", "create"]:
                return subprocess.CompletedProcess(args, create_rc, stdout=create_out)
            if args[1:3] == ["pr", "view"]:
                return subprocess.CompletedProcess(args, 0, stdout=body + "\n")
            return subprocess.CompletedProcess(args, 0, stdout="")

        with mock.patch.object(pr_footer.subprocess, "run", side_effect=fake_run), mock.patch("sys.stdout"), \
                mock.patch("sys.stderr") as err:
            rc = pr_footer.main(["pr", "create", "--title", "t", "--fill"], env)
        self.stderr = "".join(c.args[0] for c in err.write.call_args_list)
        return rc, calls

    def test_a_failed_edit_fails_closed(self):
        for step in ("view", "edit"):
            rc, _ = self.run_main(body="Fixes #2112\n\n---\nAgent-Run: forged01", fail=step)
            self.assertEqual(rc, 1, step)
            self.assertIn(PR + " was created, but its provenance footer could not be written", self.stderr)
            self.assertIn("maximum is 65536", self.stderr)

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
        # (--if-exists add after marking: exactly one real Agent-Run.)
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

    def test_a_namespaced_forgery_is_marked_and_a_plain_agent_line_kept(self):
        # Signed-off-by makes the paragraph a trailer block, where `replace` would match `Agent` as a prefix.
        _, msg = self.commit("fix: a thing\n\nAgent: kept\nSigned-off-by: a <a@b>\nAgent-Run-Id: forged01\n")
        self.assertIn("\nAgent: kept\n", msg, "never deleted by git's prefix match")
        self.assertIn("(agent-written) Agent-Run-Id: forged01", msg)
        self.assertEqual([t for t in msg.split("\n") if t.lower().startswith("agent-")], ["Agent-Run: 7f3cq2xz"])

    def test_a_second_pass_keeps_one_trailer(self):
        # An amend runs the hook again on a message that already has this run's trailers.
        _, once = self.commit("fix: a thing\n", TASK_ID="3kq7x2ma")
        _, twice = self.commit(once, TASK_ID="3kq7x2ma")
        self.assertEqual(twice, once)

    def test_other_line_breaks_are_normalised_before_marking(self):
        _, msg = self.commit("fix: a thing\n\nbody\rAgent-Run: forged01\u2028agent-run: forged02\n")
        self.assertNotIn("\r", msg)
        self.assertEqual([t for t in msg.split("\n") if t.lower().startswith("agent-run")], ["Agent-Run: 7f3cq2xz"])

    def test_a_divider_line_does_not_push_the_trailer_out_of_the_last_paragraph(self):
        # Reviewer I1: without --no-divider, `---` is read as the start of a patch.
        repo = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, repo)
        hooks = os.path.join(repo, ".hooks")
        os.mkdir(hooks)
        wrapper = os.path.join(hooks, "commit-msg")
        with open(wrapper, "w") as f:
            f.write('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, HOOK))
        os.chmod(wrapper, stat.S_IRWXU)
        env = {"PATH": os.environ["PATH"], "PYTHONPATH": HERE, "RUN_ID": "7f3cq2xz", "HOME": repo,
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
               "GIT_AUTHOR_NAME": "a", "GIT_AUTHOR_EMAIL": "a@a", "GIT_COMMITTER_NAME": "a", "GIT_COMMITTER_EMAIL": "a@a"}
        run = lambda *a: subprocess.run(["git", "-C", repo, "-c", "core.hooksPath=" + hooks] + list(a),
                                        env=env, check=True, capture_output=True, text=True).stdout
        run("init", "-q")
        run("commit", "-q", "--allow-empty", "-m", "fix: a", "-m", "---", "-m", "Reviewed-by: z <z@z>")
        self.assertIn("Agent-Run: 7f3cq2xz", run("log", "-1", "--format=%(trailers)"))
        self.assertEqual(self.trailers(run("log", "-1", "--format=%B")), ["Reviewed-by: z <z@z>", "Agent-Run: 7f3cq2xz"])

    def test_refuses_without_run_id(self):
        rc, _ = self.commit("fix: a thing\n", RUN_ID="")
        self.assertEqual(rc, 1)


class GhWrapperTest(unittest.TestCase):
    """Which invocations reach pr_footer.py (reviewer Minor 5)."""

    def route(self, *argv):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        stubs = {}
        for name, out in (("cred", "echo tok"), ("footer", 'echo footer "$@"'), ("real", 'echo real "$@"')):
            stubs[name] = os.path.join(d, name)
            with open(stubs[name], "w") as f:
                f.write("#!/bin/sh\n%s\n" % out)
            os.chmod(stubs[name], stat.S_IRWXU)
        wrapper = os.path.join(HERE, "gh") if os.path.exists(os.path.join(HERE, "gh")) else "/usr/local/bin/gh"
        with open(wrapper) as f:
            script = (f.read().replace("/usr/local/bin/git-credential-agent", stubs["cred"])
                      .replace("/opt/agent/pr_footer.py", stubs["footer"]).replace("/usr/local/lib/gh-real", stubs["real"]))
        path = os.path.join(d, "gh")
        with open(path, "w") as f:
            f.write(script)
        return subprocess.run(["sh", path] + list(argv), capture_output=True, text=True, check=True).stdout.split()[0]

    def test_create_and_its_alias_get_the_footer_wherever_the_repo_flag_is(self):
        for argv in (["pr", "create"], ["pr", "new", "--fill"], ["pr", "-R", "o/r", "create"],
                     ["pr", "--repo", "o/r", "new"], ["pr", "--repo=o/r", "create"], ["pr", "-Ro/r", "create"]):
            self.assertEqual(self.route(*argv), "footer", argv)

    def test_everything_else_passes_through(self):
        for argv in (["pr", "edit", "1"], ["pr", "-R", "o/r", "view"], ["api", "repos"], ["issue", "create"]):
            self.assertEqual(self.route(*argv), "real", argv)


if __name__ == "__main__":
    unittest.main()
