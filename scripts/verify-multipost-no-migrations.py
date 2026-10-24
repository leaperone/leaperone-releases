#!/usr/bin/env python3
"""Validate an unchanged database and a read-only Atlas status before Web deployment."""
import json
import os
import re
import subprocess
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

PRISMA_QUERY_KEYS = {
    "schema", "pgbouncer", "connection_limit", "pool_timeout", "connect_timeout",
    "socket_timeout", "statement_cache_size", "TimeZone",
}
READONLY_OPTION = "-c default_transaction_read_only=on"
ATLAS_CMD = [
    "atlas", "migrate", "status", "--env", "production", "--config",
    "file://db/atlas/atlas.hcl", "--format", "{{ json . }}",
]


class VerifyError(Exception):
    pass


def command(args, *, env=None):
    try:
        return subprocess.run(args, env=env, check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        # Atlas errors can include the database URL, so never forward raw stderr.
        raise VerifyError(f"migration guard: {args[0]} command failed; details withheld") from None


def enforce_readonly_database_url(url):
    parsed = urlsplit(url)
    if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname:
        raise VerifyError("migration guard: invalid PostgreSQL connection URL")
    pairs, options = [], []
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        if key in PRISMA_QUERY_KEYS:
            continue
        if key.lower() in {"default_transaction_read_only", "transaction_read_only"}:
            if value.lower() not in {"on", "true", "1"}:
                raise VerifyError("migration guard: conflicting read-only connection setting")
            continue
        if key == "options":
            if re.search(r"(?:default_)?transaction_read_only\s*=\s*(?:off|false|0)\b", value, re.I):
                raise VerifyError("migration guard: conflicting read-only connection options")
            options.append(value)
        else:
            pairs.append((key, value))
    pairs.append(("options", " ".join([*options, READONLY_OPTION])))
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(pairs), parsed.fragment))


def validate_atlas_status(raw):
    try:
        status = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        raise VerifyError("migration guard: Atlas returned invalid JSON") from None
    if not isinstance(status, dict) or status.get("Status") != "OK":
        raise VerifyError("migration guard: Atlas status is not OK")
    available, applied = status.get("Available"), status.get("Applied")
    # Atlas status JSON exposes Available/Applied and Next, not a Pending count.
    if not isinstance(available, list) or not isinstance(applied, list):
        raise VerifyError("migration guard: unrecognized Atlas status schema")
    if not available or len(available) != len(applied) or status.get("Next") != "Already at latest version":
        raise VerifyError("migration guard: pending or incomplete migrations")
    current = status.get("Current")
    if not isinstance(current, str) or not re.fullmatch(r"[0-9]+", current):
        raise VerifyError("migration guard: missing current migration version")
    return {"current": current, "applied": len(applied), "pending": 0}


def verify():
    raw_url = os.environ.get("MULTIPOST_DATABASE_URL", "").strip()
    if not raw_url:
        raise VerifyError("migration guard: MULTIPOST_DATABASE_URL is required")
    baseline = command([
        "git", "describe", "--tags", "--match", "web-v*", "--abbrev=0", "HEAD^",
    ]).strip()
    if not re.fullmatch(r"web-v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", baseline):
        raise VerifyError("migration guard: no valid prior Web release tag")
    command(["git", "diff", "--quiet", baseline, "HEAD", "--", "db"])
    env = {**os.environ, "MULTIPOST_DATABASE_URL": enforce_readonly_database_url(raw_url)}
    status = validate_atlas_status(command(ATLAS_CMD, env=env))
    return {"baseline_tag": baseline, **status, "migration_guard": "ok"}


def main():
    try:
        print(json.dumps(verify()))
        return 0
    except (VerifyError, ValueError):
        # Keep even malformed connection URLs and subprocess errors out of logs.
        print("Web-only migration verification failed; no migration was executed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
