#!/usr/bin/env python3
# tools/diagnostics/apple_shortcuts_probe/run_diagnostic.py
"""Cold structured Shortcuts event observation, without running any shortcut."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

import run_probe as probe

CONTRACT = "macos-shortcuts-event-diagnostic"
TYPES = {
    "undefined",
    "null",
    "boolean",
    "string",
    "number",
    "integer",
    "object",
    "function",
    "symbol",
    "bigint",
    "unavailable",
}
TRACE = [
    ("checkpoint", 1),
    ("get_entered", 1),
    ("get_returned", 1),
    ("checkpoint", 2),
    ("checkpoint", 3),
    ("get_entered", 4),
    ("get_returned", 4),
    ("checkpoint", 4),
]


class MarkerReader:
    """Parse only bounded closed scalars from the physically settled capture."""

    def __init__(self):
        self.events = []
        self.available = False

    def __call__(self, raw, role):
        self.available = False
        self.events = []
        last = 0
        try:
            probe.require(role == "discovery" and type(raw) is bytes and len(raw) <= probe.LIMIT)
            lines = raw.decode("utf-8").splitlines(keepends=True)
            probe.require(len(lines) <= len(TRACE) + 1)
            failed = False
            position = 0
            for line in lines:
                probe.require(line.endswith("\n") and "\r" not in line and not failed)
                if line.startswith("ASCP:"):
                    probe.require(line in {f"ASCP:{n}\n" for n in range(1, 5)})
                    item = ("checkpoint", int(line[5:-1]))
                    probe.require(position < len(TRACE) and TRACE[position] == item)
                    last = item[1]
                    position += 1
                    continue
                probe.require(line.startswith("ASCD:") and len(line.encode("utf-8")) <= 256)
                item = json.loads(line[5:], object_pairs_hook=probe.unique_object)
                probe.require(
                    type(item) is dict
                    and set(item)
                    == {"phase", "stage", "error_type", "error_available", "error_number"}
                )
                probe.require(
                    type(item["phase"]) is str
                    and item["phase"] in {"get_entered", "get_returned", "get_failed"}
                )
                probe.require(type(item["stage"]) is int and 1 <= item["stage"] <= 5)
                probe.require(type(item["error_type"]) is str and item["error_type"] in TYPES)
                probe.require(
                    type(item["error_available"]) is bool and type(item["error_number"]) is int
                )
                probe.require(-2147483648 <= item["error_number"] <= 2147483647)
                probe.require(item["error_available"] == (item["error_type"] == "integer"))
                probe.require(item["error_available"] or item["error_number"] == 0)
                if item["phase"] == "get_failed":
                    probe.require(
                        item["stage"] in ({0: {1}, 1: {1}, 2: {2, 3, 4}, 3: {4}, 4: {5}}[last])
                    )
                    failed = True
                else:
                    probe.require(item["error_type"] == "undefined" and not item["error_available"])
                    probe.require(
                        position < len(TRACE) and TRACE[position] == (item["phase"], item["stage"])
                    )
                    position += 1
                self.events.append(item)
            self.available = bool(self.events)
            return {"valid": True, "last": last}
        except Exception:
            self.events = []
            return {"valid": False, "last": 0}


def observe(root, ownership, deadline, evidence, reader):
    """Use the original process owner, capture and exact inventory validator."""
    remaining_ms = int((deadline - time.monotonic()) * 1000)
    probe.require(0 < remaining_ms <= 20000)
    script = root / "tools/diagnostics/apple_shortcuts_probe/discover_diagnostic.js"
    raw = probe.capture(
        ["/usr/bin/osascript", "-l", "JavaScript", str(script), str(remaining_ms)],
        ownership.NativeProcessGroups(),
        ownership,
        evidence,
        "discovery",
        deadline=deadline,
        marker_reader=reader,
    )
    return probe.validate(raw)


def main():
    deadline = time.monotonic() + 20
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    probe.require(sys.platform == "darwin" and sys.version_info >= (3, 13))
    probe.require(re.fullmatch("[0-9a-f]{40}", args.source_sha) is not None)
    root = args.source_root.resolve()
    folder = root / "tools/diagnostics/apple_shortcuts_probe"
    owner_path = root / "tools/diagnostics/macos_owned_process.py"
    paths = (
        owner_path,
        folder / "run_probe.py",
        folder / "discover.js",
        folder / "discover_diagnostic.js",
        folder / "run_diagnostic.py",
    )
    hashes = {}
    for path in paths:
        raw = path.read_bytes()
        relative = path.relative_to(root).as_posix()
        probe.require(
            subprocess.check_output(["git", "show", args.source_sha + ":" + relative], cwd=root)
            == raw
        )
        hashes[relative] = hashlib.sha256(raw).hexdigest()
    probe.require(args.output.parent.resolve() == args.output.parent.absolute())
    args.output.mkdir(mode=0o700, exist_ok=False)
    spec = importlib.util.spec_from_file_location("native_shortcuts_owner", owner_path)
    ownership = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ownership)
    probe.require(Path(probe.__file__).resolve() == (folder / "run_probe.py").resolve())

    def interrupted(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("probe_interrupted")

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    reader = MarkerReader()
    evidence = []
    result = {
        "schema": 1,
        "contract": CONTRACT,
        "source_sha": args.source_sha,
        "source_hashes": hashes,
        "feature_qualified": False,
        "invocation_qualified": False,
        "automation_cancellation_qualified": False,
        "permission": "not_determined",
        "physical_operations": evidence,
        "reason": "probe_refused",
    }
    failure = True
    primary = None
    try:
        inventory = observe(root, ownership, deadline, evidence, reader)
        result["inventory"] = inventory
        probe.require(reader.available and time.monotonic() < deadline)
        for path in paths:
            probe.require(
                hashlib.sha256(path.read_bytes()).hexdigest()
                == hashes[path.relative_to(root).as_posix()]
            )
        probe.require(time.monotonic() < deadline)
        failure = not inventory["observed"]
        result["reason"] = "none" if not failure else inventory["reason"]
    except BaseException as error:
        primary = error
        failure = True
        if probe.observation_interrupted(error, ownership):
            raise
    finally:
        result["event_diagnostic"] = {"available": reader.available, "events": reader.events}
        try:
            (args.output / "observation.json").write_text(
                json.dumps(result, sort_keys=True) + "\n", encoding="utf-8"
            )
            print(json.dumps(result, sort_keys=True))
        except BaseException as error:
            result["publication_health"] = "unavailable"
            if probe.observation_interrupted(error, ownership):
                raise
            if primary is None:
                raise probe.ProbeObservationRefused("diagnostic_publication") from None
            # Optional publication cannot replace the original cancellation/refusal.
    return 1 if failure else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        # No exception text, path, catalogue field or permission claim is exported.
        print(
            json.dumps(
                {"contract": CONTRACT, "feature_qualified": False, "reason": "probe_refused"}
            )
        )
        raise SystemExit(1)
