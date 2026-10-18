"""Run only the owned input-source/localization methods in fresh native processes."""

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

from keyboard_geometry_xctest_receipt import evaluate

COHORTS = (
    ("NativeInputSourceSelectionTests", 4),
    ("InputSourceSelectionWorkerTests", 7),
    ("InputSourceUpgradeWorkerTests", 8),
    ("EmbeddedFatalReportTests", 11),
)
LOCALIZATION_METHODS = (
    "testCatalogInterpolationPreservesLiteralPlaceholdersInArguments",
    "testLocalizedRuntimeAlertPreservesPlaceholderTextInItsComponent",
)


def inventory(evidence):
    """Extract real declarations, retaining the independently closed full census."""
    selected = []
    for classname, count in COHORTS:
        source = (evidence / (classname + ".swift")).read_text(encoding="utf-8")
        methods = re.findall(r"\bfunc (test\w+)\(\)", source)
        if len(methods) != count or len(set(methods)) != count:
            raise ValueError("owned source census changed")
        chosen = LOCALIZATION_METHODS if classname == "EmbeddedFatalReportTests" else methods
        for method in chosen:
            if methods.count(method) != 1:
                raise ValueError("owned method unavailable")
            selected.append((classname, method, source))
    return selected


def selected_receipt(source, log, classname, method, test_exit, capture_exit):
    """The one declaration is selection metadata; it never replaces native test code."""
    if re.findall(r"\bfunc (test\w+)\(\)", source).count(method) != 1:
        raise ValueError("selected method unavailable")
    result = evaluate(f"func {method}() {{}}\n", log, classname, test_exit, capture_exit)
    # Keep the real full-file identity distinct from the evaluator's metadata hash.
    result["selected_method"] = method
    result["selection_metadata_sha"] = result.pop("source_sha")
    result["source_sha"] = hashlib.sha256(source.encode("utf-8")).hexdigest()
    return result


class NativeChildRetirementError(Exception):
    def __init__(self, native_exit, retired):
        self.native_exit = native_exit
        self.retired = retired
        super().__init__("unexpected native process descendants")


def group_alive(identifier):
    try:
        os.killpg(identifier, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return True


def retire_group(identifier):
    for requested_signal in (signal.SIGTERM, signal.SIGKILL):
        if not group_alive(identifier):
            return True
        try:
            os.killpg(identifier, requested_signal)
        except ProcessLookupError:
            return True
        except OSError:
            return False
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            if not group_alive(identifier):
                return True
            time.sleep(0.01)
    return not group_alive(identifier)


def run_child(arguments, transcript):
    """Refuse residual descendants even when the exact Swift parent exits zero."""
    with transcript.open("xb") as output:
        try:
            process = subprocess.Popen(
                arguments, stdout=output, stderr=subprocess.STDOUT, start_new_session=True
            )
        except OSError:
            return 127, 0
        try:
            native_exit = process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            for requested_signal in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, requested_signal)
                except ProcessLookupError:
                    pass
                except OSError:
                    raise NativeChildRetirementError(124, False) from None
                try:
                    process.wait(timeout=5)
                    break
                except subprocess.TimeoutExpired:
                    if requested_signal == signal.SIGKILL:
                        raise NativeChildRetirementError(124, False) from None
            if not retire_group(process.pid):
                raise NativeChildRetirementError(124, False)
            return 124, 0
        if group_alive(process.pid):
            raise NativeChildRetirementError(native_exit, retire_group(process.pid))
        return native_exit, 0


def run(evidence, package_path, scratch_path, phase):
    retirement_marker = evidence / "isolation-retirement-refused.json"
    if retirement_marker.exists():
        return 75
    cases = inventory(evidence)
    if phase == "reverse":
        cases.reverse()
    destination = evidence / ("isolated-" + phase)
    destination.mkdir()
    results = []
    retirement_refused = False
    for index, (classname, method, source) in enumerate(cases):
        stem = f"{index + 1:02d}-{classname}.{method}"
        transcript = destination / (stem + ".log")
        command = [
            "swift",
            "test",
            "--package-path",
            str(package_path),
            "--scratch-path",
            str(scratch_path),
            "--filter",
            rf"(^|[.]){classname}[/.]{method}$",
        ]
        try:
            test_exit, capture_exit = run_child(command, transcript)
            result = selected_receipt(
                source,
                transcript.read_text(encoding="utf-8"),
                classname,
                method,
                test_exit,
                capture_exit,
            )
        except NativeChildRetirementError as error:
            retirement_refused = not error.retired
            result = {
                "scope": classname,
                "selected_method": method,
                "passed": False,
                "test_exit": error.native_exit,
                "capture_exit": 0,
                "reason": "unexpected_native_descendants",
                "retirement_confirmed": error.retired,
            }
        except (UnicodeError, ValueError):
            result = {
                "scope": classname,
                "selected_method": method,
                "passed": False,
                "test_exit": test_exit,
                "capture_exit": capture_exit,
            }
        result["phase"] = phase
        result["source_sha"] = hashlib.sha256(source.encode("utf-8")).hexdigest()
        data = transcript.read_bytes()
        result["log_bytes"] = len(data)
        result["log_sha256"] = hashlib.sha256(data).hexdigest()
        with (destination / (stem + ".json")).open("x", encoding="utf-8") as receipt:
            json.dump(result, receipt, sort_keys=True)
            receipt.write("\n")
        results.append(result)
        print(f"{phase} {classname}.{method} passed={result['passed']}", flush=True)
        if retirement_refused:
            retirement_marker.write_text(json.dumps(result) + "\n", encoding="utf-8")
            break
    passed = len(results) == 21 and all(row["passed"] for row in results)
    summary = {
        "phase": phase,
        "expected_count": 21,
        "received_count": len(results),
        "passed": passed,
        "order": [row["scope"] + "." + row["selected_method"] for row in results],
    }
    with (destination / "summary.json").open("x", encoding="utf-8") as receipt:
        json.dump(summary, receipt, sort_keys=True)
        receipt.write("\n")
    return 75 if retirement_refused else (0 if passed else 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--package-path", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--phase", choices=("forward", "reverse"), required=True)
    args = parser.parse_args()
    try:
        return run(args.evidence, args.package_path, args.scratch_path, args.phase)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 1


if __name__ == "__main__":
    sys.exit(main())
