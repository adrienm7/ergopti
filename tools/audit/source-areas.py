#!/usr/bin/env python3
# tools/audit/source-areas.py
"""Enumerate tracked runtime source areas at one immutable Git commit.

This is navigation data, not proof of inspected code, available features or a
complete audit. Git blob identities describe the selected commit, independently
of dirty working files. Vendor/generated flags are lexical path indicators;
they do not establish authorship or generator provenance. Check mode compares
parsed JSON values (including their types) and requires UTF-8/LF, so repository
JSON formatting and object-key order do not invalidate the census.
"""

import argparse
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys


ROOTS = tuple(f"static/ergopti_plus/{name}" for name in ("windows", "macos", "linux", "_shared"))
CODE_SUFFIXES = frozenset(
    ".ahk .applescript .c .cpp .cs .css .go .h .hpp .html .js .lua .m .mm .ps1 .py .sh .sql .swift".split()
)
DECLARATION_SUFFIXES = frozenset(
    ".conf .def .entitlements .json .keylayout .lock .mod .plist .resolved .rules .service .toml .xml".split()
)
EXCLUDED_COMPONENTS = frozenset(
    ("test", "tests", "__pycache__", "node_modules", ".cache", ".build", "build", "dist", "target")
)
GROUPED_COMPONENTS = frozenset(("modules", "ui", "native", "lua", "python", "go"))


def git(root, *arguments):
    """Read Git data without interpreting revision names as shell text."""
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def census(root, ref):
    """Build the complete member census for the explicitly declared selection."""
    sha = git(root, "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}")
    sha = sha.decode("ascii").strip()
    entries = git(root, "ls-tree", "-r", "-z", "--full-tree", sha, "--", *ROOTS)
    groups = {}
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        header, raw_path = entry.split(b"\t", 1)
        mode, object_type, blob = header.decode("ascii").split()
        if object_type != "blob":
            continue
        name = raw_path.decode("utf-8")
        parts = PurePosixPath(name).parts
        relative = parts[3:]
        if EXCLUDED_COMPONENTS.intersection(part.lower() for part in relative[:-1]) or any(
            part.endswith(".dSYM") for part in relative
        ):
            continue
        filename = relative[-1]
        if filename.endswith("_test.go"):
            continue
        suffix = PurePosixPath(filename).suffix.lower()
        if suffix in CODE_SUFFIXES:
            kind = "code"
        elif suffix in DECLARATION_SUFFIXES:
            kind = "declaration"
        elif (
            not suffix
            and mode == "100755"
            and git(root, "cat-file", "blob", blob).startswith(b"#!")
        ):
            kind = "code"
        else:
            continue
        os_name = "shared" if parts[2] == "_shared" else parts[2]
        area = "/".join(relative[:2]) if relative[0] in GROUPED_COMPONENTS else relative[0]
        vendor = "vendor" in relative[:-1]
        generated = bool({"_generated", "generated"}.intersection(relative[:-1])) or (
            ".generated." in filename.lower()
        )
        group = groups.setdefault(
            (os_name, area),
            {
                "os": os_name,
                "area": area,
                "code_files": 0,
                "declaration_files": 0,
                "vendor_path_files": 0,
                "generated_path_files": 0,
                "members": [],
            },
        )
        group[f"{kind}_files"] += 1
        group["vendor_path_files"] += int(vendor)
        group["generated_path_files"] += int(generated)
        group["members"].append(
            {
                "path": name,
                "git_blob": blob,
                "git_mode": mode,
                "kind": kind,
                "vendor_path": vendor,
                "generated_path": generated,
            }
        )
    areas = []
    for key in sorted(groups):
        group = groups[key]
        group["members"].sort(key=lambda member: member["path"])
        areas.append(group)
    return {
        "schema_version": 1,
        "audited_sha": sha,
        "meaning": (
            "Tracked source/declaration navigation for the stated roots, suffixes and exclusions. "
            "Not feature availability, inspected coverage or complete audit proof. Vendor/generated "
            "flags indicate paths only; git_blob uses this repository's Git object format."
        ),
        "roots": list(ROOTS),
        "code_suffixes": sorted(CODE_SUFFIXES),
        "declaration_suffixes": sorted(DECLARATION_SUFFIXES),
        "extensionless_code": "executable Git blob beginning with #!",
        "excluded_components": sorted(EXCLUDED_COMPONENTS),
        "exclusion_matching": (
            "Directory components compare case-insensitively. Test-named files outside excluded "
            "directories remain unless explicitly listed: test_prediction.lua is a runtime feature."
        ),
        "excluded_patterns": ["*_test.go", "*.dSYM/**"],
        "areas": areas,
    }


def main():
    """Write deterministic data or verify semantic JSON equality and UTF-8/LF."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--ref", default="HEAD", help="Commit or revision to enumerate (default HEAD)."
    )
    parser.add_argument("--output", type=Path, help="JSON destination; omit to write stdout.")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check parsed JSON values and UTF-8/LF without writing.",
    )
    options = parser.parse_args()
    if options.check and options.output is None:
        parser.error("--check requires --output")
    try:
        document = census(options.source_root, options.ref)
        encoded = (json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        if options.check:
            existing = options.output.read_bytes()
            if b"\r" in existing or not existing.endswith(b"\n"):
                raise ValueError("output must use LF and end with a newline")
            parsed = json.loads(existing.decode("utf-8"))
            if json.dumps(parsed, sort_keys=True) != json.dumps(document, sort_keys=True):
                print(
                    "source-areas: output differs from the selected commit census", file=sys.stderr
                )
                return 1
            count = sum(len(area["members"]) for area in document["areas"])
            print(f"source-areas: OK {count} members at {document['audited_sha']}")
        elif options.output:
            options.output.write_bytes(encoded)
        else:
            sys.stdout.buffer.write(encoded)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"source-areas: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
