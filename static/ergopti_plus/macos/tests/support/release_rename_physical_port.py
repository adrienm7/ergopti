# static/ergopti_plus/macos/tests/support/release_rename_physical_port.py

"""Test-only CLI port: execute real exclusive native renames and BSD file leases."""

import ctypes
import fcntl
import os
from pathlib import Path
import stat
import sys

FLAG = "--release-rename"


def exclusive_rename(source, destination):
    """Use the host kernel's no-replacement rename, never mv or a copy model."""
    libc = ctypes.CDLL(None, use_errno=True)
    source_path, destination_path = Path(source), Path(destination)
    source_fd = os.open(source_path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        destination_fd = os.open(
            destination_path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
        )
        try:
            observed = os.stat(source_path.name, dir_fd=source_fd, follow_symlinks=False)
            if not stat.S_ISDIR(observed.st_mode):
                return 2
            if sys.platform == "darwin":
                # Darwin RENAME_EXCL, not Linux RENAME_NOREPLACE's distinct bit.
                rename, flags = libc.renameatx_np, 0x00000004
            elif sys.platform == "linux":
                rename, flags = libc.renameat2, 1
            else:
                raise RuntimeError("The physical rename port requires Darwin or Linux")
            rename.argtypes = [
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint,
            ]
            rename.restype = ctypes.c_int
            result = rename(
                source_fd,
                os.fsencode(source_path.name),
                destination_fd,
                os.fsencode(destination_path.name),
                flags,
            )
            if result != 0:
                print(
                    "Exclusive release rename refused (errno " + str(ctypes.get_errno()) + ").",
                    file=sys.stderr,
                )
                return 3
            return 0
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)


def lock(arguments):
    """Mirror the native supervisor's inherited, non-unlinked descriptor custody."""
    app, script, pid, staged, previous = arguments
    if previous != app + ".previous" or not pid.isdecimal() or pid.startswith("0"):
        return 1
    path = app + ".release-lock"
    descriptor = os.open(
        path, os.O_RDWR | os.O_CREAT | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600
    )
    lease = fcntl.fcntl(descriptor, fcntl.F_DUPFD_CLOEXEC, 4)
    os.close(descriptor)
    try:
        held, named = os.fstat(lease), os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISREG(held.st_mode)
            or stat.S_IMODE(held.st_mode) != 0o600
            or held.st_uid != os.geteuid()
            or held.st_nlink != 1
            or held.st_size != 0
            or (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino)
        ):
            return 2
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another release replacement owns the installation lease.", file=sys.stderr)
            return 4
        os.set_inheritable(lease, True)
        os.execv("/bin/sh", ["/bin/sh", "-c", script, "swap", pid, app, staged, previous])
    finally:
        os.close(lease)


def main(arguments):
    """Reject unknown argv and expose only the explicit test ABI boundary."""
    if not arguments or arguments[0] != FLAG:
        return 1
    if arguments[1:] == ["probe"]:
        print(FLAG)
        return 0
    if len(arguments) == 4 and arguments[1] == "move":
        return exclusive_rename(*arguments[2:])
    if len(arguments) == 7 and arguments[1] == "lock":
        return lock(arguments[2:])
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except OSError as error:
        print("The physical release rename port refused: " + str(error), file=sys.stderr)
        sys.exit(2)
