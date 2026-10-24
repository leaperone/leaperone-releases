"""Offline boundary tests for the Web-only release migration guard."""
import importlib.util
import io
import json
import os
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

spec = importlib.util.spec_from_file_location("guard", Path(__file__).with_name("verify-multipost-no-migrations.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

URL = "postgresql://fixture:private-fixture@example.invalid/db?schema=public&pgbouncer=true"
STATUS = {
    "Env": {}, "Available": [{}, {}], "Applied": [{}, {}],
    "Current": "20260101000001", "Next": "Already at latest version", "Status": "OK",
}


class GuardTests(unittest.TestCase):
    def test_readonly_options_and_existing_connection_options(self):
        url = guard.enforce_readonly_database_url(URL + "&options=-c%20search_path%3Dpublic")
        query = parse_qs(urlsplit(url).query)
        self.assertNotIn("schema", query)
        self.assertNotIn("pgbouncer", query)
        self.assertEqual(query["options"], ["-c search_path=public -c default_transaction_read_only=on"])

    def test_readonly_overrides_are_rejected(self):
        for suffix in ["&options=-c%20default_transaction_read_only%3Doff", "&default_transaction_read_only=off"]:
            with self.assertRaises(guard.VerifyError):
                guard.enforce_readonly_database_url(URL + suffix)

    def test_real_atlas_json_schema(self):
        self.assertEqual(guard.validate_atlas_status(json.dumps(STATUS)), {
            "current": "20260101000001", "applied": 2, "pending": 0,
        })

    def test_pending_invalid_or_unknown_status_fails_closed(self):
        for value in ["invalid", "[]", json.dumps({"Status": "OK", "Current": 1, "Pending": 0})]:
            with self.assertRaises(guard.VerifyError):
                guard.validate_atlas_status(value)
        for change in [{"Status": "PENDING"}, {"Next": "20260102000000"}, {"Applied": [{}]}, {"Current": None}]:
            with self.assertRaises(guard.VerifyError):
                guard.validate_atlas_status(json.dumps({**STATUS, **change}))

    def run_guard(self, failure=None, baseline="web-v1.0.0"):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            if args[0] == failure:
                raise subprocess.CalledProcessError(1, args, stderr=URL)
            if args[:2] == ["git", "describe"]:
                return subprocess.CompletedProcess(args, 0, baseline, "")
            if args[:2] == ["git", "diff"]:
                if failure == "diff":
                    raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0, "", "")
            self.assertEqual(args[:3], ["atlas", "migrate", "status"])
            self.assertIn("default_transaction_read_only=on", parse_qs(urlsplit(kwargs["env"]["MULTIPOST_DATABASE_URL"]).query)["options"][0])
            return subprocess.CompletedProcess(args, 0, json.dumps(STATUS), "")
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(guard.subprocess, "run", side_effect=run), patch.dict(os.environ, {"MULTIPOST_DATABASE_URL": URL}), redirect_stdout(stdout), redirect_stderr(stderr):
            code = guard.main()
        self.assertNotIn("private-fixture", stdout.getvalue() + stderr.getvalue())
        self.assertNotIn("apply", [argument for args, _ in calls for argument in args])
        return code, calls, stdout.getvalue()

    def test_production_handler_uses_prior_tag_and_readonly_subprocess_env(self):
        code, calls, output = self.run_guard()
        self.assertEqual(code, 0)
        self.assertEqual(calls[0][0][-1], "HEAD^")
        self.assertEqual(calls[1][0], ["git", "diff", "--quiet", "web-v1.0.0", "HEAD", "--", "db"])
        self.assertEqual(json.loads(output)["pending"], 0)

    def test_missing_baseline_rejects_before_database(self):
        code, calls, _ = self.run_guard(failure="git")
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 1)

    def test_invalid_baseline_rejects_before_database(self):
        code, calls, _ = self.run_guard(baseline="main")
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 1)

    def test_changed_schema_rejects_before_database(self):
        code, calls, _ = self.run_guard(failure="diff")
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)

    def test_atlas_failure_does_not_leak_credentials(self):
        code, calls, _ = self.run_guard(failure="atlas")
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
