# tools/diagnostics/installed_vhd_static_fixture.py
"""Collect bounded raw native package observations without admitting package trust.

Despite the future fixture-oriented name, this first stage never expands a
payload, creates protected fixtures, executes installer scripts, or approves a
driver. Actual native grammar must be acquired and reviewed before admission.
"""

import argparse
import base64
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import types

ROOT = Path(__file__).resolve().parent
SUCCESS_SECONDS = 25
OBSERVER_SECONDS = 35
RETIRE_SECONDS = 10
RAW_BYTES = 131_072
MAX_PACKET = 131_072
PACKAGES = {
    "8.4.0": (2_090_417, "8e6c433f4e3aaa0403f6f3c72849cfcd054d52d83b53d7408771ade54f1d49a1"),
    "8.5.0": (2_089_117, "d73d6d9428f0f80b87b8a8ba8a1031f2cbc3bc1fa6b74842d1f1b764b2916fc9"),
    "8.6.0": (2_089_875, "ff8c7fdc5e25387c7805fc7509a0fa9cf98f69ba582704f717fddcae47424387"),
}
TOOLS = {"curl": Path("/usr/bin/curl"), "pkgutil": Path("/usr/sbin/pkgutil")}


def require(condition, message):
    """Retain policy refusals when Python optimization is inherited."""
    if not condition:
        raise ValueError(message)


def check(deadline):
    require(time.monotonic() < deadline, "Raw package acquisition deadline exhausted")


def load_policy(deadline):
    """Bootstrap the existing policy from exact current bytes, without CWD imports."""
    check(deadline)
    path = ROOT / "installed_vhd_acl_ci.py"
    require(
        path.is_absolute() and path.parent.resolve(strict=True) == path.parent,
        "Policy alias refused",
    )
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.geteuid()
            and before.st_nlink == 1
            and 0 < before.st_size < 1_048_576
            and not before.st_mode & 0o022,
            "Policy source owner refused",
        )
        body = bytearray()
        while len(body) <= 1_048_576:
            part = os.read(descriptor, min(65_536, 1_048_577 - len(body)))
            if not part:
                break
            body.extend(part)
        after = os.fstat(descriptor)

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

        require(
            identity(before) == identity(after)
            and identity(after) == identity(os.stat(path, follow_symlinks=False)),
            "Policy changed during capture",
        )
        require(len(body) == before.st_size, "Policy body changed")
    finally:
        os.close(descriptor)
    check(deadline)
    policy = types.ModuleType("installed_vhd_raw_policy")
    policy.__file__ = str(path)
    exec(compile(bytes(body), str(path), "exec"), policy.__dict__)
    check(deadline)
    policy.__source_capture__ = bytes(body), identity(after)
    require(
        policy.read_input(path, 1_048_576) == policy.__source_capture__,
        "Policy bootstrap body changed",
    )
    return policy


def raw_file(policy, path):
    """Read one current owned raw stream, including a genuinely empty stream."""
    require(path.parent.resolve(strict=True) == path.parent, "Raw stream parent alias refused")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.geteuid()
            and before.st_nlink == 1
            and 0 <= before.st_size <= RAW_BYTES
            and not before.st_mode & 0o022,
            "Raw stream owner or bound refused",
        )
        data = bytearray()
        while len(data) <= RAW_BYTES:
            part = os.read(descriptor, min(65_536, RAW_BYTES + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(descriptor)
        require(
            policy.identity(before) == policy.identity(after)
            and policy.identity(after) == policy.identity(os.stat(path, follow_symlinks=False))
            and len(data) == before.st_size,
            "Raw stream changed",
        )
        return bytes(data), policy.identity(after)
    finally:
        os.close(descriptor)


def package_name(version):
    return "Karabiner-DriverKit-VirtualHIDDevice-" + version + ".pkg"


def package_url(version):
    return (
        "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v"
        + version
        + "/"
        + package_name(version)
    )


def observe(parent, packages=None, *, log_public_pkgutil=False):
    """Return genuine retired-child raw evidence; package trust stays UNKNOWN."""
    require(sys.platform == "darwin", "Raw native package acquisition requires macOS")
    require(os.geteuid() != 0, "Raw package acquisition requires an ordinary caller")
    require(type(log_public_pkgutil) is bool, "Public transcript opt-in must be boolean")
    require(
        not log_public_pkgutil or packages is None,
        "Public transcript requires fixed official acquisition",
    )
    deadline = time.monotonic() + SUCCESS_SECONDS
    started = deadline - SUCCESS_SECONDS
    policy = load_policy(deadline)
    paths = {
        "collector": ROOT / "installed_vhd_static_fixture.py",
        "policy": ROOT / "installed_vhd_acl_ci.py",
        "guardian": ROOT / "macos_owned_process.py",
    }
    captured = {name: policy.read_input(path, 1_048_576) for name, path in paths.items()}
    require(captured["policy"] == policy.__source_capture__, "Executed policy source lease changed")
    check(deadline)
    tool_paths = {name: path.resolve(strict=True) for name, path in TOOLS.items()}
    tool_paths["python"] = Path(sys.executable).resolve(strict=True)
    images = {
        name: policy.read_input(path, 67_108_864, source=False) for name, path in tool_paths.items()
    }
    for name, (_, information) in images.items():
        require(
            (name == "python" or information[3] == 0) and not information[2] & 0o6000,
            "Native system image owner refused",
        )
    check(deadline)
    with contextlib.ExitStack() as directories:
        return collect_owned(
            parent,
            packages,
            deadline,
            started,
            policy,
            paths,
            captured,
            tool_paths,
            images,
            directories,
            log_public_pkgutil,
        )


def collect_owned(
    parent,
    packages,
    deadline,
    started,
    policy,
    paths,
    captured,
    tool_paths,
    images,
    directories,
    log_public_pkgutil=False,
):
    """Keep exact ordinary evidence directories retained through native closure."""

    def retain_directory(path):
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            directories.callback(os.close, descriptor)
        except BaseException:
            os.close(descriptor)
            raise
        held, named = os.fstat(descriptor), os.stat(path, follow_symlinks=False)
        require(
            stat.S_ISDIR(held.st_mode)
            and (held.st_dev, held.st_ino, held.st_mode, held.st_uid, held.st_gid)
            == (named.st_dev, named.st_ino, named.st_mode, named.st_uid, named.st_gid),
            "Raw directory acquisition changed",
        )
        return held, descriptor

    parent = Path(parent)
    require(parent.is_absolute(), "Raw evidence parent must be absolute")
    parent = parent.resolve(strict=True)
    parent_before, parent_descriptor = retain_directory(parent)
    require(
        stat.S_ISDIR(parent_before.st_mode)
        and parent_before.st_uid == os.geteuid()
        and not parent_before.st_mode & 0o022,
        "Raw evidence parent owner refused",
    )
    root = Path(tempfile.mkdtemp(prefix="vhd-raw-", dir=parent)).resolve(strict=True)
    root_before, root_descriptor = retain_directory(root)
    require(stat.S_IMODE(root_before.st_mode) == 0o700, "Raw evidence root must be private")
    artifact_root = root / "packages"
    artifact_root.mkdir(mode=0o700)
    artifact_before, artifact_descriptor = retain_directory(artifact_root)
    owner = policy.load_captured(
        "vhd_raw_guardian", captured["guardian"][0], paths["guardian"], deadline
    )
    native = owner.NativeProcessGroups()
    accepted_packages, external_packages, streams = {}, {}, {}
    children = []
    previous = {}

    def directory_current(path, before, descriptor):
        after = os.stat(path, follow_symlinks=False)
        held = os.fstat(descriptor)
        require(
            path.resolve(strict=True) == path
            and stat.S_ISDIR(after.st_mode)
            and (before.st_dev, before.st_ino, before.st_mode, before.st_uid, before.st_gid)
            == (after.st_dev, after.st_ino, after.st_mode, after.st_uid, after.st_gid)
            == (held.st_dev, held.st_ino, held.st_mode, held.st_uid, held.st_gid),
            "Raw evidence directory changed",
        )

    def current():
        check(deadline)
        directory_current(parent, parent_before, parent_descriptor)
        directory_current(root, root_before, root_descriptor)
        directory_current(artifact_root, artifact_before, artifact_descriptor)
        for name, path in paths.items():
            require(
                policy.read_input(path, 1_048_576) == captured[name], "Raw current source changed"
            )
        for name, path in tool_paths.items():
            require(
                policy.read_input(path, 67_108_864, source=False) == images[name],
                "Raw native image changed",
            )
        for path, before in external_packages.items():
            require(policy.read_input(path, 4_194_304) == before, "Raw provided artifact changed")
        for path, before in accepted_packages.items():
            require(policy.read_input(path, 4_194_304) == before, "Raw pinned artifact changed")
        if len(accepted_packages) == len(PACKAGES):
            require(
                {path.name for path in artifact_root.iterdir()}
                == {path.name for path in accepted_packages},
                "Raw package inventory changed",
            )
        for path, before in streams.items():
            require(raw_file(policy, path) == before, "Raw completed stream changed")
        check(deadline)

    def interrupted(_signum, _frame):
        raise owner.OwnedProcessInterrupted("Raw package acquisition interrupted")

    def execute(arguments, label):
        current()
        retained = [None]

        def register(group):
            retained[0] = group

        output_path, error_path = root / (label + ".stdout"), root / (label + ".stderr")
        out_fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(out_fd, "wb") as output:
            err_fd = os.open(
                error_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
            with os.fdopen(err_fd, "wb") as errors:
                try:
                    owner.acquire_owned(arguments, native, register, stdout=output, stderr=errors)
                    require(retained[0] is not None, "Raw child owner absent")
                    current()
                    retained[0].wait_for_exit(min(OBSERVER_SECONDS, deadline - time.monotonic()))
                finally:
                    if retained[0] is not None:
                        retirement_started = time.monotonic()
                        cleanup_handlers = {}
                        try:
                            for signum in (signal.SIGTERM, signal.SIGINT):
                                cleanup_handlers[signum] = signal.signal(signum, signal.SIG_IGN)
                            closed = retained[0].settle(timeout=3)
                        finally:
                            for signum, handler in cleanup_handlers.items():
                                signal.signal(signum, handler)
                        require(
                            closed is True
                            and time.monotonic() - retirement_started < RETIRE_SECONDS
                            and retained[0].reaped is True
                            and retained[0].reservation_lost is False,
                            "Raw child retirement debt remains",
                        )
        current()
        group = retained[0]
        require(type(group.process.returncode) is int, "Raw actual child status missing")
        require(
            type(group.process.pid) is int and group.process.pid > 0,
            "Raw actual child identity missing",
        )
        for path in (output_path, error_path):
            streams[path] = raw_file(policy, path)
        current()
        record = {
            "operation": label,
            "worker_pid": group.process.pid,
            "group_id": group.process.pid,
            "closed": True,
            "exit_status": group.process.returncode,
            "streams": [
                {
                    "file": path.name,
                    "bytes": len(streams[path][0]),
                    "sha256": hashlib.sha256(streams[path][0]).hexdigest(),
                }
                for path in (output_path, error_path)
            ],
            "escaped_sessions_managed": False,
        }
        children.append(record)
        return record

    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous[signum] = signal.signal(signum, interrupted)
        current()
        for version, (size, digest) in PACKAGES.items():
            destination = artifact_root / package_name(version)
            fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as output:
                initial = os.fstat(output.fileno())
                if packages is not None:
                    source = Path(packages) / package_name(version)
                    body, information = policy.read_input(source, 4_194_304)
                    require(
                        len(body) == size and hashlib.sha256(body).hexdigest() == digest,
                        "Provided fixed artifact pin refused",
                    )
                    external_packages[source] = body, information
                    output.write(body)
                    output.flush()
                    os.fsync(output.fileno())
            if packages is None:
                remaining = deadline - time.monotonic()
                check(deadline)
                child = execute(
                    [
                        str(tool_paths["curl"]),
                        "--silent",
                        "--show-error",
                        "--fail",
                        "--location",
                        "--proto",
                        "=https",
                        "--proto-redir",
                        "=https",
                        "--connect-timeout",
                        "10",
                        "--max-time",
                        str(remaining),
                        "--max-filesize",
                        str(size),
                        "--output",
                        str(destination),
                        package_url(version),
                    ],
                    "download-" + version,
                )
                require(child["exit_status"] == 0, "Actual fixed artifact download failed")
            after = destination.stat()
            require(
                (
                    initial.st_dev,
                    initial.st_ino,
                    initial.st_mode,
                    initial.st_uid,
                    initial.st_gid,
                    initial.st_nlink,
                )
                == (
                    after.st_dev,
                    after.st_ino,
                    after.st_mode,
                    after.st_uid,
                    after.st_gid,
                    after.st_nlink,
                ),
                "Raw package destination replaced",
            )
            body, information = policy.read_input(destination, 4_194_304)
            require(
                len(body) == size and hashlib.sha256(body).hexdigest() == digest,
                "Actual fixed artifact pin refused",
            )
            accepted_packages[destination] = body, information
            current()
        require(
            {path.name for path in artifact_root.iterdir()}
            == {path.name for path in accepted_packages},
            "Raw package inventory changed",
        )
        execute([str(tool_paths["pkgutil"]), "--help"], "pkgutil-help")
        for version in PACKAGES:
            execute(
                [
                    str(tool_paths["pkgutil"]),
                    "--check-signature",
                    str(artifact_root / package_name(version)),
                ],
                "pkgutil-signature-" + version,
            )
        current()
        elapsed = time.monotonic() - started
        require(
            math.isfinite(elapsed) and 0 <= elapsed < SUCCESS_SECONDS, "Raw elapsed time refused"
        )
        record = {
            "schema": 1,
            "kind": "installed_vhd_raw_package_observations",
            "status": "observed_raw",
            "trust": "unknown",
            "authority": False,
            "reference_qualified": False,
            "collector_pid": os.getpid(),
            "source_hashes": {
                name: hashlib.sha256(body).hexdigest() for name, (body, _) in captured.items()
            },
            "image_hashes": {
                name: hashlib.sha256(body).hexdigest() for name, (body, _) in images.items()
            },
            "packages": [
                {"version": version, "bytes": size, "sha256": digest}
                for version, (size, digest) in PACKAGES.items()
            ],
            "children": children,
            "native_commands_failed": sum(child["exit_status"] != 0 for child in children),
            "elapsed_seconds": elapsed,
        }
        if log_public_pkgutil:
            record["public_pkgutil_streams"] = public_pkgutil_streams(record, streams, root)
        data = (json.dumps(record, allow_nan=False, sort_keys=True) + "\n").encode()
        require(0 < len(data) <= MAX_PACKET, "Raw summary size refused")
        path = root / "raw-observations.json"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        current()
        require(policy.read_input(path, MAX_PACKET)[0] == data, "Raw persisted summary changed")
        current()
        return root, record
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def public_pkgutil_streams(record, streams, root):
    """Encode only completed fixed public tool streams, without opening a path."""
    operations = ["pkgutil-help"] + ["pkgutil-signature-" + version for version in PACKAGES]
    children = record["children"][-len(operations) :]
    require(
        [child["operation"] for child in children] == operations
        and all(child["closed"] is True for child in children)
        and record["trust"] == "unknown"
        and record["authority"] is False
        and record["reference_qualified"] is False,
        "Public fixed observations refused",
    )
    observations = []
    for operation, child in zip(operations, children):
        channels = []
        for channel in ("stdout", "stderr"):
            name = operation + "." + channel
            body = streams[root / name][0]
            digest = hashlib.sha256(body).hexdigest()
            channels.append(
                {
                    "channel": channel,
                    "bytes": len(body),
                    "sha256": digest,
                    "base64": base64.b64encode(body).decode("ascii"),
                }
            )
        require(
            child["streams"]
            == [
                {
                    "file": operation + "." + channel["channel"],
                    "bytes": channel["bytes"],
                    "sha256": channel["sha256"],
                }
                for channel in channels
            ],
            "Public completed stream metadata changed",
        )
        observations.append(
            {"operation": operation, "exit_status": child["exit_status"], "streams": channels}
        )
    return {
        "schema": 1,
        "kind": "installed_vhd_public_pkgutil_streams",
        "trust": "unknown",
        "authority": False,
        "reference_qualified": False,
        "source_hashes": record["source_hashes"],
        "image_hashes": record["image_hashes"],
        "packages": record["packages"],
        "operations": observations,
    }


def public_pkgutil_log(record):
    """Frame a bounded exact envelope so raw tool text cannot control CI logs."""
    body = json.dumps(
        record["public_pkgutil_streams"],
        allow_nan=False,
        sort_keys=True,
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("ascii")
    require(0 < len(body) <= MAX_PACKET, "Public transcript size refused")
    chunks = [body[index : index + 3072] for index in range(0, len(body), 3072)]
    digest = hashlib.sha256(body).hexdigest()
    lines = [
        json.dumps(
            {
                "kind": "installed_vhd_public_pkgutil_chunk",
                "schema": 1,
                "index": index,
                "count": len(chunks),
                "bytes": len(body),
                "sha256": digest,
                "base64": base64.b64encode(chunk).decode("ascii"),
            },
            sort_keys=True,
        )
        + "\n"
        for index, chunk in enumerate(chunks, 1)
    ]
    result = "".join(lines)
    require(len(result.encode("ascii")) <= MAX_PACKET, "Public framed transcript size refused")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("parent", type=Path)
    parser.add_argument("--packages", type=Path)
    parser.add_argument("--log-public-pkgutil", action="store_true")
    options = parser.parse_args()
    try:
        if options.log_public_pkgutil:
            evidence, packet = observe(options.parent, options.packages, log_public_pkgutil=True)
            public_log = public_pkgutil_log(packet)
        else:
            evidence, packet = observe(options.parent, options.packages)
            public_log = ""
        output = (
            json.dumps(
                {
                    "trust": "unknown",
                    "authority": False,
                    "diagnostic_root": str(evidence),
                    "native_commands_failed": packet["native_commands_failed"],
                },
                sort_keys=True,
            )
            + "\n"
            + public_log
        )
        if options.log_public_pkgutil:
            require(len(output.encode("utf-8")) <= MAX_PACKET, "Public CLI transcript size refused")
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError):
        print("Raw VHD package acquisition refused; evidence retained", file=sys.stderr)
        raise SystemExit(1) from None
    print(output, end="")
