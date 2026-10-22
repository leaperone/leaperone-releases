#!/usr/bin/env python3
"""Policy: LEAPERone API and WWW production deploys share one literal concurrency group."""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"

SHARED_GROUP = "leaperone-frontends-production"
API_WORKFLOW = WORKFLOW_DIR / "deploy-leaperone.yml"
WWW_WORKFLOW = WORKFLOW_DIR / "deploy-leaperone-www.yml"
REUSABLE_FRONTEND = WORKFLOW_DIR / "deploy-leaperone-frontend.yml"

# Workflows that must keep the shared frontend production group unchanged.
OTHER_SHARED_GROUP_WORKFLOWS = (
    WORKFLOW_DIR / "deploy-leaperone-dashboard.yml",
    WORKFLOW_DIR / "deploy-leaperone-www-cn.yml",
    WORKFLOW_DIR / "deploy-leaperone-frontends.yml",
)

EXPRESSION_RE = re.compile(r"\$\{\{")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _concurrency_block(text: str) -> str | None:
    match = re.search(
        r"(?ms)^concurrency:\n((?:[ \t].*\n?)*)",
        text,
    )
    return match.group(1) if match else None


def _field(block: str | None, name: str) -> str | None:
    if block is None:
        return None
    match = re.search(rf"^[ \t]+{name}:[ \t]*(.*)$", block, re.MULTILINE)
    if not match:
        return None
    value = match.group(1).strip()
    if not value or value in {"|", ">"}:
        return None
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    elif value.startswith("'") and value.endswith("'"):
        value = value[1:-1]
    return value


def _parse_concurrency(path: Path) -> tuple[str | None, str | None]:
    block = _concurrency_block(_read(path))
    return _field(block, "group"), _field(block, "cancel-in-progress")


def _require_literal_group(path: Path, group: str | None) -> list[str]:
    errors: list[str] = []
    if group is None:
        errors.append(f"{path.relative_to(REPO_ROOT)}: missing concurrency.group")
        return errors
    if not group.strip():
        errors.append(f"{path.relative_to(REPO_ROOT)}: empty concurrency.group")
    if EXPRESSION_RE.search(group):
        errors.append(
            f"{path.relative_to(REPO_ROOT)}: concurrency.group must be a literal, not an expression"
        )
    return errors


def verify_repo() -> list[str]:
    errors: list[str] = []

    if _concurrency_block(_read(REUSABLE_FRONTEND)) is not None:
        errors.append(
            f"{REUSABLE_FRONTEND.relative_to(REPO_ROOT)}: reusable frontend workflow must not declare concurrency (nested lock)"
        )

    api_group, api_cancel = _parse_concurrency(API_WORKFLOW)
    www_group, www_cancel = _parse_concurrency(WWW_WORKFLOW)

    errors.extend(_require_literal_group(API_WORKFLOW, api_group))
    errors.extend(_require_literal_group(WWW_WORKFLOW, www_group))

    if api_group is not None and www_group is not None and api_group != www_group:
        errors.append(
            "API and WWW production deploy workflows must share the same concurrency group "
            f"(got API={api_group!r}, WWW={www_group!r})"
        )

    if api_group != SHARED_GROUP:
        errors.append(
            f"{API_WORKFLOW.relative_to(REPO_ROOT)}: group must be {SHARED_GROUP!r}, got {api_group!r}"
        )
    if www_group != SHARED_GROUP:
        errors.append(
            f"{WWW_WORKFLOW.relative_to(REPO_ROOT)}: group must be {SHARED_GROUP!r}, got {www_group!r}"
        )

    for workflow in (API_WORKFLOW, WWW_WORKFLOW):
        group, cancel = _parse_concurrency(workflow)
        if cancel is None:
            errors.append(f"{workflow.relative_to(REPO_ROOT)}: missing cancel-in-progress")
        elif cancel.lower() != "false":
            errors.append(
                f"{workflow.relative_to(REPO_ROOT)}: cancel-in-progress must be false, got {cancel!r}"
            )

    for workflow in OTHER_SHARED_GROUP_WORKFLOWS:
        group, cancel = _parse_concurrency(workflow)
        errors.extend(_require_literal_group(workflow, group))
        if group != SHARED_GROUP:
            errors.append(
                f"{workflow.relative_to(REPO_ROOT)}: group must remain {SHARED_GROUP!r}, got {group!r}"
            )
        if cancel is None or cancel.lower() != "false":
            errors.append(
                f"{workflow.relative_to(REPO_ROOT)}: cancel-in-progress must be false, got {cancel!r}"
            )

    email_worker = WORKFLOW_DIR / "deploy-leaperone-email-worker.yml"
    ew_group, _ = _parse_concurrency(email_worker)
    if ew_group == SHARED_GROUP:
        errors.append(
            f"{email_worker.relative_to(REPO_ROOT)}: must not use the shared frontend production group"
        )

    return errors


def _self_test() -> None:
    import tempfile
    import unittest

    class PolicyTests(unittest.TestCase):
        def test_missing_groups_do_not_false_positive_match(self) -> None:
            api_group, www_group = None, None
            self.assertFalse(api_group == www_group and api_group is not None)

        def test_reject_expression_group(self) -> None:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                wf = root / "deploy-leaperone.yml"
                wf.write_text(
                    "concurrency:\n  group: ${{ github.workflow }}\n  cancel-in-progress: false\n",
                    encoding="utf-8",
                )
                block = _concurrency_block(wf.read_text(encoding="utf-8"))
                group = _field(block, "group")
                self.assertIsNotNone(group)
                self.assertTrue(EXPRESSION_RE.search(group or ""))

        def test_reject_cancel_in_progress_true(self) -> None:
            block = "  group: leaperone-frontends-production\n  cancel-in-progress: true\n"
            self.assertEqual(_field(block, "cancel-in-progress"), "true")

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PolicyTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)


def main() -> int:
    if "--self-test" in sys.argv:
        _self_test()
        return 0

    errors = verify_repo()
    if errors:
        for message in errors:
            print(f"ERROR: {message}", file=sys.stderr)
        return 1

    print("OK: LEAPERone deploy concurrency policy satisfied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
