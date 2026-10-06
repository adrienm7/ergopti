"""Closed Windows checkpoint fixture port; not POSIX no-follow qualification.

The actual YAML publisher Python still executes in CPython. Only its exact
exclusive open and hard-link publication run through this declared Windows port.
The fixture has no concurrent hostile writer; native POSIX runs remain unchanged.
"""

import json
import os
from pathlib import Path
import stat
import sys


def main():
    if os.name != "nt" or sys.argv[1:] != ["-"]:
        raise RuntimeError("The checkpoint port admits only the Windows stdin fixture")
    source = sys.stdin.read()
    expected = Path(os.environ["SWIFT_FIXTURE_PYTHON_BODY"]).read_text(encoding="utf-8")
    if source.rstrip("\n") != expected.rstrip("\n"):
        raise RuntimeError("The executed checkpoint must be the exact actual YAML publisher")
    root = Path(os.environ["ERGOPTI_ARCHIVE_EVIDENCE_DIR"]).resolve(strict=True)
    owner = root / "workflow"
    temporary = owner / ".workflow-stage"
    destination = owner / "checkpoint.json"
    if owner.exists():
        raise RuntimeError("The fixture publisher must acquire a new workflow owner")
    native_open, native_link = os.open, os.link
    had_nofollow = hasattr(os, "O_NOFOLLOW")
    original_nofollow = getattr(os, "O_NOFOLLOW", None)
    # This is a modeled protocol bit, never a claimed Windows native open flag.
    os.O_NOFOLLOW = 1 << 30
    required_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    counts = {"open": 0, "link": 0}

    def fixture_open(filename, flags, mode=0o777, *, dir_fd=None):
        if Path(filename) != temporary or type(flags) is not int or flags != required_flags:
            raise PermissionError("Unowned checkpoint open")
        if mode != 0o600 or dir_fd is not None:
            raise PermissionError("Unowned checkpoint open options")
        if owner.resolve(strict=True) != owner or temporary.exists() or temporary.is_symlink():
            raise FileExistsError("The fixture checkpoint stage is not exclusively owned")
        counts["open"] += 1
        return native_open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)

    def fixture_link(source_path, target_path, *, follow_symlinks=True, **options):
        if Path(source_path) != temporary or Path(target_path) != destination:
            raise PermissionError("Unowned checkpoint publication")
        if follow_symlinks is not False or options:
            raise PermissionError("Unowned checkpoint publication options")
        if not stat.S_ISREG(temporary.lstat().st_mode):
            raise RuntimeError("The acquired checkpoint stage must be a regular file")
        counts["link"] += 1
        return native_link(source_path, target_path, follow_symlinks=False)

    # A foreign-path request must fail before any real descriptor is acquired.
    try:
        fixture_open(root / "foreign-stage", required_flags, 0o600)
    except PermissionError:
        pass
    else:
        raise AssertionError("The closed checkpoint port admitted a foreign path")
    assert counts == {"open": 0, "link": 0}
    os.open, os.link = fixture_open, fixture_link
    try:
        exec(compile(source, "<actual-workflow-checkpoint>", "exec"), {"__name__": "__main__"})
        assert counts == {"open": 1, "link": 1}
        assert not temporary.exists()
        assert stat.S_ISREG(destination.lstat().st_mode)
        checkpoint = json.loads(destination.read_text(encoding="utf-8"))
        assert checkpoint == {
            "schema": 1,
            "owner": "workflow",
            "phase": "candidate.begin",
            "scope": "swift-not-started",
            "ownership_closed": False,
            "status": "pending",
            "elapsed_seconds": 0,
            "history_omitted": 0,
        }
    finally:
        os.open, os.link = native_open, native_link
        if had_nofollow:
            os.O_NOFOLLOW = original_nofollow
        else:
            del os.O_NOFOLLOW


if __name__ == "__main__":
    main()
