"""Authenticate the dead-key composition campaign's named source claims against Git and disk."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

AUDITED_SHA = "f2c3ea43542c985fb20e5f0887976f1c02525341"
ROLE_RECEIPTS = tuple(
    (role, f"{role}/source-receipts.json", "audited_sha", "files")
    for role in ("windows", "macos", "linux", "shared")
)


def require(condition, message):
    """Reject malformed or drifted evidence independently of Python optimization."""
    if not condition:
        raise ValueError(message)


def relative_path(value):
    """Require a canonical repository-relative POSIX path with no traversal."""
    require(
        isinstance(value, str) and value and "\\" not in value and ":" not in value, "source path"
    )
    path = Path(value)
    require(
        not path.is_absolute()
        and ".." not in path.parts
        and "." not in path.parts
        and path.as_posix() == value,
        f"noncanonical source path: {value}",
    )
    return path


def regular_file(root, relative):
    """Resolve a regular file while refusing symlinks in its relative path."""
    path = root
    for part in relative_path(relative).parts:
        path = path / part
        require(not path.is_symlink(), f"symlink source or receipt: {relative}")
    require(path.is_file(), f"missing source or receipt: {relative}")
    return path


def claims(directory):
    """Read the four explicit role receipts without inferring transitive coverage."""
    result = []
    for role, receipt, pin_field, field in ROLE_RECEIPTS:
        document = json.loads(regular_file(directory, receipt).read_text(encoding="utf-8"))
        require(document.get(pin_field) == AUDITED_SHA, f"wrong source pin: {receipt}")
        entries = document.get(field)
        if isinstance(entries, dict):
            entries = [{"path": path, "sha256": digest} for path, digest in entries.items()]
        require(isinstance(entries, list) and entries, f"empty source receipt: {receipt}")
        seen = set()
        for entry in entries:
            require(isinstance(entry, dict), f"source claim shape: {receipt}")
            relative = entry.get("path")
            relative_path(relative)
            digest = entry.get("sha256")
            require(
                isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest),
                f"source digest: {relative}",
            )
            require(relative not in seen, f"duplicate claim within role {role}: {relative}")
            seen.add(relative)
            result.append({"role": role, "receipt": receipt, "path": relative, "sha256": digest})
    return result


def main():
    """Check immutable claims, then retain a qualified current-source receipt."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repository = args.repository.resolve()
    directory = args.directory.resolve()
    entries = claims(directory)
    protected = {(directory / receipt).resolve() for _, receipt, _, _ in ROLE_RECEIPTS}
    protected.update((repository / entry["path"]).resolve() for entry in entries)
    require(args.output.resolve() not in protected, "output would overwrite source evidence")
    require(not args.output.is_symlink(), "output symlink")
    checked = {}
    results = []
    for entry in entries:
        relative, expected = entry["path"], entry["sha256"]
        if relative not in checked:
            pinned = subprocess.check_output(
                ["git", "show", f"{AUDITED_SHA}:{relative}"], cwd=repository
            )
            current = regular_file(repository, relative).read_bytes()
            checked[relative] = (
                hashlib.sha256(pinned).hexdigest(),
                hashlib.sha256(current).hexdigest(),
            )
        pinned_digest, current_digest = checked[relative]
        require(pinned_digest == expected, f"pinned claim mismatch: {relative}")
        require(current_digest == expected, f"current claimed source drift: {relative}")
        results.append(dict(entry, pinned_matches=True, current_matches=True))
    counts = {
        role: sum(entry["role"] == role for entry in entries) for role, _, _, _ in ROLE_RECEIPTS
    }
    document = {
        "audited_sha": AUDITED_SHA,
        "current_head": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True
        ).strip(),
        "claims": len(entries),
        "distinct_paths": len(checked),
        "per_role_claims": counts,
        "qualification": "Named source files only; overlapping role claims are not unique coverage. Both pinned Git bytes and current bytes must match. No transitive completeness, semantic parity, native execution or automatic metadata re-hashing is inferred.",
        "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent="\t") + "\n", encoding="utf-8")
    print(f"Authenticated {len(entries)} role claims over {len(checked)} distinct source paths.")


if __name__ == "__main__":
    main()
