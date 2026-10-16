#!/usr/bin/env python3
"""Exercise the workflow's upload shell against local fake CLI processes."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/upload-telemetry-sourcemaps.yml"


def upload_script():
    step = WORKFLOW.read_text().split("      - name: Upload to internal PostHog and Sentry\n", 1)[1]
    script = step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
    return textwrap.dedent(script)


class UploadPolicyTest(unittest.TestCase):
    def run_upload(self, *, optional, posthog_status=0, sentry_status=0, stalled=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Record the commands and model an upload that succeeds, fails, or hangs.
            cli = root / "pnpm"
            cli.write_text(textwrap.dedent("""\
                #!/usr/bin/env bash
                set -eu
                echo "$*" >> "$CALLS"
                if [[ "$*" == *'@posthog/cli'* ]]; then
                  if [[ "$POSTHOG_STALLED" == 1 ]]; then sleep 10; fi
                  exit "$POSTHOG_STATUS"
                fi
                if [[ "$*" == *'sourcemaps upload'* ]]; then exit "$SENTRY_STATUS"; fi
                exit 0
                """))
            cli.chmod(0o755)
            # Keep the production deadline assertion, but shorten it for the test.
            timeout = root / "timeout"
            timeout.write_text(textwrap.dedent("""\
                #!/usr/bin/env bash
                set -eu
                [[ "$1" == --kill-after=10s && "$2" == 180s ]]
                shift 2
                exec /usr/bin/timeout --kill-after=0.1s 0.3s "$@"
                """))
            timeout.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "RUNNER_TEMP": directory,
                "GITHUB_RUN_ID": "1",
                "GITHUB_RUN_ATTEMPT": "1",
                "SOURCE_MAP_DIR": directory,
                "POSTHOG_CLI_API_KEY": "test-key",
                "POSTHOG_CLI_PROJECT_ID": "1",
                "POSTHOG_CLI_HOST": "https://example.invalid",
                "POSTHOG_RELEASE_NAME": "test",
                "POSTHOG_RELEASE_VERSION": "test-sha",
                "ALLOW_POSTHOG_FAILURE": str(optional).lower(),
                "SENTRY_AUTH_TOKEN": "test-key",
                "SENTRY_URL": "https://example.invalid",
                "SENTRY_RELEASE": "test-release",
                "POSTHOG_STATUS": str(posthog_status),
                "SENTRY_STATUS": str(sentry_status),
                "POSTHOG_STALLED": "1" if stalled else "0",
                "CALLS": str(root / "calls"),
            }
            result = subprocess.run(
                ["bash", "-c", upload_script()], env=env,
                capture_output=True, text=True, timeout=5,
            )
            calls = (root / "calls").read_text()
            self.assertIn("@posthog/cli", calls)
            self.assertIn("@sentry/cli", calls)
            self.assertIn("sourcemaps upload", calls)
            if sentry_status == 0:
                self.assertIn("releases finalize", calls)
            return result

    def test_failure_matrix(self):
        for optional in (False, True):
            for posthog in (0, 1):
                for sentry in (0, 1):
                    with self.subTest(optional=optional, posthog=posthog, sentry=sentry):
                        result = self.run_upload(
                            optional=optional, posthog_status=posthog, sentry_status=sentry,
                        )
                        expected_success = sentry == 0 and (optional or posthog == 0)
                        self.assertEqual(result.returncode == 0, expected_success, result.stderr)
                        self.assertEqual("::warning::" in result.stdout, optional and posthog != 0)

    def test_stalled_posthog_is_bounded(self):
        for optional in (False, True):
            with self.subTest(optional=optional):
                result = self.run_upload(optional=optional, stalled=True)
                self.assertEqual(result.returncode == 0, optional, result.stderr)
                if optional:
                    self.assertIn("::warning::", result.stdout)
                    self.assertIn("exit 124", result.stdout)


if __name__ == "__main__":
    unittest.main()
