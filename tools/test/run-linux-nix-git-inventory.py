# tools/test/run-linux-nix-git-inventory.py

"""Spool the complete Git index under the existing native phase owner."""

import json
import os
import stat
import sys


def main():
    """Create a private output, publish its identity, and become the Git child."""
    if len(sys.argv) != 3 or not all(os.path.isabs(arg) for arg in sys.argv[1:]):
        raise ValueError("Absolute Git inventory arguments required")
    root, target = sys.argv[1:]
    parent = os.path.dirname(target)
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        before = os.fstat(directory)
        if before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) != 0o700:
            raise ValueError("Private Git inventory directory required")
        descriptor = os.open(
            os.path.basename(target),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=directory,
        )
        try:
            fact = os.fstat(descriptor)
            after = os.stat(parent, follow_symlinks=False)
            if (
                not stat.S_ISREG(fact.st_mode)
                or fact.st_uid != os.geteuid()
                or fact.st_nlink != 1
                or stat.S_IMODE(fact.st_mode) != 0o600
                or fact.st_size != 0
                or (after.st_dev, after.st_ino, after.st_mode, after.st_uid)
                != (before.st_dev, before.st_ino, before.st_mode, before.st_uid)
            ):
                raise ValueError("Git inventory creation identity refused")
            # This small receipt stays in the bounded phase capture. Only Git's
            # complete NUL inventory leaves that capture for the private file.
            receipt = {
                "schema": 1,
                "dev": str(fact.st_dev),
                "ino": str(fact.st_ino),
                "uid": str(fact.st_uid),
                "mode": 0o600,
                "nlink": 1,
            }
            raw = (json.dumps(receipt, separators=(",", ":")) + "\n").encode("ascii")
            if os.write(sys.stdout.fileno(), raw) != len(raw):
                raise OSError("Git inventory creation receipt incomplete")
            os.dup2(descriptor, sys.stdout.fileno(), inheritable=True)
        finally:
            os.close(descriptor)
    finally:
        os.close(directory)
    # Exec preserves the exact child PID and its original process-group owner.
    # Git exit, inherited output closure and cancellation remain phase receipts.
    os.execv("/usr/bin/git", ["git", "-C", root, "ls-files", "-z"])


if __name__ == "__main__":
    main()
