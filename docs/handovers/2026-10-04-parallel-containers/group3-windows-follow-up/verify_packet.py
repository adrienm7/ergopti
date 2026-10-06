#!/usr/bin/env python3
"""Verify inactive handoff bytes; this does not execute or qualify Windows code."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--producer",
        type=Path,
        help="Compare current shell_runner.ahk with the exact patch preimage",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    for entry in manifest["files"]:
        relative = Path(entry["path"])
        path = (root / relative).resolve()
        if relative.is_absolute() or not path.is_relative_to(root):
            raise ValueError("Manifest path escapes packet")
        raw = path.read_bytes()
        if len(raw) != entry["bytes"] or hashlib.sha256(raw).hexdigest() != entry["sha256"]:
            raise ValueError("Packet byte mismatch: " + entry["path"])
        raw.decode("utf-8-sig")
        if b"\r" in raw:
            raise ValueError("Packet text is not LF: " + entry["path"])
        if path.suffix == ".ahk" and not raw.startswith(b"\xef\xbb\xbf"):
            raise ValueError("AHK BOM missing: " + entry["path"])
    print("PASS: inactive packet integrity, UTF-8, LF and AHK BOM only")
    print("Native Windows execution: NOT RUN; patch and fixture: NOT INSTALLED")
    if args.producer:
        actual = hashlib.sha256(args.producer.read_bytes()).hexdigest()
        expected = manifest["producer_preimage_sha256"]
        if actual != expected:
            print(
                "REFUSED: current producer differs from exact preimage; forward-port and review, never overwrite it"
            )
            print("Expected " + expected + "; actual " + actual)
            return 2
        print("PASS: exact producer preimage bytes match (not native qualification)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
