"""Verify retained repository-file hash claims against pinned and current bytes.

Only explicit path/sha256 source entries and source-inventory/source-hashes maps
are interpreted. Log receipts, artifact freezes and upstream URL hashes have
different owners and are not reinterpreted as repository source claims.
"""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import subprocess

DIRECTORY = Path(__file__).resolve().parent
CAMPAIGN = DIRECTORY.parent
ROOT = CAMPAIGN.parents[3]
AUDITED_SHA = "7aecd9a25b35efdcff68898919506dc2f6fd02d0"
MODULES = ("wpm", "wrap-symbols", "personal-info")
ROLES = ("windows", "macos", "linux", "shared")


def digest(raw):
    """Hash exact bytes, retaining BOM and newline distinctions."""
    return hashlib.sha256(raw).hexdigest()


def require(condition, message):
    """Reject malformed claims without relying on optimization-sensitive asserts."""
    if not condition:
        raise ValueError(message)


def claims_in(path):
    """Read the explicit source-claim shapes retained by the audit roles."""
    data = json.loads(path.read_text(encoding="utf-8"))
    is_inventory = path.name == "source-hashes.json" or path.name.startswith("source-inventory-")
    if is_inventory:
        require(isinstance(data, dict), f"Unsupported inventory shape: {path}")
        return [(key, value, "/" + key) for key, value in data.items()]
    claims = []

    def walk(value, pointer=""):
        if isinstance(value, dict):
            if (
                "sha256" in value
                and isinstance(value.get("path"), str)
                and value["path"].startswith("static/")
            ):
                claims.append((value["path"], value["sha256"], pointer))
            for key, child in value.items():
                walk(child, pointer + "/" + str(key))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, pointer + "/" + str(index))

    walk(data)
    return claims


def scan():
    """Compare all twelve scope inventories without altering their snapshots."""
    grouped = defaultdict(list)
    scopes = []
    for module in MODULES:
        for role in ROLES:
            scope = CAMPAIGN / module / role
            require((scope / "coverage.json").is_file(), f"Missing scope coverage: {module}/{role}")
            count = 0
            for owner in sorted(scope.rglob("*.json")):
                for path, claimed, pointer in claims_in(owner):
                    relative = Path(path)
                    require(
                        not relative.is_absolute()
                        and ".." not in relative.parts
                        and relative.as_posix() == path
                        and "\\" not in path
                        and ":" not in path,
                        f"Noncanonical source path: {path}",
                    )
                    require(
                        isinstance(claimed, str) and re.fullmatch(r"[0-9a-f]{64}", claimed),
                        f"Unsupported SHA256 claim: {owner}: {pointer}",
                    )
                    grouped[path].append(
                        {
                            "artifact": owner.relative_to(CAMPAIGN).as_posix(),
                            "pointer": pointer,
                            "sha256": claimed,
                        }
                    )
                    count += 1
            scopes.append({"scope": module + "/" + role, "claim_count": count})
    require(grouped, "No repository hash claims found")
    rows = []
    failures = []
    for path, origins in sorted(grouped.items()):
        production = path.startswith("static/")
        documentation = path == "TODO.md" or path.startswith("docs/")
        result = subprocess.run(
            ["git", "show", AUDITED_SHA + ":" + path], cwd=ROOT, capture_output=True, check=True
        )
        pinned = digest(result.stdout)
        current_path = ROOT / path
        current = digest(current_path.read_bytes()) if current_path.is_file() else None
        require(
            current_path.resolve().is_relative_to(ROOT.resolve()),
            f"Escaped current source path: {path}",
        )
        claim_matches = all(origin["sha256"] == pinned for origin in origins)
        current_matches = current == pinned
        if not claim_matches:
            failures.append("claim differs from pinned bytes: " + path)
        if not current_matches and not documentation:
            failures.append("current production/source bytes differ: " + path)
        rows.append(
            {
                "path": path,
                "kind": "production"
                if production
                else "documentation"
                if documentation
                else "repository_source",
                "pinned_sha256": pinned,
                "current_sha256": current,
                "claim_count": len(origins),
                "claim_origins": [
                    {
                        key: value
                        for key, value in origin.items()
                        if key != "sha256" and not (key == "pointer" and value == "/" + path)
                    }
                    | ({"claimed_sha256": origin["sha256"]} if origin["sha256"] != pinned else {})
                    for origin in origins
                ],
                "claims_match_pinned": claim_matches,
                "current_matches_pinned": current_matches,
                "status": "mismatch"
                if not claim_matches or not current_matches and not documentation
                else "expected_documentation_drift"
                if not current_matches
                else "match",
            }
        )
    return {
        "schema_version": 1,
        "audited_sha": AUDITED_SHA,
        "scope_count": len(scopes),
        "claim_count": sum(scope["claim_count"] for scope in scopes),
        "unique_path_count": len(rows),
        "scopes": scopes,
        "paths": rows,
        "failures": failures,
        "boundary": "Exact retained repository-file hash claims only; no production behavior, native receiving or exhaustive source-coverage certification. Documentation drift is reported without changing audit snapshots.",
    }


def main():
    """Write the compact result, or replay all checks without changing artifacts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true", help="verify live bytes without writing the result snapshot"
    )
    options = parser.parse_args()
    report = scan()
    if not options.check:
        (DIRECTORY / "source-hashes.json").write_bytes(
            (json.dumps(report, indent=2) + "\n").encode("utf-8")
        )
    for row in report["paths"]:
        if row["status"] != "match":
            print(row["status"] + ": " + row["path"])
    require(not report["failures"], "; ".join(report["failures"]))
    print(
        f"PASS source hashes: {report['scope_count']} scopes, {report['claim_count']} claims, {report['unique_path_count']} unique paths; pinned claims and current production bytes match"
    )


if __name__ == "__main__":
    main()
