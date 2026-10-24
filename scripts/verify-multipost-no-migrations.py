#!/usr/bin/env python3
"""Web-only MultiPost release guard: no db/ drift since last web-v* tag and Atlas status OK."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.parse
from typing import Any

READONLY_OPTION = "default_transaction_read_only=on"
PRISMA_QUERY_KEYS = (
    "schema",
    "pgbouncer",
    "connection_limit",
    "pool_timeout",
    "connect_timeout",
    "socket_timeout",
    "statement_cache_size",
    "TimeZone",
)
WEB_TAG_PATTERN = "web-v*"
DB_SCOPE = "db"
ATLAS_CMD = (
    "atlas",
    "migrate",
    "status",
    "--env",
    "production",
    "--config",
    "file://db/atlas/atlas.hcl",
    "--format",
    "{{ json . }}",
)


class VerifyError(Exception):
    pass


def _run(
    args: list[str],
    *,
    cwd: str | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        text=True,
        capture_output=True,
        check=check,
    )


def _safe_fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise VerifyError(message)


def resolve_baseline_tag() -> str:
    try:
        result = _run(
            [
                "git",
                "describe",
                "--tags",
                "--match",
                WEB_TAG_PATTERN,
                "--abbrev=0",
                "HEAD^",
            ],
            check=True,
        )
    except subprocess.CalledProcessError:
        _safe_fail("migration guard: no prior web-v release tag found for baseline")
    tag = result.stdout.strip()
    if not tag or not re.fullmatch(r"(refs/tags/)?web-v[0-9]+\.[0-9]+\.[0-9]+.*", tag):
        _safe_fail("migration guard: baseline tag is missing or not a web-v release")
    return tag


def assert_no_db_diff_since(baseline: str) -> None:
    try:
        _run(["git", "diff", "--quiet", baseline, "HEAD", "--", DB_SCOPE], check=True)
    except subprocess.CalledProcessError:
        _safe_fail(
            "migration guard: database tree changed since last web release; "
            "web-only deploy cannot include schema or migration updates"
        )


def strip_prisma_query_params(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    if not parsed.query:
        return url
    pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    filtered = [(k, v) for k, v in pairs if k not in PRISMA_QUERY_KEYS]
    query = urllib.parse.urlencode(filtered)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, query, parsed.fragment)
    )


def _normalize_options_value(options: str) -> str:
    lowered = options.lower()
    if "default_transaction_read_only=off" in lowered.replace(" ", ""):
        _safe_fail("migration guard: refusing database URL that disables read-only transactions")
    if READONLY_OPTION.replace("=", "=") in lowered.replace(" ", ""):
        # already requests read-only; still ensure our -c form is present
        pass
    cleaned = re.sub(
        r"-c\s+default_transaction_read_only=\w+",
        "",
        options,
        flags=re.IGNORECASE,
    ).strip()
    suffix = f"-c {READONLY_OPTION}"
    return f"{cleaned} {suffix}".strip() if cleaned else suffix


def enforce_readonly_database_url(url: str) -> str:
    url = strip_prisma_query_params(url)
    parsed = urllib.parse.urlsplit(url)
    pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    options_value: str | None = None
    rest: list[tuple[str, str]] = []
    for key, value in pairs:
        if key == "options":
            options_value = value
        else:
            rest.append((key, value))
    merged_options = _normalize_options_value(options_value or "")
    rest.append(("options", merged_options))
    query = urllib.parse.urlencode(rest)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, query, parsed.fragment)
    )


def _pending_count(payload: Any) -> int | None:
    if isinstance(payload, dict):
        if "Pending" in payload and isinstance(payload["Pending"], (int, float)):
            return int(payload["Pending"])
        if "pending" in payload and isinstance(payload["pending"], (int, float)):
            return int(payload["pending"])
        for value in payload.values():
            found = _pending_count(value)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for item in payload:
            found = _pending_count(item)
            if found is not None:
                return found
    return None


def _current_count(payload: Any) -> int | None:
    if isinstance(payload, dict):
        if "Current" in payload and isinstance(payload["Current"], (int, float)):
            return int(payload["Current"])
        if "current" in payload and isinstance(payload["current"], (int, float)):
            return int(payload["current"])
        for value in payload.values():
            found = _current_count(value)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for item in payload:
            found = _current_count(item)
            if found is not None:
                return found
    return None


def _status_ok(payload: Any) -> bool:
    if isinstance(payload, dict):
        status = payload.get("Status") or payload.get("status")
        if isinstance(status, str) and status.upper() == "OK":
            return True
        for value in payload.values():
            if _status_ok(value):
                return True
    elif isinstance(payload, list):
        return any(_status_ok(item) for item in payload)
    return False


def run_atlas_status_readonly(database_url: str) -> tuple[int | None, int | None]:
    env = {**os.environ, "MULTIPOST_DATABASE_URL": database_url}
    try:
        result = _run(list(ATLAS_CMD), check=True, cwd=None)
    except subprocess.CalledProcessError as exc:
        _safe_fail("migration guard: atlas migrate status failed (details withheld)")
        raise VerifyError from exc
    stdout = result.stdout.strip()
    if not stdout:
        _safe_fail("migration guard: atlas migrate status returned empty output")
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        _safe_fail("migration guard: atlas migrate status returned non-JSON output")
    if not _status_ok(payload):
        _safe_fail("migration guard: atlas migrate status is not OK")
    pending = _pending_count(payload)
    if pending is None:
        _safe_fail("migration guard: could not read pending migration count from atlas status")
    if pending != 0:
        _safe_fail("migration guard: pending database migrations must be zero for web-only deploy")
    current = _current_count(payload)
    return current, pending


def main() -> int:
    raw_url = os.environ.get("MULTIPOST_DATABASE_URL", "").strip()
    if not raw_url:
        print("MULTIPOST_DATABASE_URL is required", file=sys.stderr)
        return 1
    try:
        baseline = resolve_baseline_tag()
        assert_no_db_diff_since(baseline)
        readonly_url = enforce_readonly_database_url(raw_url)
        current, pending = run_atlas_status_readonly(readonly_url)
        print(
            json.dumps(
                {
                    "baseline_tag": baseline,
                    "atlas_current": current,
                    "atlas_pending": pending,
                    "migration_guard": "ok",
                }
            )
        )
        return 0
    except VerifyError:
        return 1


if __name__ == "__main__":
    sys.exit(main())
