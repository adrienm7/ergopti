# tools/test/prepare-linux-updater-archive-snapshot.py
"""Capture actual index-listed working bytes into a genuine private Git clone.

No synthetic HEAD/history/commit. All subprocesses belong to the outer existing
phase owner. Missing/deleted/aliased/unmerged input refuses, evidence stays.
"""

from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import time


def sha(value):
    return hashlib.sha256(value).hexdigest()


def literal(path, directory=False):
    mode = path.lstat().st_mode
    if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
        raise RuntimeError("Literal source kind refused")
    parent = path.parent
    while parent != parent.parent:
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise RuntimeError("Literal source ancestry refused")
        parent = parent.parent


def capture(repository, clone, output, expected):
    end = time.monotonic() + 150
    git_environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    git_environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    git_environment["GIT_CONFIG_NOSYSTEM"] = "1"
    git_environment["GIT_OPTIONAL_LOCKS"] = "0"  # Status must not refresh original index.

    def current():
        if time.monotonic() >= end:
            raise RuntimeError("Snapshot original deadline refused")

    def git(root, *args, environment=None):
        current()
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=git_environment if environment is None else environment,
            check=False,
            timeout=max(0.001, min(30, end - time.monotonic())),
        )
        current()
        if result.returncode != 0 or result.stderr:
            raise RuntimeError("Snapshot Git admission refused")
        return result.stdout

    for root in (repository, clone, output.parent):
        if not root.is_absolute():
            raise RuntimeError("Absolute snapshot roots required")
        literal(root, True)
    fact = clone.parent.lstat()
    if fact.st_uid != os.geteuid() or stat.S_IMODE(fact.st_mode) != 0o700:
        raise RuntimeError("Private clone namespace refused")
    if repository == clone or repository in clone.parents or clone in repository.parents:
        raise RuntimeError("Distinct original and owned clone required")
    if os.path.lexists(output):
        raise RuntimeError("Fresh snapshot namespace required")
    if (
        git(repository, "rev-parse", "HEAD") != (expected + "\n").encode()
        or git(clone, "rev-parse", "HEAD") != (expected + "\n").encode()
    ):
        raise RuntimeError("Original genuine Git HEAD refused")
    index = git(repository, "ls-files", "--stage", "-z")
    status = git(repository, "status", "--porcelain=v1", "-z")
    names = []
    for record in index.split(b"\0"):
        if not record:
            continue
        metadata, raw_name = record.split(b"\t", 1)
        mode, blob, stage = metadata.split(b" ")
        if (
            mode not in (b"100644", b"100755")
            or stage != b"0"
            or re.fullmatch(rb"(?:[0-9a-f]{40}|[0-9a-f]{64})", blob) is None
        ):
            raise RuntimeError("Ordinary exact index entry required")
        name = raw_name.decode("utf-8", "strict")
        if (
            name.startswith("/")
            or ".." in Path(name).parts
            or not name
            or ".git" in Path(name).parts
        ):
            raise RuntimeError("Literal repository-relative index name refused")
        names.append(name)
    if len(names) != len(set(names)) or not 0 < len(names) <= 20000:
        raise RuntimeError("Finite unique index inventory required")
    clone_names = git(clone, "ls-files", "-z").split(b"\0")
    if any(name.decode("utf-8", "strict") not in names for name in clone_names if name):
        raise RuntimeError("Staged deletion requires separate exact private prune ownership")
    output.mkdir(mode=0o700)
    frozen = output / "files"
    frozen.mkdir(mode=0o700)
    rows, total = [], 0
    for name in sorted(names):
        current()
        source = repository / name
        literal(source)
        fact = source.lstat()
        if stat.S_IMODE(fact.st_mode) & 0o7000 or fact.st_size > 32 * 1024 * 1024:
            raise RuntimeError("Snapshot individual source bound refused")
        data = source.read_bytes()
        total += len(data)
        if total > 512 * 1024 * 1024 or len(data) != fact.st_size:
            raise RuntimeError("Snapshot source inventory bound refused")
        copied = frozen / name
        copied.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with copied.open("xb") as sink:
            sink.write(data)
        copied.chmod(stat.S_IMODE(fact.st_mode))
        row = {"path": name, "mode": stat.S_IMODE(fact.st_mode), "sha256": sha(data)}
        if sha(copied.read_bytes()) != row["sha256"]:
            raise RuntimeError("Copied snapshot bytes refused")
        rows.append(row)
    for row in rows:
        current()
        source = repository / row["path"]
        literal(source)
        if (
            stat.S_IMODE(source.lstat().st_mode) != row["mode"]
            or sha(source.read_bytes()) != row["sha256"]
        ):
            raise RuntimeError("Working source changed during capture")
        target = clone / row["path"]
        if os.path.lexists(target):
            literal(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        literal(target.parent, True)
        with target.open("wb" if os.path.lexists(target) else "xb") as sink:
            sink.write((frozen / row["path"]).read_bytes())
        target.chmod(row["mode"])
        literal(target)
        if sha(target.read_bytes()) != row["sha256"]:
            raise RuntimeError("Private clone overlay bytes refused")
    pathspec = output / "PATHS.nul"
    with pathspec.open("xb") as sink:
        sink.write(b"\0".join(name.encode() for name in names) + b"\0")
    pathspec.chmod(0o600)
    env = git_environment.copy()
    env["GIT_LITERAL_PATHSPECS"] = "1"
    git(
        clone,
        "add",
        "--force",
        "--pathspec-from-file=" + str(pathspec),
        "--pathspec-file-nul",
        environment=env,
    )
    if set(git(clone, "ls-files", "-z").split(b"\0")) != set(name.encode() for name in names) | {
        b""
    }:
        raise RuntimeError("Private copied Git index differs")
    for row in rows:
        current()
        for root in (repository, frozen, clone):
            target = root / row["path"]
            literal(target)
            if (
                stat.S_IMODE(target.lstat().st_mode) != row["mode"]
                or sha(target.read_bytes()) != row["sha256"]
            ):
                raise RuntimeError("Snapshot final bytes/mode changed")
    if (
        git(repository, "ls-files", "--stage", "-z") != index
        or git(repository, "status", "--porcelain=v1", "-z") != status
        or git(repository, "rev-parse", "HEAD") != (expected + "\n").encode()
        or git(clone, "rev-parse", "HEAD") != (expected + "\n").encode()
    ):
        raise RuntimeError("Original index/status/HEAD changed")
    raw = (json.dumps(rows, sort_keys=True, separators=(",", ":")) + "\n").encode()
    with (output / "SOURCE-FILES.json").open("xb") as sink:
        sink.write(raw)
    current()
    with (output / "ADMISSION.json").open("x", encoding="utf-8") as sink:
        json.dump(
            {
                "schema": 1,
                "source_head": expected,
                "phase": "working-tree-snapshot",
                "inventory_sha256": sha(raw),
                "index_sha256": sha(index),
                "status_sha256": sha(status),
                "files": len(rows),
                "original_mutated": False,
            },
            sink,
            sort_keys=True,
        )
        sink.write("\n")
    current()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--clone", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-head", required=True)
    args = parser.parse_args()
    if re.fullmatch(r"[0-9a-f]{40}", args.expected_head) is None:
        raise SystemExit("Snapshot source identity refused.")
    try:
        capture(args.repository, args.clone, args.output, args.expected_head)
    except BaseException:
        raise SystemExit("Snapshot refused; original untouched and private evidence retained.")
