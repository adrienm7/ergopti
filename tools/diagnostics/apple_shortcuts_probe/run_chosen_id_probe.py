#!/usr/bin/env python3
# tools/diagnostics/apple_shortcuts_probe/run_chosen_id_probe.py
"""Hosted chosen-ID ABI observer; executes only an explicitly imported safe fixture."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import signal
import subprocess
import sys

from chosen_id_backend import NativeShortcuts, Refused, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture-id")
    parser.add_argument("--expected-output", type=Path)
    args = parser.parse_args()
    require(sys.platform == "darwin" and sys.version_info >= (3, 13), "native_unavailable")
    require(re.fullmatch("[0-9a-f]{40}", args.source_sha) is not None, "source_refused")
    require((args.fixture_id is None) == (args.expected_output is None), "fixture_refused")
    root = args.source_root.resolve()
    sources = [
        Path(__file__).resolve(),
        Path(__file__).with_name("chosen_id_backend.py").resolve(),
        root / "tools/diagnostics/macos_owned_process.py",
        root / "static/ergopti_plus/macos/adapters/apple_shortcuts.lua",
        root / "static/ergopti_plus/macos/adapters/apple_shortcuts_query.js",
    ]
    hashes = {}
    for path in sources:
        relative = str(path.relative_to(root))
        raw = path.read_bytes()
        require(
            subprocess.check_output(["git", "show", args.source_sha + ":" + relative], cwd=root)
            == raw,
            "source_refused",
        )
        hashes[relative] = hashlib.sha256(raw).hexdigest()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    backend = None
    result = {
        "schema": 1,
        "contract": "macos-chosen-shortcut-id",
        "source_sha": args.source_sha,
        "source_hashes": hashes,
        "native_query_observed": False,
        "chosen_id_revalidated": False,
        "fixture_invocation_observed": False,
        "automation_retirement_qualified": False,
        "native_catalogue_internal_allocation_bounded": False,
        "local_retired": False,
        "result": "REFUSED",
        "reason": "native_unavailable",
        "operations": [],
    }

    def interrupted(_sig, _frame):
        raise Refused("interrupted")

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    exit_code = 1
    try:
        backend = NativeShortcuts(root)
        result["inventory"] = backend.inventory()
        discovered = backend.discover()
        result["native_query_observed"] = True
        result["observed_choices"] = len(discovered["choices"])
        result["truncated"] = discovered["truncated"]
        # Empty inventory qualifies only that native observation. An arbitrary
        # discovered user workflow is never substituted for the safe fixture.
        require(args.fixture_id is not None, "safe_fixture_unavailable")
        keys = [key for key, (row, _) in backend.choices.items() if row["id"] == args.fixture_id]
        require(len(keys) == 1, "safe_fixture_missing")
        scalar = backend.resolve(keys[0])
        require(scalar["arguments"] == ["run", args.fixture_id], "chosen_id_refused")
        result["chosen_id_revalidated"] = True
        expected = args.expected_output.read_bytes()
        require(0 < len(expected) <= 65536, "fixture_refused")
        invoked = backend.invoke(keys[0], lambda: True, expected)
        result["fixture_invocation_observed"] = invoked["fixture_output_verified"]
        # The explicit fixture effect proves invocation, but public CLI/group
        # exit still cannot qualify cancellation of the Shortcuts service.
        result["result"] = "PARTIAL"
        result["reason"] = "service_retirement_unqualified"
        exit_code = 2
    except Refused as error:
        result["reason"] = str(error)
    except Exception:
        result["reason"] = "native_refused"
    finally:
        if backend is not None:
            try:
                result["local_retired"] = backend.cancel()["local_retired"]
            except Exception:
                result["local_retired"] = False
                result["reason"] = "cleanup_pending"
            result["operations"] = backend.receipts + [group.receipt() for group in backend.pending]
        for path in sources:
            if hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(root))]:
                result["result"], result["reason"], exit_code = "REFUSED", "source_changed", 1
        (args.output / "observation.json").write_text(json.dumps(result, sort_keys=True) + "\n")
        print(json.dumps(result, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Refused as error:
        print(
            json.dumps(
                {"contract": "macos-chosen-shortcut-id", "result": "REFUSED", "reason": str(error)}
            )
        )
        raise SystemExit(1)
