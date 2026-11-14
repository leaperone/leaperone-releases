#!/usr/bin/env python3
"""Check release workflow guardrails that prevent silent queueing and skips."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"


def read(name: str) -> str:
    return (WORKFLOW_DIR / name).read_text(encoding="utf-8")


def job_block(workflow: str, job: str) -> str:
    text = read(workflow)
    match = re.search(
        rf"(?ms)^  {re.escape(job)}:\n((?:    .*\n|\n)*)?(?=^  [A-Za-z0-9_-]+:|\Z)",
        text,
    )
    if not match:
        raise AssertionError(f"{workflow}: missing job {job}")
    return match.group(0)


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"{label}: missing {needle!r}")


def main() -> int:
    errors: list[str] = []

    deploy = read("deploy-twosomeone.yml")
    backend = read("deploy-twosomeone-backend.yml")
    multipost = read("deploy-multipost.yml")

    try:
        web_build = job_block("deploy-twosomeone.yml", "build-and-push")
        require(web_build, "timeout-minutes: 45", "2SOMEone web build")
        require(
            web_build,
            "cancel-in-progress: ${{ needs.prepare.outputs.deploy_env == 'beta' }}",
            "2SOMEone web concurrency",
        )
        require(deploy, "  migrate:\n", "2SOMEone migration job")
        require(
            deploy,
            "group: deploy-twosomeone-migrate-${{ needs.prepare.outputs.deploy_env }}",
            "2SOMEone migration concurrency",
        )
        require(deploy, "needs: [prepare, build-and-push, migrate]", "2SOMEone deploy ordering")

        backend_build = job_block("deploy-twosomeone-backend.yml", "build-and-push")
        require(backend_build, "timeout-minutes: 30", "2SOMEone backend build")
        require(backend, "Wait for the matching web migration", "2SOMEone backend migration wait")
        require(backend, "wait_for_web", "2SOMEone backend migration selector")
        require(backend, "components=all requires a full source_sha", "2SOMEone combined source guard")

        multipost_build = job_block("deploy-multipost.yml", "build-and-push")
        require(multipost_build, "timeout-minutes: 45", "MultiPost build")
        require(multipost_build, "group: deploy-multipost-production", "MultiPost build concurrency")
        multipost_migrate = job_block("deploy-multipost.yml", "migrate-production")
        require(multipost_migrate, "group: deploy-multipost-production", "MultiPost migration concurrency")
        multipost_deploy = job_block("deploy-multipost.yml", "deploy-de")
        require(multipost_deploy, "group: deploy-multipost-production", "MultiPost deploy concurrency")
        require(multipost, "source_sha: ${{ steps.resolve.outputs.source_sha }}", "MultiPost source output")
        require(multipost, "ref: ${{ needs.resolve-context.outputs.source_sha }}", "MultiPost immutable build checkout")
        require(multipost, "ref: ${{ needs.build-and-push.outputs.source_sha }}", "MultiPost immutable migration checkout")
        require(multipost, "  - name: Resolve migration mode", "MultiPost migration resolver")
        require(multipost, "if: steps.migration.outputs.mode == 'apply'", "MultiPost migration promotion")
        require(read("deploy-de.yml"), "timeout-minutes: 30", "DE deploy timeout")
    except AssertionError as exc:
        errors.append(str(exc))

    for path in WORKFLOW_DIR.glob("deploy-*.yml"):
        text = path.read_text(encoding="utf-8")
        if "exit 78" in text:
            errors.append(f"{path.relative_to(REPO_ROOT)}: exit 78 still marks noci as a failure")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("OK: release workflow policy satisfied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
