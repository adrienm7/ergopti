# tools/diagnostics/installed_vhd_acl_ci.py
"""Own one diagnostic-only Darwin ACL sample without modifying native ancestors.

The external workflow invokes this caller before its unchanged Swift pipeline.
Portable controls are explicit endpoint models; an actual successful caller
must retire its direct native guardians before admitting their terminal facts.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import types

ROOT = Path(__file__).resolve().parent
SUCCESS_SECONDS = 25
WORKER_SECONDS = 30
OBSERVER_SECONDS = 35
RETIRE_SECONDS = 10
MAX_BYTES = 16_384


def require(condition, message):
    """Keep refusal checks effective under optimized Python."""
    if not condition:
        raise ValueError(message)


def check_deadline(deadline):
    require(time.monotonic() < deadline, "ACL caller absolute deadline exhausted")


def source_paths():
    """Return fixed current inputs; the caller accepts no external source identity."""
    return {
        "caller": ROOT / "installed_vhd_acl_ci.py",
        "test": ROOT / "installed_vhd_ci_fixture_test.py",
        "controller": ROOT / "installed_vhd_ci_fixture.py",
        "observer": ROOT / "installed-vhd-acl-ancestry.c",
        "guardian": ROOT / "macos_owned_process.py",
    }


def identity(info):
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


def read_input(path, maximum, *, source=True):
    """Read a current fixed source or genuine toolchain image without aliases."""
    path = Path(path)
    require(
        path.is_absolute() and path.parent.resolve(strict=True) == path.parent,
        "Caller input parent alias refused",
    )
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(
            stat.S_ISREG(before.st_mode)
            and 0 < before.st_size <= maximum
            and (not source or before.st_uid == os.geteuid() and before.st_nlink == 1)
            and not before.st_mode & 0o022,
            "Caller ordinary input owner refused",
        )
        data = bytearray()
        while len(data) <= maximum:
            part = os.read(fd, min(65536, maximum + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(fd)
        require(
            identity(before) == identity(after)
            and identity(os.stat(path, follow_symlinks=False)) == identity(after)
            and len(data) == before.st_size,
            "Caller input changed while reading",
        )
        return bytes(data), identity(after)
    finally:
        os.close(fd)


def load_captured(name, data, path, deadline):
    """Execute the exact captured byte body without CWD import or bytecode lookup."""
    check_deadline(deadline)
    module = types.ModuleType(name)
    module.__file__ = str(path)
    exec(compile(data, str(path), "exec"), module.__dict__)
    check_deadline(deadline)
    return module


def persist(path, packet):
    """Retain a bounded classification; the file is never process-completion authority."""
    data = (json.dumps(packet, allow_nan=False, sort_keys=True) + "\n").encode()
    require(0 < len(data) <= MAX_BYTES, "Caller diagnostic size refused")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def run(parent):
    """Return one actual retired-process ancestry classification and its retained root."""
    require(sys.platform == "darwin", "Native ACL caller requires macOS")
    started = time.monotonic()
    deadline = started + SUCCESS_SECONDS
    paths = source_paths()
    captured = {}
    for key, path in paths.items():
        check_deadline(deadline)
        captured[key] = read_input(path, 1024 * 1024)
        check_deadline(deadline)
    hashes = {key: hashlib.sha256(data).hexdigest() for key, (data, _) in captured.items()}
    runtime = Path(sys.executable).resolve(strict=True)
    runtime_before = read_input(runtime, 64 * 1024 * 1024, source=False)
    check_deadline(deadline)
    parent = Path(parent)
    require(parent.is_absolute(), "Caller evidence parent must be absolute")
    parent = parent.resolve(strict=True)
    parent_before = parent.stat()
    require(
        stat.S_ISDIR(parent_before.st_mode)
        and parent_before.st_uid == os.geteuid()
        and not parent_before.st_mode & 0o022,
        "Caller evidence parent owner refused",
    )
    root = Path(tempfile.mkdtemp(prefix="acl-ancestry-", dir=parent)).resolve(strict=True)
    root_before = root.stat()
    require(stat.S_IMODE(root_before.st_mode) == 0o700, "Caller root must be private")
    staged = root / "source"
    staged.mkdir(mode=0o700)
    staged_before = staged.stat()
    staged_paths = {}
    for key, (data, _) in captured.items():
        path = staged / paths[key].name
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        staged_paths[key] = path

    def directory_current(path, before):
        now = path.stat()
        require(
            path.resolve(strict=True) == path
            and stat.S_ISDIR(now.st_mode)
            and (now.st_dev, now.st_ino, now.st_mode, now.st_uid, now.st_gid)
            == (before.st_dev, before.st_ino, before.st_mode, before.st_uid, before.st_gid),
            "Caller directory identity changed",
        )

    def unchanged():
        check_deadline(deadline)
        directory_current(parent, parent_before)
        directory_current(root, root_before)
        directory_current(staged, staged_before)
        require(
            {path.name for path in staged.iterdir()}
            == {path.name for path in staged_paths.values()},
            "Caller staged input inventory changed",
        )
        for key, path in paths.items():
            require(read_input(path, 1024 * 1024) == captured[key], "Caller current source changed")
            require(
                read_input(staged_paths[key], 1024 * 1024)[0] == captured[key][0],
                "Caller staged source changed",
            )
        require(
            read_input(runtime, 64 * 1024 * 1024, source=False) == runtime_before,
            "Caller current interpreter changed",
        )
        check_deadline(deadline)

    unchanged()
    worker = load_captured(
        "acl_caller_worker", captured["controller"][0], staged_paths["controller"], deadline
    )
    unchanged()
    owner = load_captured(
        "acl_caller_guardian", captured["guardian"][0], staged_paths["guardian"], deadline
    )
    unchanged()
    native = owner.NativeProcessGroups()
    unchanged()
    previous = {}

    def interrupted(_signum, _frame):
        raise owner.OwnedProcessInterrupted("ACL caller interrupted")

    def execute(arguments, name):
        unchanged()
        retained = []

        def register(group):
            retained.append(group)

        output_path = root / (name + ".stdout")
        error_path = root / (name + ".stderr")
        output_fd = os.open(
            output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
        )
        with os.fdopen(output_fd, "wb") as output:
            error_fd = os.open(
                error_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
            with os.fdopen(error_fd, "wb") as errors:
                try:
                    owner.acquire_owned(arguments, native, register, stdout=output, stderr=errors)
                    require(len(retained) == 1, "Caller acquisition registration refused")
                    unchanged()
                    retained[0].wait_for_exit(min(OBSERVER_SECONDS, deadline - time.monotonic()))
                finally:
                    if retained:
                        retirement_started = time.monotonic()
                        cleanup_handlers = {}
                        try:
                            for sig in (signal.SIGTERM, signal.SIGINT):
                                cleanup_handlers[sig] = signal.signal(sig, signal.SIG_IGN)
                            closed = retained[0].settle(timeout=3)
                        finally:
                            for sig, handler in cleanup_handlers.items():
                                signal.signal(sig, handler)
                        require(
                            closed is True
                            and time.monotonic() - retirement_started < RETIRE_SECONDS
                            and retained[0].reaped is True
                            and retained[0].reservation_lost is False,
                            "Caller native retirement debt remains",
                        )
        unchanged()
        group = retained[0]
        require(
            type(group.process.returncode) is int and group.process.returncode == 0,
            "Actual caller child status refused",
        )
        return group

    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous[sig] = signal.signal(sig, interrupted)
        for name, optimized in (("normal", False), ("optimized", True)):
            arguments = [str(runtime), "-I", "-B"]
            if optimized:
                arguments.append("-O")
            arguments.extend(
                [
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    str(staged),
                    "-p",
                    "installed_vhd_ci_fixture_test.py",
                ]
            )
            execute(arguments, name)
            output = (root / (name + ".stdout")).stat()
            require(output.st_size == 0, "Portable controls emitted unexpected stdout")
            transcript = worker.ordinary_bytes(root / (name + ".stderr"), MAX_BYTES).decode("utf-8")
            require(
                re.search(r"(?m)^Ran 22 tests in [0-9.]+s$", transcript) is not None
                and re.search(r"(?m)^OK$", transcript) is not None
                and not re.search(r"(?i)skip|FAIL|ERROR", transcript),
                "Portable 22-control completion refused",
            )
            unchanged()
        probe = root / "probe"
        probe.mkdir(mode=0o700)
        terminal_path = root / "guardian-terminal.json"
        guardian = execute(
            [
                str(runtime),
                "-I",
                "-B",
                str(staged_paths["guardian"]),
                "run",
                str(terminal_path),
                str(WORKER_SECONDS),
                "--",
                str(runtime),
                "-I",
                "-B",
                str(staged_paths["controller"]),
                str(probe),
            ],
            "guardian",
        )
        unchanged()
        terminal = worker.read_record(terminal_path)
        packet = worker.read_record(probe / "acl-ancestry.json")
        require(
            type(terminal) is dict and type(terminal.get("worker_pid")) is int,
            "Caller worker identity absent",
        )
        classification = worker.admit(
            packet,
            terminal,
            guardian_pid=guardian.process.pid,
            guardian_status=guardian.process.returncode,
            worker_pid=terminal["worker_pid"],
            completed=guardian.reaped is True and guardian.reservation_lost is False,
            expected_sources={key: hashes[key] for key in worker.SOURCES},
            deadline=deadline,
        )
        unchanged()
        elapsed = time.monotonic() - started
        require(0 <= elapsed < SUCCESS_SECONDS and math.isfinite(elapsed), "Caller elapsed refused")
        record = {
            "schema": 1,
            "kind": "acl_ancestry_ci",
            "status": "observed",
            "classification": classification,
            "authority": False,
            "guardian_pid": guardian.process.pid,
            "worker_pid": terminal["worker_pid"],
            "source_hashes": hashes,
            "elapsed_seconds": elapsed,
        }
        persist(root / "ci-classification.json", record)
        unchanged()
        require(
            worker.read_record(root / "ci-classification.json") == record,
            "Persisted caller classification changed",
        )
        unchanged()
        return root, record
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("parent", type=Path)
    options = parser.parse_args()
    try:
        acquired_root, summary = run(options.parent)
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError):
        print("Read-only ACL caller refused; evidence retained", file=sys.stderr)
        raise SystemExit(1) from None
    print(
        json.dumps(
            {
                "classification": summary["classification"],
                "authority": False,
                "diagnostic_root": str(acquired_root),
            },
            sort_keys=True,
        )
    )
