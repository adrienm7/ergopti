#!/usr/bin/env python3
"""Read-only checksum and optional repository-preimage verification. Never apply."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys


def safe_path(root, relative):
    part = PurePosixPath(relative)
    if not relative or part.is_absolute() or ".." in part.parts or "\\" in relative:
        raise ValueError("unsafe relative path: " + relative)
    result = root.joinpath(*part.parts)
    cursor = result
    while cursor != root:
        if cursor.is_symlink():
            raise ValueError("symlink refused: " + relative)
        cursor = cursor.parent
    if not result.resolve().is_relative_to(root.resolve()):
        raise ValueError("path escapes root: " + relative)
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository",
        type=Path,
        help="optional checkout whose exact preimages are compared; no edits",
    )
    parser.add_argument(
        "--packet",
        action="append",
        default=[],
        help="limit optional preimage comparisons to this packet; repeatable",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    errors = []
    try:
        manifest = json.loads(safe_path(root, "manifest.json").read_text(encoding="utf-8"))
        if manifest.get("schema_version") != 1:
            raise ValueError("unsupported bundle manifest schema")
        packets = manifest["packets"]
        unknown = set(args.packet) - set(packets)
        if unknown:
            raise ValueError("unknown packet(s): " + ", ".join(sorted(unknown)))
        declared = set()
        immutable = {
            "candidate",
            "preimage",
            "causal-preimage",
            "reviewed-preimage",
            "independent-control",
            "staging-script",
            "patch",
            "registration",
        }
        for entry in manifest["files"]:
            name = entry["path"]
            if name in declared:
                errors.append("duplicate manifest path: " + name)
                continue
            declared.add(name)
            path = safe_path(root, name)
            if not path.is_file():
                errors.append("missing file: " + name)
                continue
            data = path.read_bytes()
            if len(data) != entry["bytes"] or digest(data) != entry["sha256"]:
                errors.append("bytes/checksum mismatch: " + name)
            if entry["role"] in immutable and (
                entry.get("metadata_rewritten") or entry["sha256"] != entry["original_sha256"]
            ):
                errors.append("source/patch/registration differs from frozen input: " + name)
            if entry.get("target", "").endswith(".ahk") and entry["role"] in immutable:
                if not data.startswith(b"\xef\xbb\xbf"):
                    errors.append("AHK source lacks UTF-8 BOM: " + name)
                if b"\r" in data:
                    errors.append("AHK source contains non-LF line endings: " + name)
            if entry["role"] in {"metadata", "documentation"} and (b"/" + b"workspace/") in data:
                errors.append("nonportable metadata reference: " + name)
        actual = set()
        for path in root.rglob("*"):
            if path.is_symlink():
                errors.append("bundle symlink refused: " + path.relative_to(root).as_posix())
            elif path.is_file():
                actual.add(path.relative_to(root).as_posix())
        extras = actual - declared - {"manifest.json", "SHA256SUMS"}
        if extras:
            errors.extend("undeclared file: " + name for name in sorted(extras))
        checksums = safe_path(root, "SHA256SUMS")
        if checksums.is_file():
            listed = set()
            for line in checksums.read_text(encoding="utf-8").splitlines():
                expected, name = line.split("  ", 1)
                if name in listed:
                    errors.append("duplicate checksum index path: " + name)
                listed.add(name)
                path = safe_path(root, name)
                if not path.is_file() or digest(path.read_bytes()) != expected:
                    errors.append("checksum index mismatch: " + name)
            if listed != actual - {"SHA256SUMS"}:
                errors.append("checksum index does not cover exact bundle inventory")
        else:
            errors.append("missing checksum index")
        compared = 0
        if args.repository:
            repository = args.repository.resolve(strict=True)
            if not repository.is_dir():
                raise ValueError("repository must be an existing directory")
            selected = set(args.packet)
            for entry in manifest["preimages"]:
                if selected and entry["packet"] not in selected:
                    continue
                name = entry["target"]
                path = safe_path(repository, name)
                compared += 1
                label = entry["packet"] + ": " + name
                if entry["absent"]:
                    if path.exists():
                        errors.append("expected absent preimage: " + label)
                elif not path.is_file() or digest(path.read_bytes()) != entry["sha256"]:
                    errors.append("preimage mismatch (" + entry["comparison_scope"] + "): " + label)
        elif args.packet:
            raise ValueError("--packet requires --repository; every bundle byte is always checked")
        if errors:
            for error in errors:
                print("FAIL " + error, file=sys.stderr)
            print(f"{len(errors)} verification failure(s); no files changed.", file=sys.stderr)
            return 1
        print(
            f"PASS {len(declared)} preserved files; {compared} repository preimages compared; no files changed."
        )
        if not args.repository:
            print("Repository drift, application order and native behavior were not tested.")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("FAIL " + str(error) + "; no files changed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
