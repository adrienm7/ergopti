# docs/handovers/2026-10-04-parallel-containers/group3-2026-10-06-modifier-consumer-inventory/verify_selection.py

"""Verify inert consumer-inventory inputs without executing their controls."""

import argparse
import hashlib
import json
from pathlib import Path


EXPECTED_NAMES = {
    "README.md",
    "controls.lua",
    "evidence-pins.json",
    "facts.json",
    "receipt.json",
    "replay.py",
    "results.json",
    "run.lua",
    "source-pins.json",
    "independent-review/review.json",
    "independent-review/review-receipt.json",
}
EXPECTED_OUTCOMES = {
    "current": {"passed": 17, "failed": 8},
    "skip_only_up": {"passed": 19, "failed": 6},
    "weaken_baseline": {"passed": 16, "failed": 9},
    "legacy_tap_hold": {"passed": 26, "failed": 0},
    "forbid_reentrant_retirement": {"passed": 25, "failed": 1},
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="manifest.json", type=Path)
    args = parser.parse_args()
    root = args.manifest.resolve().parent
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    errors = []
    names = [row["original_name"] for row in manifest["files"]]
    if set(names) != EXPECTED_NAMES or len(names) != len(EXPECTED_NAMES):
        errors.append("Inventory must contain the exact nine inputs and two review receipts")
    for row in manifest["files"]:
        relative = Path(row["portable_path"])
        if relative.is_absolute() or ".." in relative.parts:
            errors.append("Unsafe portable artifact path")
            continue
        path = root / relative
        if not relative.as_posix().endswith(".txt"):
            errors.append("Artifact has an active extension")
            continue
        if any(
            root.joinpath(*relative.parts[:index]).is_symlink()
            for index in range(1, len(relative.parts) + 1)
        ):
            errors.append("Artifact or ancestor is a symlink")
            continue
        if not path.is_file():
            errors.append("Artifact is missing or nonregular")
            continue
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != row["sha256"] or len(data) != row["bytes"]:
            errors.append("Immutable artifact bytes changed")
        if b"\r\n" in data:
            errors.append("Immutable text has CRLF")
    if (
        manifest["physical_delivery_available"] is not False
        or manifest["production_source_fix"] is not False
    ):
        errors.append("Regression inventory must not claim availability or a repair")
    if manifest["native_kernel_execution"] != "NOT_RUN":
        errors.append("Regression inventory must preserve unexecuted kernel status")
    if manifest["recorded_both_abi_outcomes"] != EXPECTED_OUTCOMES:
        errors.append("Recorded red and positive outcomes differ")
    print(
        json.dumps(
            {"status": "PORTABLE_BYTE_CHECK_ONLY", "files": len(names), "errors": errors}, indent=2
        )
    )
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
