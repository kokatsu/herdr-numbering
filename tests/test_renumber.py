import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parent.parent


class RenumberTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr-numbering-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = {
            "tabs": [
                {"workspace_id": "w1", "tab_id": "t1", "label": "[8] shell"},
                {"workspace_id": "w1", "tab_id": "t2", "label": "9"},
                {"workspace_id": "w2", "tab_id": "t3", "label": r"foo\bar"},
            ],
            "workspaces": [
                {"workspace_id": "w1", "number": 1, "label": "work", "tokens": {}},
                {"workspace_id": "w2", "number": 2, "label": "other", "tokens": {}},
            ],
            "panes": [
                {"pane_id": "p1", "workspace_id": "w1", "tokens": {}},
                {"pane_id": "p2", "workspace_id": "w2", "tokens": {}},
            ],
        }
        self.write_state(self.state)
        config = self.root / "config"
        config.mkdir()
        fake = self.root / "herdr"
        fake.write_text("#!/bin/sh\nexec " + shlex.join([
            sys.executable, str(REPO / "tests" / "fake_herdr.py")
        ]) + ' "$@"\n')
        fake.chmod(0o700)
        self.env = dict(os.environ, HERDR_BIN_PATH=str(fake),
                        HERDR_PLUGIN_STATE_DIR=str(self.root),
                        HERDR_PLUGIN_CONFIG_DIR=str(config),
                        XDG_RUNTIME_DIR=str(self.root),
                        HERDR_SOCKET_PATH="/test/herdr.sock",
                        FAKE_HERDR_DIR=str(self.root))

    def write_state(self, state):
        (self.root / "state.json").write_text(json.dumps(state))

    def read_state(self):
        return json.loads((self.root / "state.json").read_text())

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def run_plugin(self, env=None):
        return subprocess.run(["bash", str(REPO / "renumber.sh")], env=env or self.env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_numbering_and_steady_state(self):
        self.assert_success(self.run_plugin())
        state = self.read_state()
        self.assertEqual([row["label"] for row in state["tabs"]],
                         ["[1] shell", "[2]", r"[1] foo\bar"])
        self.assertEqual([row["label"] for row in state["workspaces"]], ["work", "other"])
        self.assertEqual([row["tokens"] for row in state["workspaces"]],
                         [{"number": "(1)"}, {"number": "(2)"}])
        self.assertEqual([row["tokens"] for row in state["panes"]],
                         [{"wsnum": "(1)"}, {"wsnum": "(2)"}])
        before = len(self.calls())
        self.assert_success(self.run_plugin())
        self.assertEqual(self.calls()[before:],
                         [["tab", "list"], ["workspace", "list"], ["pane", "list"]])

    def test_close_and_reorder(self):
        self.assert_success(self.run_plugin())
        state = self.read_state()
        state["tabs"] = [state["tabs"][2], state["tabs"][1]]
        state["workspaces"].reverse()
        for number, row in enumerate(state["workspaces"], 1):
            row["number"] = number
        state["panes"][0]["workspace_id"] = "w2"
        self.write_state(state)
        self.assert_success(self.run_plugin())
        state = self.read_state()
        self.assertEqual([row["label"] for row in state["tabs"]], [r"[1] foo\bar", "[1]"])
        self.assertEqual([row["tokens"]["number"] for row in state["workspaces"]], ["(1)", "(2)"])
        self.assertEqual([row["tokens"]["wsnum"] for row in state["panes"]], ["(1)", "(1)"])

    def test_format_change_converges(self):
        self.assert_success(self.run_plugin())
        (self.root / "config" / "config.toml").write_text(
            'tab_format = "<{n}>"\nworkspace_format = " No. {n} "\n')
        self.assert_success(self.run_plugin())
        state = self.read_state()
        self.assertEqual([row["label"] for row in state["tabs"]],
                         ["<1> shell", "<2>", r"<1> foo\bar"])
        self.assertEqual(state["workspaces"][0]["tokens"]["number"], "No. 1")
        self.assertEqual(state["panes"][0]["tokens"]["wsnum"], "No. 1")
        before = len(self.calls())
        self.assert_success(self.run_plugin())
        self.assertTrue(all(call[1] == "list" for call in self.calls()[before:]))

    def test_failed_updates_and_disappeared_targets(self):
        for kind, target_id, collection in [
            ("tab", "t1", "tabs"), ("workspace", "w1", "workspaces"), ("pane", "p1", "panes")
        ]:
            for failure in ["error", "gone"]:
                with self.subTest(kind=kind, failure=failure):
                    state = copy.deepcopy(self.state)
                    state["failures"] = {kind: {target_id: failure}}
                    self.write_state(state)
                    result = self.run_plugin()
                    self.assertEqual(result.returncode, 1 if failure == "error" else 0, result.stderr)
                    after = self.read_state()
                    if failure == "gone":
                        self.assertFalse(any(row[kind + "_id"] == target_id for row in after[collection]))
                    tab = next(row for row in after["tabs"] if row["tab_id"] == "t2")
                    self.assertEqual(tab["label"], "[2]")
                    self.assertEqual(after["workspaces"][-1]["tokens"]["number"], "(2)")
                    self.assertEqual(after["panes"][-1]["tokens"]["wsnum"], "(2)")
                    if kind == "tab" and failure == "gone":
                        self.assert_success(self.run_plugin())
                        tab = next(row for row in self.read_state()["tabs"] if row["tab_id"] == "t2")
                        self.assertEqual(tab["label"], "[1]")

    def test_herdr_reading_stdin_does_not_skip_targets(self):
        self.assert_success(self.run_plugin(dict(self.env, FAKE_HERDR_READ_STDIN="1")))
        state = self.read_state()
        self.assertEqual([row["label"] for row in state["tabs"]],
                         ["[1] shell", "[2]", r"[1] foo\bar"])
        self.assertEqual([row["tokens"]["number"] for row in state["workspaces"]], ["(1)", "(2)"])
        self.assertEqual([row["tokens"]["wsnum"] for row in state["panes"]], ["(1)", "(2)"])

    def test_missing_digest_sha_is_named(self):
        lib = self.root / "perl5" / "Digest"
        lib.mkdir(parents=True)
        (lib / "SHA.pm").write_text('die "unavailable\\n";\n')
        result = self.run_plugin(dict(self.env, PERL5LIB=str(self.root / "perl5")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Digest::SHA is required", result.stderr)
        self.assertEqual(self.read_state(), self.state)

    def test_list_failures(self):
        for kind in ["tab", "workspace", "pane"]:
            for error in ["error", "malformed"]:
                with self.subTest(kind=kind, error=error):
                    state = copy.deepcopy(self.state)
                    state["list_errors"] = {kind: error}
                    self.write_state(state)
                    self.assertEqual(self.run_plugin().returncode, 1)

    def test_failed_update_cannot_verify_disappearance(self):
        for error in ["error", "malformed"]:
            with self.subTest(error=error):
                state = copy.deepcopy(self.state)
                state["failures"] = {"tab": {"t1": "error"}}
                state["verification_error"] = error
                self.write_state(state)
                self.assertEqual(self.run_plugin().returncode, 1)

    def start_gated(self):
        gate = self.root / "gate"
        gate.mkdir()
        env = dict(self.env, FAKE_HERDR_GATE=str(gate))
        process = subprocess.Popen(["bash", str(REPO / "renumber.sh")], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.finish_process, process, gate)
        deadline = time.monotonic() + 5
        while not (gate / "entered").exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                self.fail("lock holder did not reach the gate")
            time.sleep(0.01)
        return process, gate

    @staticmethod
    def finish_process(process, gate):
        (gate / "release").touch()
        try:
            process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()

    def test_pending_event_is_processed(self):
        process, gate = self.start_gated()
        state = copy.deepcopy(self.state)
        state["tabs"].append({"workspace_id": "w1", "tab_id": "t4", "label": "new"})
        self.write_state(state)
        self.assert_success(self.run_plugin())
        self.assertEqual(len(self.calls()), 1)
        (gate / "release").touch()
        _, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(self.read_state()["tabs"][-1]["label"], "[3] new")
        self.assertEqual(self.calls().count(["tab", "list"]), 2)
        self.assertFalse(list(self.root.glob("*.pending")))

    def test_socket_paths_do_not_share_lock(self):
        self.env["HERDR_SOCKET_PATH"] = "/tmp/herdr/a/b.sock"
        process, gate = self.start_gated()
        env = dict(self.env, HERDR_SOCKET_PATH="/tmp/herdr/a_b.sock")
        self.assert_success(self.run_plugin(env))
        self.assertEqual(len(list(self.root.glob("*.lock"))), 2)
        self.assertGreater(len(self.calls()), 1)
        (gate / "release").touch()
        _, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stderr)


if __name__ == "__main__":
    unittest.main()
