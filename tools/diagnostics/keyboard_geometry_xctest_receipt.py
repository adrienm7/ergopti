"""Close one selected XCTest receipt without weakening the complete-suite owner."""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def evaluate(source, log, classname, test_exit, capture_exit):
    """Require every exact source-registered method and its native terminal row."""
    expected = re.findall(r"\bfunc (test\w+)\(\)", source)
    if not expected or len(expected) != len(set(expected)):
        raise ValueError("invalid expected method inventory")
    started = []
    received = []
    failures = []
    suites_started = 0
    suites_passed = 0
    for line in log.replace("\r\n", "\n").splitlines():
        if re.match(r"^Test Suite 'Selected tests' started at ", line):
            suites_started += 1
        if re.match(r"^Test Suite 'Selected tests' passed at ", line):
            suites_passed += 1
        row = re.match(r"^Test Case '(.+)' (started\.|passed \(|failed \(|skipped \()", line)
        if not row:
            continue
        identity = row.group(1)
        name = re.fullmatch(r"(?:\w+\.)?" + re.escape(classname) + r"\.(test\w+)", identity)
        if name is None:
            name = re.fullmatch(r"-\[(?:\w+\.)?" + re.escape(classname) + r" (test\w+)\]", identity)
        if name is None:
            raise ValueError("foreign XCTest class")
        method = name.group(1)
        if row.group(2) == "started.":
            started.append(method)
        else:
            received.append(method)
            if row.group(2) != "passed (":
                failures.append(method)
    complete = (
        sorted(started) == sorted(expected)
        and sorted(received) == sorted(expected)
        and not failures
        and suites_started == 1
        and suites_passed == 1
    )
    observation = None
    if "testActualNativeCarbonCanonicalAndOlderModels" in expected:
        values = re.findall(
            r"^KEYBOARD_GEOMETRY_OBSERVATION ranges=(\d+) env_bytes=(\d+) "
            r"elapsed_ns=(\d+) arg_max=(\d+) physical_qualified=false$",
            log.replace("\r\n", "\n"),
            re.MULTILINE,
        )
        if len(values) != 1:
            complete = False
        else:
            ranges, size, elapsed, limit = map(int, values[0])
            if not (1 <= ranges <= 32768 and 0 < size < limit and elapsed <= 2**64 - 1):
                complete = False
            else:
                observation = {
                    "range_count": ranges,
                    "environment_bytes": size,
                    "elapsed_ns": elapsed,
                    "argument_limit": limit,
                }
    return {
        "schema": 1,
        "scope": classname,
        "source_sha": hashlib.sha256(source.encode("utf-8")).hexdigest(),
        "expected_count": len(expected),
        "received_count": len(received),
        "failures": failures,
        "test_exit": test_exit,
        "capture_exit": capture_exit,
        "complete": complete,
        "passed": complete and test_exit == 0 and capture_exit == 0,
        "native_map_observation": observation,
        "physical_keyboard_qualified": False,
        "application_launch_qualified": False,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--class", dest="classname", required=True)
    for name in ("source", "log", "receipt"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--test-exit", type=int, required=True)
    parser.add_argument("--capture-exit", type=int, required=True)
    args = parser.parse_args()
    try:
        result = evaluate(
            args.source.read_text(encoding="utf-8"),
            args.log.read_text(encoding="utf-8"),
            args.classname,
            args.test_exit,
            args.capture_exit,
        )
    except (OSError, UnicodeError, ValueError):
        result = {
            "schema": 1,
            "scope": args.classname,
            "passed": False,
            "complete": False,
            "reason": "selected_receipt_unavailable",
            "test_exit": args.test_exit,
            "capture_exit": args.capture_exit,
            "physical_keyboard_qualified": False,
            "application_launch_qualified": False,
        }
    if args.log.is_file():
        data = args.log.read_bytes()
        result["log_bytes"] = len(data)
        result["log_sha256"] = hashlib.sha256(data).hexdigest()
    with args.receipt.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, sort_keys=True)
        stream.write("\n")
    return 0 if result["passed"] else (args.test_exit or args.capture_exit or 1)


if __name__ == "__main__":
    sys.exit(main())
