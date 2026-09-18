#!/usr/bin/env python3
"""Exercise public inspection commands with disposable receipts and fake Docker."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUN_ID = "20260918T120000Z-123"


class InspectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name)
        self.profiles = self.workspace / "profiles"
        self.profiles.mkdir()
        self.run = self.workspace / "learnings-inbox" / "headless-runs" / RUN_ID
        self.run.mkdir(parents=True)
        self.env = {**os.environ, "SANDBOX_LOGIN": "fixture",
                    "SANDBOX_WORKSPACE": str(self.workspace), "SANDBOX_PROFILE": "",
                    "SANDBOX_RUNTIME": "docker",
                    "SANDBOX_PROFILE_DIR": str(self.profiles),
                    "PATH": str(self.workspace) + os.pathsep + os.environ["PATH"]}
        self.docker = self.workspace / "docker"
        self.docker.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$SANDBOX_WORKSPACE/docker-args"\nprintf "running\\n"\n')
        self.docker.chmod(0o755)
        self.meta = dict(run_id=RUN_ID, start="2026-09-18T12:00:00Z", profile="",
                         login="fixture", container="fixture-sandbox", workspace=str(self.workspace),
                         sandbox_home="private-path", secret="DO_NOT_EXPOSE")
        self.write_meta()
        (self.run / "stdout.log").write_text("DO_NOT_EXPOSE")
        (self.run / "command.txt").write_text("DO_NOT_EXPOSE")

    def write_meta(self):
        (self.run / "meta.env").write_text("".join(f"{k}={v}\n" for k, v in self.meta.items()))

    def call(self, *args, code=0):
        proc = subprocess.run(["/bin/bash", str(ROOT / "bin/sandbox.sh"), *args],
                              env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(proc.returncode, code, proc.stderr + proc.stdout)
        self.assertNotIn("DO_NOT_EXPOSE", proc.stdout + proc.stderr)
        return json.loads(proc.stdout)

    def finish(self, code):
        (self.run / "exit_code").write_text(f"{code}\n")
        self.meta.update(end="2026-09-18T12:01:00Z", exit_code=str(code))
        self.write_meta()

    def test_completed_results_are_typed_and_redacted(self):
        for code, state in [(0, "succeeded"), (7, "failed")]:
            with self.subTest(code=code):
                self.finish(code)
                result = self.call("run-result", RUN_ID)
                self.assertEqual(result, dict(schema_version=1, profile=None, run_id=RUN_ID,
                    state=state, exit_code=code, started_at=self.meta["start"], ended_at=self.meta["end"]))

    def test_missing_or_partial_completion_is_incomplete(self):
        self.assertEqual(self.call("run-result", RUN_ID)["state"], "incomplete")
        (self.run / "exit_code").write_text("0\n")
        result = self.call("run-result", RUN_ID)
        self.assertEqual(result["state"], "incomplete")
        self.assertIsNone(result["exit_code"])

    def test_bad_exit_evidence_never_succeeds(self):
        self.finish(0)
        for bad in ["256", "-1", "0\nsecret", "", "7"]:
            with self.subTest(bad=bad):
                (self.run / "exit_code").write_text(bad)
                self.assertEqual(self.call("run-result", RUN_ID, code=2)["error"], "invalid_receipt")

    def test_missing_run_and_invalid_arguments(self):
        self.assertEqual(self.call("run-result", "20260918T120000Z-456", code=2)["error"], "run_not_found")
        for args in [(), (RUN_ID, "extra")]:
            self.assertEqual(self.call("run-result", *args, code=2)["error"], "invalid_arguments")
        for run in ["../secret", "/tmp/secret", ".", RUN_ID + "/meta.env"]:
            self.assertEqual(self.call("run-result", run, code=2)["error"], "invalid_run_id")

    def test_scope_must_match(self):
        for key in ["profile", "login", "workspace", "container", "run_id"]:
            with self.subTest(key=key):
                old = self.meta[key]
                self.meta[key] = "other"
                self.write_meta()
                self.assertEqual(self.call("run-result", RUN_ID, code=2)["error"], "receipt_scope_mismatch")
                self.meta[key] = old

    def test_named_profile(self):
        (self.profiles / "personal.env").write_text("export SANDBOX_LOGIN=fixture\n")
        self.meta["profile"] = "personal"
        self.write_meta()
        self.assertEqual(self.call("--profile=personal", "run-result", RUN_ID)["profile"], "personal")

    def test_profile_traversal_is_rejected_before_source(self):
        (self.workspace / "escape.env").write_text("touch '" + str(self.workspace / "executed") + "'\n")
        proc = subprocess.run(["/bin/bash", str(ROOT / "bin/sandbox.sh"), "--profile=../escape", "status", "--json"],
                              env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(proc.returncode, 78)
        self.assertFalse((self.workspace / "executed").exists())

    def test_profile_creation_uses_the_same_name_rules(self):
        proc = subprocess.run(["/bin/bash", str(ROOT / "bin/sandbox.sh"), "profile-new", "../escape"],
                              env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(proc.returncode, 2)
        self.assertFalse((self.workspace / "escape.env").exists())

    def test_metadata_is_data_not_shell(self):
        self.meta["unknown"] = "$(touch " + str(self.workspace / "executed") + ")"
        self.write_meta()
        self.call("run-result", RUN_ID)
        self.assertFalse((self.workspace / "executed").exists())

    def test_symlinks_and_fifo_are_rejected(self):
        meta = self.run / "meta.env"
        meta.unlink()
        meta.symlink_to(self.run / "stdout.log")
        self.call("run-result", RUN_ID, code=2)
        meta.unlink()
        os.mkfifo(meta)
        self.call("run-result", RUN_ID, code=2)
        moved = self.run.with_name("saved")
        self.run.rename(moved)
        self.run.symlink_to(moved, target_is_directory=True)
        self.call("run-result", RUN_ID, code=2)

    def test_oversized_duplicate_and_malformed_metadata(self):
        for text in ["a" * 8193, "not-an-assignment", "a=1\na=2", "\udcff"]:
            (self.run / "meta.env").write_bytes(text.encode("utf-8", errors="surrogateescape"))
            self.assertEqual(self.call("run-result", RUN_ID, code=2)["error"], "invalid_receipt")

    def test_inspection_does_not_change_receipts(self):
        self.finish(0)
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.run.iterdir()}
        self.call("run-result", RUN_ID)
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.run.iterdir()})

    def test_status_uses_read_only_docker_query(self):
        self.assertEqual(self.call("status", "--json"), dict(schema_version=1, profile=None,
                                                             container="fixture-sandbox", state="running"))
        self.assertEqual((self.workspace / "docker-args").read_text().splitlines(),
                         ["container", "ls", "--all", "--filter", "name=^/fixture\\-sandbox$", "--format", "{{.State}}"])

    def test_status_honors_selected_runtime(self):
        podman = self.workspace / "podman"
        podman.write_text('#!/bin/sh\nprintf "paused\\n"\n')
        podman.chmod(0o755)
        self.env["SANDBOX_RUNTIME"] = "podman"
        self.assertEqual(self.call("status", "--json")["state"], "paused")
        self.assertFalse((self.workspace / "docker-args").exists())

    def test_status_absent_stopped_and_error_are_distinct(self):
        for output, code, expected in [("", 0, "absent"), ("exited", 0, "exited"),
                                      ("DO_NOT_EXPOSE", 1, "runtime_unavailable"),
                                      ("running\\nexited", 0, "invalid_runtime_response")]:
            self.docker.write_text(f'#!/bin/sh\nprintf "{output}\\n"\nexit {code}\n')
            result = self.call("status", "--json", code=0 if expected in {"absent", "exited"} else 2)
            self.assertEqual(result.get("state", result.get("error")), expected)


if __name__ == "__main__":
    unittest.main()
