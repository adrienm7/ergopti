# tools/diagnostics/installed_vhd_ci_fixture.py
"""Read-only Darwin ACL ancestry worker for the existing native guardian.

Caller: macos_owned_process.py run TERMINAL 30 -- python3 THIS PRIVATE_ROOT.
The caller keeps its existing 35-second observation and 10-second retirement
limits. This worker's observation is never its own retirement acknowledgement.
No package, root fixture, installation, driver, environment export or authority
is provisioned. A future caller must retain the actual guardian before admit().
"""

import argparse
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

MAX_BYTES = 16_384
CONTROLLER_SECONDS = 25
ROOT = Path(__file__).resolve().parent
SOURCES = {
    "controller": ROOT / "installed_vhd_ci_fixture.py",
    "observer": ROOT / "installed-vhd-acl-ancestry.c",
    "guardian": ROOT / "macos_owned_process.py",
}
IDENTITY_KEYS = {"device", "inode", "mode", "uid", "gid"}
ACL_KEYS = {
    "acquisition_attempted",
    "acquired",
    "acquire_errno",
    "valid_result",
    "valid_errno",
    "first_result",
    "first_errno",
    "entry_present",
    "free_result",
    "free_errno",
}
NODE_KEYS = {
    "role",
    "opened",
    "identity",
    "current",
    "pin_error",
    "error_code",
    "acl",
    "close_result",
    "close_errno",
}


def require(value, message):
    """Preserve refusal checks under Python optimization."""
    if not value:
        raise ValueError(message)


def integer(value, minimum=0, maximum=2**64 - 1):
    return type(value) is int and minimum <= value <= maximum


def unique_object(pairs):
    """Reject duplicate decoded fields, including escaped spellings."""
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate diagnostic field")
        result[key] = value
    return result


def finite_float(value):
    result = float(value)
    require(math.isfinite(result), "Nonfinite diagnostic number")
    return result


def decode(data):
    """Bound JSON and reject nonfinite constants before any receipt admission."""
    require(0 < len(data) <= MAX_BYTES, "Diagnostic size refused")

    def constant(_value):
        raise ValueError("Nonfinite diagnostic constant")

    value = json.loads(
        data, object_pairs_hook=unique_object, parse_float=finite_float, parse_constant=constant
    )
    require(type(value) is dict, "Diagnostic must be an object")
    return value


def ordinary_bytes(path, maximum):
    """Read a current ordinary owned inode without blocking on a special file."""
    path = Path(path)
    require(
        path.is_absolute() and path.parent.resolve(strict=True) == path.parent,
        "Diagnostic parent alias refused",
    )
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise ValueError("Diagnostic open refused") from error
    try:
        before = os.fstat(fd)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.geteuid()
            and before.st_nlink == 1
            and 0 < before.st_size <= maximum,
            "Diagnostic ordinary owner refused",
        )
        data = bytearray()
        while len(data) <= maximum:
            part = os.read(fd, min(65536, maximum + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(fd)

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
            and identity(os.stat(path, follow_symlinks=False)) == identity(after)
            and len(data) == before.st_size,
            "Diagnostic inode changed",
        )
        return bytes(data)
    finally:
        os.close(fd)


def read_record(path, maximum=MAX_BYTES):
    require(integer(maximum, 1, MAX_BYTES), "Diagnostic maximum refused")
    return decode(ordinary_bytes(Path(path), maximum))


def source_hashes():
    return {
        key: hashlib.sha256(ordinary_bytes(path, 131072)).hexdigest()
        for key, path in SOURCES.items()
    }


def check_deadline(deadline):
    require(
        (integer(deadline, 1, 2**63 - 1) or type(deadline) is float and math.isfinite(deadline))
        and time.monotonic() < deadline,
        "ACL ancestry absolute deadline exhausted",
    )


def native_state(packet):
    """Classify a typed sample; no native liveness or capture permission is inferred."""
    require(
        type(packet) is dict
        and set(packet) == {"schema", "pid", "nodes"}
        and type(packet["schema"]) is int
        and packet["schema"] == 1
        and integer(packet["pid"], 1, 2**31 - 1),
        "Native sample shape refused",
    )
    nodes = packet["nodes"]
    require(type(nodes) is list and len(nodes) == 2, "Native ancestor inventory refused")
    state = "qualified"
    for node, role in zip(nodes, ("root", "library"), strict=True):
        require(
            type(node) is dict
            and all(type(key) is str for key in node)
            and set(node) == NODE_KEYS
            and type(node["role"]) is str
            and node["role"] == role,
            "Native ancestor shape refused",
        )
        require(
            type(node["opened"]) is bool and type(node["current"]) is bool,
            "Native ancestor Boolean refused",
        )
        require(
            node["pin_error"] is None
            or type(node["pin_error"]) is str
            and node["pin_error"]
            in {"named_stat", "held_stat", "open", "identity", "wrong_type", "parent_unavailable"},
            "Native pin diagnostic refused",
        )
        require(
            node["error_code"] is None or integer(node["error_code"], 0, 2**31 - 1),
            "Native pin error refused",
        )
        identity = node["identity"]
        if identity is not None:
            require(
                type(identity) is dict
                and set(identity) == IDENTITY_KEYS
                and all(integer(value) for value in identity.values()),
                "Native identity refused",
            )
        for key in ("close_result", "close_errno"):
            value = node[key]
            require(
                value is None or integer(value, -1 if key == "close_result" else 0, 2**31 - 1),
                "Native close result refused",
            )
        acl = node["acl"]
        require(type(acl) is dict and set(acl) == ACL_KEYS, "Native ACL shape refused")
        for key in ("acquisition_attempted", "acquired"):
            require(type(acl[key]) is bool, "Native ACL Boolean refused")
        require(
            acl["entry_present"] is None or type(acl["entry_present"]) is bool,
            "Native ACL entry refused",
        )
        for key in ACL_KEYS - {"acquisition_attempted", "acquired", "entry_present"}:
            value = acl[key]
            require(
                value is None or integer(value, -1 if key.endswith("result") else 0, 2**31 - 1),
                "Native ACL integer refused",
            )
        if (
            not node["opened"]
            or not node["current"]
            or identity is None
            or node["pin_error"] is not None
            or node["close_result"] != 0
            or node["close_errno"] is None
            or node["error_code"] is not None
            or not stat.S_ISDIR(identity["mode"])
            or identity["uid"] != 0
            or identity["mode"] & 0o022
        ):
            state = "denied"
        if acl["acquired"] and acl["free_result"] != 0:
            state = "denied"
        empty = (
            acl["acquisition_attempted"]
            and acl["acquired"]
            and acl["acquire_errno"] is not None
            and acl["valid_errno"] is not None
            and acl["free_errno"] is not None
            and acl["valid_result"] == 0
            and acl["first_result"] == -1
            and acl["first_errno"] == errno.EINVAL
            and acl["entry_present"] is False
            and acl["free_result"] == 0
        )
        if not empty and state != "denied":
            state = "unknown"
    return state


def admit(
    packet,
    terminal,
    *,
    guardian_pid,
    guardian_status,
    worker_pid,
    completed,
    expected_sources,
    deadline,
):
    """Require facts held by the completed actual caller, never self-issued ACK credit."""
    check_deadline(deadline)
    require(
        completed is True
        and integer(guardian_pid, 1, 2**31 - 1)
        and integer(worker_pid, 1, 2**31 - 1)
        and type(guardian_status) is int
        and guardian_status == 0,
        "Actual guardian completion refused",
    )
    require(
        type(terminal) is dict
        and set(terminal)
        == {"schema", "guardian_pid", "worker_pid", "group_id", "closed", "exit_status"},
        "Guardian terminal inventory refused",
    )
    for key, expected in (
        ("schema", 1),
        ("guardian_pid", guardian_pid),
        ("worker_pid", worker_pid),
        ("group_id", worker_pid),
        ("exit_status", guardian_status),
    ):
        require(
            type(terminal[key]) is int and terminal[key] == expected,
            "Guardian terminal identity/status refused",
        )
    require(terminal["closed"] is True, "Guardian inherited group retirement refused")
    require(
        type(packet) is dict
        and set(packet) == {"schema", "kind", "pid", "native", "source_hashes", "elapsed_seconds"}
        and type(packet["schema"]) is int
        and packet["schema"] == 1
        and type(packet["kind"]) is str
        and packet["kind"] == "read_only_acl_ancestry"
        and type(packet["pid"]) is int
        and packet["pid"] == worker_pid,
        "Worker observation identity refused",
    )
    require(
        type(expected_sources) is dict
        and set(expected_sources) == set(SOURCES)
        and all(
            type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value)
            for value in expected_sources.values()
        )
        and type(packet["source_hashes"]) is dict
        and all(type(key) is str for key in packet["source_hashes"])
        and all(
            type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value)
            for value in packet["source_hashes"].values()
        )
        and packet["source_hashes"] == expected_sources,
        "Borrowed source identity refused",
    )
    elapsed = packet["elapsed_seconds"]
    require(
        type(elapsed) in (int, float)
        and 0 <= elapsed <= CONTROLLER_SECONDS
        and math.isfinite(elapsed),
        "Worker elapsed bound refused",
    )
    result = native_state(packet["native"])
    check_deadline(deadline)
    return result


def command(arguments, deadline):
    """Children inherit the worker's reserved PGID; the caller owns final retirement."""
    check_deadline(deadline)
    child = subprocess.Popen(
        arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    output, errors = child.communicate(timeout=deadline - time.monotonic())
    check_deadline(deadline)
    require(child.returncode == 0, "Native diagnostic command refused")
    require(
        len(output) <= MAX_BYTES and len(errors) <= MAX_BYTES,
        "Native diagnostic output bound refused",
    )
    return child.pid, output, errors


def persist(path, packet):
    """Exclusive ordinary result; a retained result never substitutes for retirement."""
    data = (json.dumps(packet, allow_nan=False, sort_keys=True) + "\n").encode()
    require(len(data) <= MAX_BYTES, "Persisted observation bound refused")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def observe(root, budget=CONTROLLER_SECONDS):
    """Collect only sampled ACL facts; the external guardian still owns this worker."""
    require(sys.platform == "darwin", "Native Darwin SDK prerequisite unavailable")
    require(
        type(budget) is int and 0 < budget <= CONTROLLER_SECONDS,
        "ACL ancestry worker budget refused",
    )
    started = time.monotonic()
    deadline = started + budget
    root = Path(root)
    require(
        root.is_absolute() and root.resolve(strict=True) == root,
        "Private diagnostic root alias refused",
    )
    before = root.stat()
    require(
        stat.S_ISDIR(before.st_mode)
        and stat.S_IMODE(before.st_mode) == 0o700
        and before.st_uid == os.geteuid(),
        "Private diagnostic root owner refused",
    )
    sources = source_hashes()
    executable = root / "acl-ancestry"
    result = root / "acl-ancestry.json"
    require(
        not executable.exists()
        and not executable.is_symlink()
        and not result.exists()
        and not result.is_symlink(),
        "Private diagnostic collision",
    )
    executable_hash = None

    def unchanged():
        check_deadline(deadline)
        current = root.stat()
        require(
            root.resolve(strict=True) == root
            and current.st_dev == before.st_dev
            and current.st_ino == before.st_ino
            and current.st_mode == before.st_mode
            and current.st_uid == before.st_uid
            and current.st_gid == before.st_gid
            and source_hashes() == sources,
            "ACL ancestry source/root changed",
        )
        if executable_hash is not None:
            require(
                hashlib.sha256(ordinary_bytes(executable, 8 * 1024 * 1024)).hexdigest()
                == executable_hash,
                "Compiled observer changed",
            )
        check_deadline(deadline)

    unchanged()
    _, output, errors = command(
        [
            "/usr/bin/xcrun",
            "clang",
            "-std=c17",
            "-D_DARWIN_C_SOURCE",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            str(SOURCES["observer"]),
            "-o",
            str(executable),
        ],
        deadline,
    )
    require(not output and not errors, "Native compilation emitted diagnostics")
    unchanged()
    executable_hash = hashlib.sha256(ordinary_bytes(executable, 8 * 1024 * 1024)).hexdigest()
    native_pid, output, errors = command([str(executable)], deadline)
    require(not errors, "Native observation emitted diagnostics")
    unchanged()
    require(
        hashlib.sha256(ordinary_bytes(executable, 8 * 1024 * 1024)).hexdigest() == executable_hash,
        "Compiled observer changed",
    )
    native = decode(output)
    native_state(native)
    require(
        type(native["pid"]) is int and native["pid"] == native_pid,
        "Actual native child identity differs",
    )
    packet = {
        "schema": 1,
        "kind": "read_only_acl_ancestry",
        "pid": os.getpid(),
        "native": native,
        "source_hashes": sources,
        "elapsed_seconds": time.monotonic() - started,
    }
    unchanged()
    persist(result, packet)
    unchanged()
    require(read_record(result) == packet, "Persisted observation changed")
    unchanged()
    return packet


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--budget", type=int, default=CONTROLLER_SECONDS)
    options = parser.parse_args()
    try:
        observe(options.root, options.budget)
    except (ValueError, OSError, subprocess.SubprocessError):
        print("Read-only ACL ancestry observation refused; inputs retained", file=sys.stderr)
        raise SystemExit(1) from None
