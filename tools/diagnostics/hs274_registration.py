# tools/diagnostics/hs274_registration.py
"""Suspend automatic service registration only inside the disposable fixture."""

from contextlib import contextmanager, ExitStack
import os
from pathlib import Path
import stat
import sys

from hs274_services import command, require_success


def helper_paths():
    """Return only the two installed registration helpers used by pinned upstream."""
    base = Path("/Library/Application Support/org.pqrs/Karabiner-Elements")
    return tuple((base / (name + ".app/Contents/MacOS") / name, query) for name, query in (
        ("Karabiner-Elements Privileged Daemons v2", "core-daemons-enabled"),
        ("Karabiner-Elements Non-Privileged Agents v2", "core-agents-enabled"),
    ))


def inspect_owned(record):
    """Refuse pathname replacement before altering or trusting an acquired file."""
    path = Path(record["path"])
    current = path.lstat()
    if not stat.S_ISREG(current.st_mode) or path.resolve() != path:
        raise RuntimeError("Registration helper is not a direct regular file")
    if (current.st_dev, current.st_ino) != (record["device"], record["inode"]):
        raise RuntimeError("Registration helper identity changed")
    return stat.S_IMODE(current.st_mode)


def verify_registration_block(report):
    """Require the same non-executable helper files throughout the fixture."""
    for record in report["registration_helpers"]:
        if inspect_owned(record) != record["blocked_mode"]:
            raise RuntimeError("Registration helper permissions changed during the fixture")


@contextmanager
def suspended_registration(report):
    """Restore exact modes after success, failure, or partial setup on macOS CI."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Registration suspension requires disposable macOS Actions")
    if not os.environ.get("HS274_DEVELOPMENT_ROOT"):
        raise RuntimeError("Registration suspension requires explicit development mode")
    records = report["registration_helpers"] = []

    def restore(record):
        inspect_owned(record)
        require_success(["sudo", "-n", "chmod", format(record["original_mode"], "o"), record["path"]])
        record["restored"] = inspect_owned(record) == record["original_mode"]
        if not record["restored"]:
            raise RuntimeError("Registration helper permissions were not restored")

    with ExitStack() as stack:
        for path, query in helper_paths():
            acquired = path.lstat()
            original = stat.S_IMODE(acquired.st_mode)
            record = {"path": str(path), "device": acquired.st_dev, "inode": acquired.st_ino,
                      "original_mode": original, "blocked_mode": original & ~0o111, "restored": False}
            inspect_owned(record)
            if not original & 0o111:
                raise RuntimeError("Installed registration helper was already non-executable")
            records.append(record)
            stack.callback(restore, record)
            require_success(["sudo", "-n", "chmod", format(record["blocked_mode"], "o"), str(path)])
            verify_registration_block(report)
            # sudo's own lookup hides EACCES as "command not found". Let the
            # native exec attempt report its errno in a deterministic locale.
            refusal = command(["sudo", "-n", "/usr/bin/env", "LC_ALL=C", str(path), query])
            record["execution_refusal"] = {"exit": refusal.returncode, "stdout": refusal.stdout,
                                           "stderr": refusal.stderr}
            if refusal.returncode != 126 or "Permission denied" not in refusal.stderr:
                raise RuntimeError("Native registration helper execution was not explicitly refused")
        yield
