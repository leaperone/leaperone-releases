#!/usr/bin/env python3
"""Offline tests for verify-multipost-no-migrations.py (mocked subprocess / env)."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_PATH = Path(__file__).resolve().parent / "verify-multipost-no-migrations.py"
SPEC = importlib.util.spec_from_file_location("verify_multipost", SCRIPT_PATH)
verify = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(verify)


class SubprocessRunner:
    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def run(self, args: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
        self.calls.append(list(args))
        raise AssertionError(f"unhandled subprocess: {args}")


class VerifyMultipostNoMigrationsTests(unittest.TestCase):
    def test_enforce_readonly_rejects_off_override(self) -> None:
        url = "postgresql://user:secret@127.0.0.1:5432/db?options=-c%20default_transaction_read_only%3Doff"
        with self.assertRaises(verify.VerifyError):
            verify.enforce_readonly_database_url(url)

    def test_enforce_readonly_strips_prisma_and_adds_option(self) -> None:
        url = "postgresql://user:secret@127.0.0.1:5432/app?schema=public&pgbouncer=true"
        readonly = verify.enforce_readonly_database_url(url)
        self.assertIn("default_transaction_read_only%3Don", readonly)
        self.assertNotIn("schema=", readonly)
        self.assertNotIn("pgbouncer=", readonly)

    def test_resolve_baseline_uses_head_parent(self) -> None:
        runner = SubprocessRunner()

        def fake_run(args, **kwargs):
            runner.calls.append(list(args))
            if args[:4] == ["git", "describe", "--tags", "--match"]:
                return subprocess.CompletedProcess(args, 0, "web-v1.0.0\n", "")
            raise AssertionError(args)

        with mock.patch.object(verify, "_run", side_effect=fake_run):
            tag = verify.resolve_baseline_tag()
        self.assertEqual(tag, "web-v1.0.0")
        self.assertEqual(runner.calls[0][-1], "HEAD^")

    def test_no_baseline_fails_closed(self) -> None:
        with mock.patch.object(
            verify,
            "_run",
            side_effect=subprocess.CalledProcessError(1, "git"),
        ):
            with self.assertRaises(verify.VerifyError):
                verify.resolve_baseline_tag()

    def test_db_diff_rejects_changes(self) -> None:
        with mock.patch.object(
            verify,
            "_run",
            side_effect=subprocess.CalledProcessError(1, "git", "", ""),
        ):
            with self.assertRaises(verify.VerifyError):
                verify.assert_no_db_diff_since("web-v1.0.0")

    def test_atlas_status_ok_zero_pending(self) -> None:
        payload = json.dumps({"Status": "OK", "Current": 3, "Pending": 0})

        def fake_run(args, **kwargs):
            self.assertNotIn("apply", args)
            return subprocess.CompletedProcess(args, 0, payload, "")

        with mock.patch.object(verify, "_run", side_effect=fake_run):
            current, pending = verify.run_atlas_status_readonly("postgresql://u:p@h/db")
        self.assertEqual((current, pending), (3, 0))

    def test_atlas_pending_fails(self) -> None:
        payload = json.dumps({"Status": "OK", "Pending": 2})

        def fake_run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, payload, "")

        with mock.patch.object(verify, "_run", side_effect=fake_run):
            with self.assertRaises(verify.VerifyError):
                verify.run_atlas_status_readonly("postgresql://u:p@h/db")

    def test_atlas_non_json_fails(self) -> None:
        with mock.patch.object(
            verify,
            "_run",
            return_value=subprocess.CompletedProcess([], 0, "not-json", ""),
        ):
            with self.assertRaises(verify.VerifyError):
                verify.run_atlas_status_readonly("postgresql://u:p@h/db")

    def test_atlas_process_failure_without_stderr_leak(self) -> None:
        err = subprocess.CalledProcessError(
            1,
            "atlas",
            "",
            "postgresql://user:topsecret@host/db connection failed",
        )

        with mock.patch.object(verify, "_run", side_effect=err):
            with self.assertRaises(verify.VerifyError) as ctx:
                verify.run_atlas_status_readonly("postgresql://u:p@h/db")
        self.assertNotIn("topsecret", str(ctx.exception))

    def test_main_never_invokes_apply(self) -> None:
        runner = SubprocessRunner()

        def fake_run(args, **kwargs):
            runner.calls.append(list(args))
            if args[:3] == ["git", "describe", "--tags"]:
                return subprocess.CompletedProcess(args, 0, "web-v1.0.0\n", "")
            if args[:3] == ["git", "diff", "--quiet"]:
                return subprocess.CompletedProcess(args, 0, "", "")
            if args and args[0] == "atlas":
                body = json.dumps({"Status": "OK", "Current": 1, "Pending": 0})
                return subprocess.CompletedProcess(args, 0, body, "")
            raise AssertionError(args)

        with mock.patch.object(verify, "_run", side_effect=fake_run):
            with mock.patch.dict(
                os.environ,
                {"MULTIPOST_DATABASE_URL": "postgresql://u:p@127.0.0.1:5432/db"},
                clear=False,
            ):
                code = verify.main()
        self.assertEqual(code, 0)
        joined = " ".join(" ".join(c) for c in runner.calls)
        self.assertNotIn("apply", joined)


if __name__ == "__main__":
    unittest.main()
