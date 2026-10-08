# tools/test/prepare-linux-managed-http-snapshot.py

"""Capture one literal current driver/shared cohort without applying changes.

The exact HEAD, index and working-tree status are bound separately from every
source byte. This is an honest working-tree snapshot, never a published-tree
claim. Missing/changed sources refuse; an unadmitted private copy is retained.
"""

from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import time

MAX_FILES = 20000
MAX_SOURCE_BYTES = 512 * 1024 * 1024
TOTAL_SECONDS = 120


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], stderr=subprocess.PIPE, timeout=30
    )


def write_json(path, value):
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    path.chmod(0o600)


def inventory(root, deadline):
    source = root / "static/ergopti_plus"
    for directory in (root, root / "static", source):
        if not stat.S_ISDIR(directory.lstat().st_mode):
            raise RuntimeError("Literal source root required")
    pending = [source]
    files = []
    total = 0
    while pending:
        if time.monotonic() >= deadline:
            raise RuntimeError("Snapshot deadline expired")
        directory = pending.pop()
        if not stat.S_ISDIR(directory.lstat().st_mode):
            raise RuntimeError("Source directory kind changed")
        for entry in sorted(os.scandir(directory), key=lambda item: item.name):
            path = Path(entry.path)
            native = path.lstat()
            if stat.S_ISDIR(native.st_mode):
                pending.append(path)
            elif stat.S_ISREG(native.st_mode):
                total += native.st_size
                if len(files) >= MAX_FILES or total > MAX_SOURCE_BYTES:
                    raise RuntimeError("Snapshot source inventory bound refused")
                data = path.read_bytes()
                if time.monotonic() >= deadline:
                    raise RuntimeError("Snapshot deadline expired")
                after = path.lstat()
                if not stat.S_ISREG(after.st_mode) or len(data) != native.st_size:
                    raise RuntimeError("Source kind or size changed")
                files.append(
                    {
                        "path": path.relative_to(root).as_posix(),
                        "kind": "file",
                        "sha256": digest(data),
                    }
                )
            else:
                raise RuntimeError("Symlink or special source refused")
    return sorted(files, key=lambda entry: entry["path"])


def capture(root, out, expected_head):
    # Admit the provided root itself before canonicalization can hide a symlink.
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise RuntimeError("Literal source directory required")
    root = root.resolve(strict=True)
    if not stat.S_ISDIR(root.lstat().st_mode) or not out.is_absolute():
        raise RuntimeError("Literal source and absolute private output required")
    parent = out.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
        raise RuntimeError("Owned private snapshot parent required")
    # lexists also refuses broken symlinks and special existing destinations.
    if os.path.lexists(out):
        raise RuntimeError("New private snapshot destination required")
    deadline = time.monotonic() + TOTAL_SECONDS
    head = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    if head != expected_head:
        raise RuntimeError("Expected source HEAD differs")
    status = git(root, "status", "--porcelain=v1", "-z")
    index = git(root, "ls-files", "--stage", "-z", "static/ergopti_plus")
    entries = inventory(root, deadline)
    out.mkdir(mode=0o700)
    dependency = out / "dependencies"
    dependency.mkdir(mode=0o700)
    for entry in entries:
        if time.monotonic() >= deadline:
            raise RuntimeError("Snapshot deadline expired")
        original = root / entry["path"]
        if not stat.S_ISREG(original.lstat().st_mode):
            raise RuntimeError("Literal source kind changed")
        copied = dependency / entry["path"]
        copied.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with original.open("rb") as source, copied.open("xb") as target:
            shutil.copyfileobj(source, target, 65536)
        copied.chmod(0o600)
        if digest(copied.read_bytes()) != entry["sha256"]:
            raise RuntimeError("Copied source bytes changed")
    if (
        inventory(root, deadline) != entries
        or inventory(dependency, deadline) != entries
        or git(root, "rev-parse", "HEAD").decode("ascii").strip() != head
        or git(root, "status", "--porcelain=v1", "-z") != status
        or git(root, "ls-files", "--stage", "-z", "static/ergopti_plus") != index
    ):
        raise RuntimeError("Source cohort changed during snapshot")
    receipt = {
        "dependency_commit": head,
        "phase": "working-tree-snapshot",
        "git_status_sha256": digest(status),
        "git_index_sha256": digest(index),
        "files": len(entries),
    }
    write_json(dependency / "SOURCE-RECEIPT.json", receipt)
    inventory_path = out / "DEPENDENCY-FILES.json"
    write_json(
        inventory_path,
        {"commit": head, "phase": "working-tree-snapshot", "entries": entries},
    )
    manifest = out / "FINAL-SOURCE-MANIFEST.json"
    write_json(
        manifest,
        {
            "files": [
                {"path": "dependencies/" + item["path"], "sha256": item["sha256"]}
                for item in entries
            ]
        },
    )
    native = dependency / "static/ergopti_plus/linux/adapters/curl_http_client.lua"
    admission = {
        "expected_manifest": digest(manifest.read_bytes()),
        "expected_inventory_sha256": digest(inventory_path.read_bytes()),
        "expected_native_sha256": digest(native.read_bytes()),
        "expected_dependency_commit": head,
        "expected_dependency_phase": "working-tree-snapshot",
        "source_files": len(entries),
    }
    write_json(out / "ADMISSION.json", admission)
    # No giant inventory, private pathname, raw Git status or source is emitted.
    print(
        json.dumps(
            {
                "phase": "working-tree-snapshot",
                "source_files": len(entries),
                "inventory_sha256": admission["expected_inventory_sha256"],
                "native_execution": False,
            }
        )
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-head", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_head):
        parser.error("Exact expected Git HEAD required")
    try:
        capture(args.repository, args.output, args.expected_head)
    except BaseException:
        # Fixed diagnostic: native/private path or Git output never escapes.
        raise SystemExit("Source snapshot refused; private unadmitted copy retained.")


if __name__ == "__main__":
    main()
