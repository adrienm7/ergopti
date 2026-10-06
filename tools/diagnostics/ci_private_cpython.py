# tools/diagnostics/ci_private_cpython.py
"""Copy standard CPython into one private CI venv before selecting its PATH.

The setup image may have the toolchain's observed group-write permission. It
is a read-only bootstrap input, never an admitted native worker image. Only
task-owned byte-identical copies have write access restricted. No install,
pip, privileged worker, global permission change or runtime waiver occurs.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import sys
import sysconfig
import tempfile
import time
import types
import venv

SUCCESS_SECONDS = 25
OBSERVER_SECONDS = 35
RETIRE_SECONDS = 10
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_SOURCE_BYTES = 1024 * 1024
MAX_RECEIPT_BYTES = 16_384
WAIT_NAMES = (
    "waitid",
    "P_PID",
    "WEXITED",
    "WNOHANG",
    "WNOWAIT",
    "CLD_EXITED",
    "CLD_KILLED",
    "CLD_DUMPED",
)
REFUSAL_CODES = {
    "Private CPython setup source alias refused": "setup-source-alias",
    "Private CPython executed runtime or stdlib differs": "runtime-or-stdlib",
    "Private CPython venv inventory changed": "venv-inventory",
    "Private CPython interpreter inventory refused": "interpreter-inventory",
    "Private CPython smoke failed": "smoke-execution",
    "Private CPython smoke retirement failed": "smoke-retirement",
    "Private CPython smoke completion refused": "smoke-completion",
    "Private CPython held input changed": "input-currentness",
    "Private CPython directory changed": "directory-currentness",
    "Private CPython ordinary file refused": "ordinary-file",
    "Private CPython setup deadline exhausted": "deadline",
    "Private setup runtime differs from base image": "base-image",
    "Native private setup requires macOS CPython >= 3.13": "host-version",
}
SMOKE = """import argparse, ctypes, hashlib, json, math, os, pathlib, re, signal, stat
import subprocess, sys, sysconfig, tempfile, time, types, venv
names = ('waitid', 'P_PID', 'WEXITED', 'WNOHANG', 'WNOWAIT', 'CLD_EXITED', 'CLD_KILLED', 'CLD_DUMPED')
print(json.dumps({'implementation': sys.implementation.name, 'version': list(sys.version_info[:3]),
 'executable': sys.executable, 'prefix': sys.prefix, 'base_prefix': sys.base_prefix,
 'stdlib': sysconfig.get_path('stdlib'), 'platform': sys.platform,
 'nonreaping_apis': [name for name in names if hasattr(os, name)]}, sort_keys=True))
"""


def require(condition, message):
    """Keep every refusal active under optimized Python."""
    if not condition:
        raise ValueError(message)


def identity(info):
    """Capture the held image's metadata without access-time observations."""
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_uid,
        info.st_gid,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def check_deadline(deadline):
    """Refuse late success, including late persistence."""
    require(time.monotonic() < deadline, "Private CPython setup deadline exhausted")


class PinnedFile:
    """Hold current exact bytes; writable bootstrap permission is explicit."""

    def __init__(self, path, maximum, *, bootstrap=False, allow_empty=False):
        self.path = Path(path)
        self.fd = None
        require(
            self.path.is_absolute() and self.path.parent.resolve(strict=True) == self.path.parent,
            "Private CPython input parent alias refused",
        )
        self.fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(self.fd)
            require(
                stat.S_ISREG(info.st_mode)
                and (0 <= info.st_size if allow_empty else 0 < info.st_size)
                and info.st_size <= maximum
                and info.st_nlink == 1
                and not info.st_mode & 0o7000
                and (bootstrap or info.st_uid == os.geteuid() and not info.st_mode & 0o022),
                "Private CPython ordinary file refused",
            )
            self.before = identity(info)
            self.body = self.read(maximum)
            self.current()
        except BaseException:
            self.close()
            raise

    def read(self, maximum):
        """Bound actual held-FD reads rather than trusting pathname contents."""
        os.lseek(self.fd, 0, os.SEEK_SET)
        parts = []
        size = 0
        while size <= maximum:
            part = os.read(self.fd, min(65536, maximum + 1 - size))
            if not part:
                break
            parts.append(part)
            size += len(part)
        require(size <= maximum, "Private CPython file size exceeded")
        return b"".join(parts)

    def current(self):
        """Require both named and held current identities plus complete bytes."""
        require(
            identity(os.fstat(self.fd)) == self.before
            and identity(os.stat(self.path, follow_symlinks=False)) == self.before
            and self.read(len(self.body)) == self.body
            and identity(os.fstat(self.fd)) == self.before
            and identity(os.stat(self.path, follow_symlinks=False)) == self.before,
            "Private CPython held input changed",
        )

    def close(self):
        """Close an acquired descriptor once, including constructor failures."""
        if self.fd is not None:
            descriptor, self.fd = self.fd, None
            os.close(descriptor)


class PinnedDirectory:
    """Retain a canonical owned directory while ordinary contents are created."""

    def __init__(self, path, *, private=False):
        self.path = Path(path)
        self.fd = None
        require(
            self.path.is_absolute() and self.path.resolve(strict=True) == self.path,
            "Private CPython directory alias refused",
        )
        self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(self.fd)
            require(
                stat.S_ISDIR(info.st_mode)
                and info.st_uid == os.geteuid()
                and not info.st_mode & 0o022
                and (not private or stat.S_IMODE(info.st_mode) == 0o700),
                "Private CPython directory owner refused",
            )
            self.before = self.key(info)
            self.current()
        except BaseException:
            self.close()
            raise

    @staticmethod
    def key(info):
        """Exclude content timestamps that change during standard venv creation."""
        return info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid

    def current(self):
        """Reject aliasing, mode changes and replacement through either view."""
        require(
            self.path.resolve(strict=True) == self.path
            and self.key(os.fstat(self.fd)) == self.before
            and self.key(os.stat(self.path, follow_symlinks=False)) == self.before,
            "Private CPython directory changed",
        )

    def close(self):
        """Close only this acquired directory descriptor."""
        if self.fd is not None:
            descriptor, self.fd = self.fd, None
            os.close(descriptor)


def restrict_copy(path, original):
    """Remove group/other write bits from only an owned byte-identical copy."""
    copied = PinnedFile(path, MAX_IMAGE_BYTES, bootstrap=True)
    try:
        before = os.fstat(copied.fd)
        require(
            before.st_uid == os.geteuid() and before.st_mode & stat.S_IXUSR,
            "Private CPython copied executable owner refused",
        )
        require(
            copied.body == original.body,
            "Private CPython copied executable bytes differ",
        )
        original.current()
        copied.current()
        os.fchmod(copied.fd, stat.S_IMODE(before.st_mode) & ~0o022)
        copied.before = identity(os.fstat(copied.fd))
        require(not copied.before[2] & 0o022, "Private CPython copy remains writable")
        copied.current()
        original.current()
    finally:
        copied.close()


def native_smoke(arguments, owned, stdout, stderr, deadline):
    """Acquire and retire the actual Mac child through existing native ownership."""
    native = owned.NativeProcessGroups()
    group = None
    previous = {}
    failure = None
    cleanup_failure = None

    def interrupted(_number, _frame):
        raise owned.OwnedProcessInterrupted("Private CPython smoke interrupted")

    def register(acquired):
        nonlocal group
        require(group is None, "Private CPython smoke registered twice")
        group = acquired

    try:
        for number in (signal.SIGTERM, signal.SIGINT):
            previous[number] = signal.signal(number, interrupted)
        owned.acquire_owned(arguments, native, register, stdout=stdout, stderr=stderr)
        check_deadline(deadline)
        group.wait_for_exit(min(OBSERVER_SECONDS, deadline - time.monotonic()))
    except BaseException as error:
        failure = error
    finally:
        retirement_started = time.monotonic()
        try:
            for number in previous:
                signal.signal(number, signal.SIG_IGN)
            require(
                group is not None and group.settle(timeout=3),
                "Private CPython smoke retains process-group debt",
            )
            require(
                time.monotonic() - retirement_started < RETIRE_SECONDS,
                "Private CPython smoke retirement deadline exhausted",
            )
        except BaseException as error:
            cleanup_failure = error
        finally:
            for number, handler in previous.items():
                try:
                    signal.signal(number, handler)
                except BaseException as error:
                    cleanup_failure = error
    if cleanup_failure is not None:
        raise ValueError("Private CPython smoke retirement failed") from cleanup_failure
    if failure is not None:
        raise ValueError("Private CPython smoke failed") from failure
    receipt = group.receipt()
    require(
        group.process.returncode == 0
        and receipt["closed"]
        and not receipt["reservation_lost"]
        and not receipt["live_group_members"]
        and receipt["escaped_sessions_managed"] is False,
        "Private CPython smoke completion refused",
    )
    return receipt


def tree_paths(root):
    """Inventory ordinary entries and the standard non-Darwin lib64 metadata link."""
    directories, files, links = [], [], []

    def refused(error):
        raise error

    for parent, names, leaves in os.walk(root, followlinks=False, onerror=refused):
        directories.append(Path(parent))
        for name in names:
            path = Path(parent) / name
            if path.is_symlink():
                # CPython's standard EnvBuilder creates this metadata entry even
                # with symlinks=False. It is never an executable or traversed input.
                before = path.lstat()
                require(
                    os.name == "posix"
                    and sys.maxsize > 2**32
                    and sys.platform != "darwin"
                    and path == root / "lib64"
                    and os.readlink(path) == "lib"
                    and before.st_uid == os.geteuid()
                    and before.st_nlink == 1
                    and path.resolve(strict=True) == root / "lib"
                    and identity(path.lstat()) == identity(before),
                    "Private CPython tree alias refused",
                )
                links.append((path, identity(before), "lib"))
        files.extend(Path(parent) / name for name in leaves)
    return sorted(directories), sorted(files), sorted(links)


def prepare(parent, *, smoke=native_smoke):
    """Return one fully checked selection; portable tests inject explicit leaf execution."""
    require(sys.implementation.name == "cpython", "Private setup requires genuine CPython")
    deadline = time.monotonic() + SUCCESS_SECONDS
    pins = []
    streams = []

    def hold(pin):
        pins.append(pin)
        return pin

    try:
        here = Path(__file__)
        require(
            here.is_absolute() and here.resolve(strict=True) == here,
            "Private CPython setup source alias refused",
        )
        own = hold(PinnedFile(here, MAX_SOURCE_BYTES))
        guardian = hold(PinnedFile(here.with_name("macos_owned_process.py"), MAX_SOURCE_BYTES))
        # Canonicalize only the configured toolchain references, then hold exact
        # ordinary images. A supplied file or private output never gets this allowance.
        original = hold(
            PinnedFile(
                Path(sys._base_executable).resolve(strict=True),
                MAX_IMAGE_BYTES,
                bootstrap=True,
            )
        )
        executing = hold(
            PinnedFile(
                Path(sys.executable).resolve(strict=True),
                MAX_IMAGE_BYTES,
                bootstrap=True,
            )
        )
        require(
            executing.body == original.body,
            "Private setup runtime differs from base image",
        )
        expected = {
            "implementation": "cpython",
            "version": list(sys.version_info[:3]),
            "base_prefix": sys.base_prefix,
            "stdlib": sysconfig.get_path("stdlib"),
            "platform": sys.platform,
            "nonreaping_apis": list(WAIT_NAMES),
        }
        parent_pin = hold(PinnedDirectory(parent, private=True))
        root = Path(tempfile.mkdtemp(prefix="cpython-", dir=parent_pin.path))
        hold(PinnedDirectory(root, private=True))
        environment = root / "venv"
        environment.mkdir(mode=0o700)
        hold(PinnedDirectory(environment, private=True))
        check_deadline(deadline)
        previous_mask = os.umask(0o077)
        try:
            venv.EnvBuilder(with_pip=False, symlinks=False).create(environment)
        finally:
            os.umask(previous_mask)
        check_deadline(deadline)
        for pinned in pins:
            pinned.current()
        names = {
            "python",
            "python3",
            f"python{sys.version_info.major}.{sys.version_info.minor}",
        }
        binary_dir = environment / "bin"
        require(
            {path.name for path in binary_dir.glob("python*")} == names,
            "Private CPython interpreter inventory refused",
        )
        for name in sorted(names):
            restrict_copy(binary_dir / name, original)
            check_deadline(deadline)
        directories, files, links = tree_paths(environment)
        for path in directories:
            hold(PinnedDirectory(path))
        for path in files:
            hold(
                PinnedFile(
                    path,
                    MAX_IMAGE_BYTES
                    if path.parent == binary_dir and path.name in names
                    else MAX_SOURCE_BYTES,
                )
            )

        def current():
            check_deadline(deadline)
            require(
                tree_paths(environment) == (directories, files, links),
                "Private CPython venv inventory changed",
            )
            for pin in pins:
                pin.current()
            check_deadline(deadline)

        current()
        owned = types.ModuleType("private_cpython_owned")
        owned.__file__ = str(guardian.path)
        exec(compile(guardian.body, str(guardian.path), "exec"), owned.__dict__)
        current()
        for name in ("smoke.stdout", "smoke.stderr"):
            fd = os.open(root / name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            streams.append(os.fdopen(fd, "w+b"))
        binary = binary_dir / "python3"
        ownership = smoke(
            [str(binary), "-I", "-B", "-c", SMOKE],
            owned,
            streams[0],
            streams[1],
            deadline,
        )
        current()
        bodies = []
        for name, stream in zip(("smoke.stdout", "smoke.stderr"), streams):
            stream.flush()
            os.fsync(stream.fileno())
            pin = hold(PinnedFile(root / name, MAX_RECEIPT_BYTES, allow_empty=True))
            require(
                identity(os.fstat(stream.fileno())) == pin.before,
                "Private CPython smoke output replaced",
            )
            if name.endswith("stdout"):
                bodies.append(pin.body)
            else:
                info = os.fstat(stream.fileno())
                require(
                    stat.S_ISREG(info.st_mode)
                    and info.st_size == 0
                    and info.st_nlink == 1
                    and info.st_uid == os.geteuid()
                    and stat.S_IMODE(info.st_mode) == 0o600
                    and identity(info) == identity(os.stat(root / name, follow_symlinks=False)),
                    "Private CPython smoke stderr refused",
                )
        sample = json.loads(bodies[0])
        expected.update(executable=str(binary), prefix=str(environment))
        require(sample == expected, "Private CPython executed runtime or stdlib differs")
        current()
        receipt = {
            "schema": 1,
            "kind": "private_standard_cpython_setup",
            "authority_granted": False,
            "selection": str(binary_dir),
            "smoke": sample,
            "ownership": ownership,
            "original_image_sha256": hashlib.sha256(original.body).hexdigest(),
            "bootstrap_image": {
                "path": str(original.path),
                "identity": original.before,
                "bytes": len(original.body),
                "native_admitted": False,
            },
            "copied_images": {
                pin.path.name: {
                    "identity": pin.before,
                    "sha256": hashlib.sha256(pin.body).hexdigest(),
                }
                for pin in pins
                if isinstance(pin, PinnedFile)
                and pin.path.parent == binary_dir
                and pin.path.name in names
            },
            "source_hashes": {
                "setup": hashlib.sha256(own.body).hexdigest(),
                "guardian": hashlib.sha256(guardian.body).hexdigest(),
            },
        }
        data = (json.dumps(receipt, allow_nan=False, sort_keys=True) + "\n").encode()
        require(len(data) <= MAX_RECEIPT_BYTES, "Private CPython receipt size refused")
        fd = os.open(
            root / "selection.json",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        retained = hold(PinnedFile(root / "selection.json", MAX_RECEIPT_BYTES))
        require(retained.body == data, "Private CPython receipt readback differs")
        current()
        require(
            not any(character in str(binary_dir) for character in "\r\n"),
            "Private CPython PATH line refused",
        )
        result = str(binary_dir)
    finally:
        # No selection is returned through an exception, including final close failure.
        failure = None
        for stream in streams:
            try:
                stream.close()
            except BaseException as error:
                failure = error
        for pin in reversed(pins):
            try:
                pin.close()
            except BaseException as error:
                failure = error
        if failure is not None:
            raise failure
    check_deadline(deadline)
    return result


def main():
    """Print one safe PATH line only after genuine Mac smoke and all final fences."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("parent", type=Path)
    options = parser.parse_args()
    try:
        require(
            sys.platform == "darwin" and sys.version_info >= (3, 13),
            "Native private setup requires macOS CPython >= 3.13",
        )
        selection = prepare(options.parent)
    except Exception as failure:
        message = "Private CPython setup refused; PATH was not selected"
        # Only fixed internal literals can select bounded codes. Never stringify
        # arbitrary exceptions, paths, secondary arguments or mutable payloads.
        if type(failure) is ValueError and len(failure.args) == 1 and type(failure.args[0]) is str:
            reason = REFUSAL_CODES.get(failure.args[0])
            if reason is not None:
                message += " (reason=" + reason + ")"
        print(message, file=sys.stderr)
        return 1
    print(selection)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
