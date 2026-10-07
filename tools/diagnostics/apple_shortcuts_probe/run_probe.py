#!/usr/bin/env python3
# tools/diagnostics/apple_shortcuts_probe/run_probe.py
"""Hosted read-only Shortcuts API observation; never executes a user automation."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

LIMIT = 65536
CONTRACT = "macos-shortcuts-discovery-probe"


def require(condition):
    if condition is not True:
        raise ValueError("probe_refused")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def retire(owners):
    old = {}
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            old[sig] = signal.signal(sig, signal.SIG_IGN)
        for group in owners:
            require(group.settle())
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


def capture(arguments, native, ownership, evidence, role):
    owners = []
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            group = ownership.acquire_owned(
                arguments, native, owners.append, stdout=out, stderr=err
            )
            deadline = time.monotonic() + 20
            while group.observe_exit() is None:
                require(time.monotonic() < deadline)
                require(
                    os.fstat(out.fileno()).st_size <= LIMIT
                    and os.fstat(err.fileno()).st_size <= LIMIT
                )
                time.sleep(0.02)
        finally:
            acknowledged = False
            try:
                retire(owners)
                acknowledged = True
            finally:
                evidence.append(
                    {
                        "role": role,
                        "registered": len(owners),
                        "retirement_ack": acknowledged,
                        "groups": [retained.receipt() for retained in owners],
                    }
                )
        require(group.process.returncode == 0)
        out.seek(0)
        err.seek(0)
        raw, errors = out.read(LIMIT + 1), err.read(LIMIT + 1)
        require(0 < len(raw) <= LIMIT and len(errors) == 0)
        return raw


def validate(raw):
    require(type(raw) is bytes and 0 < len(raw) <= LIMIT)
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    require(type(value) is dict and type(value.get("version")) is int and value["version"] == 1)
    if value.get("status") in ("refused", "stale"):
        require(set(value) == {"version", "status", "stage", "reason"})
        require(type(value["stage"]) is int and 1 <= value["stage"] <= 5)
        require(value["reason"] in ("native_refused", "automation_permission_refused"))
        return {
            "observed": False,
            "status": value["status"],
            "stage": value["stage"],
            "reason": value["reason"],
        }
    require(value.get("status") == "observed")
    require(set(value) == {"version", "status", "choices", "truncated"})
    require(
        type(value["choices"]) is list
        and len(value["choices"]) <= 64
        and type(value["truncated"]) is bool
    )
    identifiers = set()
    for row in value["choices"]:
        require(type(row) is dict and set(row) == {"id", "name", "accepts_input"})
        require(type(row["id"]) is str and 0 < len(row["id"].encode("utf-8")) <= 256)
        require(type(row["name"]) is str and len(row["name"].encode("utf-8")) <= 4096)
        require("\0" not in row["name"] and "\0" not in row["id"] and row["id"] not in identifiers)
        require(type(row["accepts_input"]) is bool)
        identifiers.add(row["id"])
    # Never emit or persist discovered identifiers/names, even hashed names.
    return {
        "observed": True,
        "observed_choices": len(value["choices"]),
        "truncated": value["truncated"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin" and sys.version_info >= (3, 13))
    require(re.fullmatch("[0-9a-f]{40}", args.source_sha) is not None)
    root = args.source_root.resolve()
    owner_path = root / "tools/diagnostics/macos_owned_process.py"
    script = Path(__file__).with_name("discover.js").resolve()
    source_files = (owner_path, Path(__file__).resolve(), script)
    hashes = {}
    for path in source_files:
        relative = str(path.relative_to(root))
        raw = path.read_bytes()
        require(
            subprocess.check_output(["git", "show", args.source_sha + ":" + relative], cwd=root)
            == raw
        )
        hashes[relative] = hashlib.sha256(raw).hexdigest()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("native_shortcuts_owner", owner_path)
    ownership = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ownership)

    def interrupted(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("probe_interrupted")

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    native = ownership.NativeProcessGroups()
    evidence = []
    result = {
        "schema": 1,
        "contract": CONTRACT,
        "source_sha": args.source_sha,
        "source_hashes": hashes,
        "discovery_observed": False,
        "invocation_qualified": False,
        "automation_cancellation_qualified": False,
        "native_catalogue_retrieval_bounded": False,
        "cli_identifier_help_observed": False,
        "physical_operations": evidence,
        "permission": "not_determined",
        "reason": "probe_refused",
    }
    failure = True
    try:
        for tool in ("/usr/bin/osascript", "/usr/bin/shortcuts"):
            info = os.stat(tool)
            require(stat.S_ISREG(info.st_mode) and bool(info.st_mode & 0o111))
        help_bytes = capture(
            ["/usr/bin/shortcuts", "run", "--help"], native, ownership, evidence, "cli_help"
        )
        require(b"shortcut-name-or-identifier" in help_bytes)
        result["cli_identifier_help_observed"] = True
        raw = capture(
            ["/usr/bin/osascript", "-l", "JavaScript", str(script)],
            native,
            ownership,
            evidence,
            "discovery",
        )
        observed = validate(raw)
        result["inventory"] = observed
        result["discovery_observed"] = observed["observed"]
        if observed["observed"]:
            result["reason"] = "none"
            failure = False
        else:
            result["reason"] = observed["reason"]
            if observed["reason"] == "automation_permission_refused":
                result["permission"] = "refusal_code_observed"
        for path in source_files:
            require(
                hashlib.sha256(path.read_bytes()).hexdigest() == hashes[str(path.relative_to(root))]
            )
    except Exception:
        failure = True
        result["discovery_observed"] = False
        result["reason"] = "probe_refused"
    finally:
        # Includes exact physical receipts on declined native API/start/timeout,
        # without including stdout, stderr, identifiers or discovered names.
        (args.output / "observation.json").write_text(json.dumps(result, sort_keys=True) + "\n")
        print(json.dumps(result, sort_keys=True))
    return 1 if failure else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        print(
            json.dumps(
                {
                    "contract": CONTRACT,
                    "discovery_observed": False,
                    "invocation_qualified": False,
                    "automation_cancellation_qualified": False,
                    "reason": "probe_refused",
                }
            )
        )
        raise SystemExit(1)
