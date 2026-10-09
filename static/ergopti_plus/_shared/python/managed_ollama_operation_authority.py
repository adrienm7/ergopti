# _shared/python/managed_ollama_operation_authority.py
"""Retain one original operation through immutable private handoff files."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time

MAXIMUM_BYTES = 16384


class AuthorityRefusal(Exception):
    """Closed file or original-operation refusal without private data."""


def digest(value):
    return hashlib.sha256(value).hexdigest()


def decimal(value):
    if not isinstance(value, str) or re.fullmatch(r"0|[1-9][0-9]{0,19}", value) is None:
        raise AuthorityRefusal()
    result = int(value)
    if result >= 1 << 64:
        raise AuthorityRefusal()
    return result


def hexadecimal(value, length=64):
    if not isinstance(value, str) or re.fullmatch(r"[a-f0-9]{" + str(length) + "}", value) is None:
        raise AuthorityRefusal()
    return value


def nonce(value):
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9-]{36}", value) is None:
        raise AuthorityRefusal()
    return value


def exact(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise AuthorityRefusal()
    return value


def document(data):
    def pairs(items):
        result = {}
        for name, value in items:
            if name in result:
                raise AuthorityRefusal()
            result[name] = value
        return result

    try:
        if not isinstance(data, bytes) or not 0 < len(data) <= MAXIMUM_BYTES:
            raise AuthorityRefusal()
        return json.loads(
            data,
            object_pairs_hook=pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(AuthorityRefusal()),
        )
    except (UnicodeError, ValueError, TypeError):
        raise AuthorityRefusal() from None


def encoded(value):
    data = (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    ).encode("ascii")
    if len(data) > MAXIMUM_BYTES:
        raise AuthorityRefusal()
    return data


def stable(value):
    return value.st_dev, value.st_ino, value.st_uid, value.st_nlink, value.st_mode


def observation(value):
    return stable(value), value.st_size, value.st_mtime_ns, value.st_ctime_ns


def private_file(value):
    return (
        stat.S_ISREG(value.st_mode)
        and value.st_uid == os.geteuid()
        and value.st_nlink == 1
        and stat.S_IMODE(value.st_mode) == 0o600
    )


def private_directory(value):
    return (
        stat.S_ISDIR(value.st_mode)
        and value.st_uid == os.geteuid()
        and stat.S_IMODE(value.st_mode) == 0o700
    )


def reference(path, value, data=None):
    result = {
        "path": str(path),
        "device": str(value.st_dev),
        "inode": str(value.st_ino),
    }
    if data is not None:
        result["sha256"] = digest(data)
    return result


class PinnedFile:
    """Keep the originally reserved inode through one write or exact read."""

    def __init__(self, ref, *, writable=False, parent_fd=None):
        exact(
            ref,
            {"path", "device", "inode"} if writable else {"path", "device", "inode", "sha256"},
        )
        if (
            not isinstance(ref["path"], str)
            or not Path(ref["path"]).is_absolute()
            or "\0" in ref["path"]
        ):
            raise AuthorityRefusal()
        self.path = Path(ref["path"])
        self.descriptor = None
        self.parent_fd = parent_fd
        self.published = False
        self.data = b""
        device, inode = decimal(ref["device"]), decimal(ref["inode"])
        flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_NOFOLLOW | os.O_CLOEXEC
        try:
            self.descriptor = os.open(
                self.path.name if parent_fd is not None else self.path,
                flags,
                dir_fd=parent_fd,
            )
            current = os.fstat(self.descriptor)
            if not private_file(current) or (current.st_dev, current.st_ino) != (
                device,
                inode,
            ):
                raise AuthorityRefusal()
            self.expected = observation(current)
            self.fence()
            if writable:
                if current.st_size != 0:
                    raise AuthorityRefusal()
            else:
                hexadecimal(ref["sha256"])
                self.data = os.read(self.descriptor, MAXIMUM_BYTES + 1)
                self.fence()
                if (
                    len(self.data) != current.st_size
                    or len(self.data) > MAXIMUM_BYTES
                    or digest(self.data) != ref["sha256"]
                ):
                    raise AuthorityRefusal()
                self.published = True
        except BaseException:
            self.close()
            raise

    def fence(self):
        if self.descriptor is None:
            raise AuthorityRefusal()
        current = os.fstat(self.descriptor)
        named = (
            os.stat(self.path.name, dir_fd=self.parent_fd, follow_symlinks=False)
            if self.parent_fd is not None
            else self.path.lstat()
        )
        if (
            not private_file(current)
            or observation(current) != self.expected
            or observation(named) != self.expected
        ):
            raise AuthorityRefusal()

    def publish(self, value):
        if self.published:
            raise AuthorityRefusal()
        self.fence()
        data = encoded(value)
        offset = 0
        while offset < len(data):
            count = os.write(self.descriptor, data[offset:])
            if count <= 0:
                raise AuthorityRefusal()
            offset += count
        os.fsync(self.descriptor)
        current = os.fstat(self.descriptor)
        if (
            not private_file(current)
            or stable(current) != self.expected[0]
            or current.st_size != len(data)
        ):
            raise AuthorityRefusal()
        self.expected = observation(current)
        self.fence()
        self.data, self.published = data, True
        return reference(self.path, current, data)

    def ref(self):
        self.fence()
        return reference(
            self.path, os.fstat(self.descriptor), self.data if self.published else None
        )

    def close(self):
        if self.descriptor is not None:
            descriptor, self.descriptor = self.descriptor, None
            os.close(descriptor)


def source_alias(value):
    if value is None:
        return None
    exact(
        value,
        {
            "version",
            "nonce",
            "directory_device",
            "directory_inode",
            "ancestor_device",
            "ancestor_inode",
            "lease_device",
            "lease_inode",
            "binary_sha256",
        },
    )
    if type(value["version"]) is not int or value["version"] != 1:
        raise AuthorityRefusal()
    hexadecimal(value["nonce"], 32)
    hexadecimal(value["binary_sha256"])
    for field in (
        "directory_device",
        "directory_inode",
        "ancestor_device",
        "ancestor_inode",
        "lease_device",
        "lease_inode",
    ):
        number = decimal(value[field])
        if (field.endswith("_device") and number > (1 << 32) - 1) or (
            field.endswith("_inode") and number == 0
        ):
            raise AuthorityRefusal()
    return dict(value)


class OperationFiles:
    """Create private authority before POST, then seal the original cleanup clock."""

    def __init__(self, anchor_ref, original_nonce):
        self.nonce = nonce(original_nonce)
        self.anchor = PinnedFile(anchor_ref, writable=True)
        self.directory = Path(anchor_ref["path"] + ".operation")
        self.directory_fd = None
        self.authority = self.window = None
        self.bound = False
        self.sealed = False
        try:
            os.mkdir(self.directory, 0o700)
            self.directory_fd = os.open(
                self.directory,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
            self.directory_identity = stable(os.fstat(self.directory_fd))
            self.directory_fence()
            for name in ("authority.json", "window.json"):
                fd = os.open(
                    name,
                    os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600,
                    dir_fd=self.directory_fd,
                )
                try:
                    ref = reference(self.directory / name, os.fstat(fd))
                finally:
                    os.close(fd)
                target = PinnedFile(ref, writable=True, parent_fd=self.directory_fd)
                if name == "authority.json":
                    self.authority = target
                else:
                    self.window = target
        except BaseException:
            self.close()
            raise

    def directory_fence(self):
        if self.directory_fd is None:
            raise AuthorityRefusal()
        value = os.fstat(self.directory_fd)
        named = self.directory.lstat()
        if (
            not private_directory(value)
            or stable(value) != self.directory_identity
            or stable(named) != self.directory_identity
        ):
            raise AuthorityRefusal()
        if set(os.listdir(self.directory_fd)) - {"authority.json", "window.json"}:
            raise AuthorityRefusal()

    def bind(self, owner, policy, validate_session, validate_listener):
        if self.bound or not owner.admitted or owner.submitted or owner.listener is None:
            raise AuthorityRefusal()
        self.directory_fence()
        session = validate_session(dict(owner.session))
        listener = validate_listener(dict(owner.listener))
        if listener["device"] != session["device"] or listener["inode"] != session["inode"]:
            raise AuthorityRefusal()
        if (
            not isinstance(owner.executable, str)
            or not Path(owner.executable).is_absolute()
            or "\0" in owner.executable
        ):
            raise AuthorityRefusal()
        policy = dict(exact(policy, {"retirement_ms", "idle_ms", "maximum_bytes"}))
        for name in ("retirement_ms", "idle_ms", "maximum_bytes"):
            if type(policy[name]) is not int or not 1 <= policy[name] <= (
                65536 if name == "maximum_bytes" else (1 << 31) - 1
            ):
                raise AuthorityRefusal()
        alias = source_alias(getattr(owner, "source_alias", None))
        if alias is not None and alias["binary_sha256"] != session["binary_sha256"]:
            raise AuthorityRefusal()
        value = {
            "version": 1,
            "nonce": self.nonce,
            "operation": hexadecimal(owner.operation, 32),
            "executable": owner.executable,
            "session": session,
            "lease_id": digest(session["token"].encode("ascii")),
            "listener": listener,
            "source_alias": alias,
            "contract_sha256": hexadecimal(owner.contract_sha256),
            "catalogue_sha256": hexadecimal(owner.catalogue_sha256),
            "policy": policy,
        }
        self.authority_ref = self.authority.publish(value)
        self.operation = value["operation"]
        self.policy = policy
        self.bound = True

    def seal_window(self, deadline, boot):
        if not self.bound or self.sealed:
            raise AuthorityRefusal()
        started = time.monotonic_ns()
        deadline_ns = int(deadline * 1_000_000_000)
        if (
            deadline_ns <= started
            or deadline_ns - started > self.policy["retirement_ms"] * 1_000_000
        ):
            raise AuthorityRefusal()
        self.directory_fence()
        self.authority.fence()
        boot_session = boot((deadline_ns - time.monotonic_ns()) / 1_000_000_000)
        if (
            not isinstance(boot_session, str)
            or re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", boot_session) is None
        ):
            raise AuthorityRefusal()
        self.window_ref = self.window.publish(
            {
                "version": 1,
                "nonce": self.nonce,
                "operation": self.operation,
                "authority_sha256": self.authority_ref["sha256"],
                "boot_session": boot_session,
                "started_monotonic_ns": str(started),
                "deadline_monotonic_ns": str(deadline_ns),
                "retirement_ms": self.policy["retirement_ms"],
            }
        )
        self.directory_fence()
        self.anchor.publish(
            {
                "version": 1,
                "nonce": self.nonce,
                "operation": self.operation,
                "directory": reference(self.directory, os.fstat(self.directory_fd)),
                "authority": self.authority_ref,
                "window": self.window_ref,
            }
        )
        self.sealed = True

    def remove(self):
        """Close only unpublished pre-handoff files; sealed ACK ownership is Lua's."""
        if self.sealed:
            raise AuthorityRefusal()
        self.directory_fence()
        for target in (self.authority, self.window):
            target.fence()
        for target in (self.authority, self.window):
            self.directory_fence()
            target.fence()
            os.unlink(target.path.name, dir_fd=self.directory_fd)
        self.directory_fence()
        os.rmdir(self.directory)

    def close(self):
        for target in (self.authority, self.window, self.anchor):
            if target is not None:
                target.close()
        if self.directory_fd is not None:
            fd, self.directory_fd = self.directory_fd, None
            os.close(fd)


class ReadOperation:
    """Read only the task's exact anchor, never select a daemon from a directory."""

    def __init__(self, anchor_ref, original_nonce, operation, validate_session, validate_listener):
        self.anchor = PinnedFile(anchor_ref)
        self.directory_fd = None
        self.authority = self.window = None
        try:
            handoff = document(self.anchor.data)
            exact(
                handoff,
                {"version", "nonce", "operation", "directory", "authority", "window"},
            )
            if (
                type(handoff["version"]) is not int
                or handoff["version"] != 1
                or handoff["nonce"] != nonce(original_nonce)
                or handoff["operation"] != hexadecimal(operation, 32)
            ):
                raise AuthorityRefusal()
            directory = exact(handoff["directory"], {"path", "device", "inode"})
            self.directory = Path(anchor_ref["path"] + ".operation")
            if directory["path"] != str(self.directory):
                raise AuthorityRefusal()
            self.directory_fd = os.open(
                self.directory,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
            current = os.fstat(self.directory_fd)
            if not private_directory(current) or (current.st_dev, current.st_ino) != (
                decimal(directory["device"]),
                decimal(directory["inode"]),
            ):
                raise AuthorityRefusal()
            self.directory_identity = stable(current)
            if handoff["authority"]["path"] != str(self.directory / "authority.json") or handoff[
                "window"
            ]["path"] != str(self.directory / "window.json"):
                raise AuthorityRefusal()
            self.authority = PinnedFile(handoff["authority"], parent_fd=self.directory_fd)
            self.window = PinnedFile(handoff["window"], parent_fd=self.directory_fd)
            value = exact(
                document(self.authority.data),
                {
                    "version",
                    "nonce",
                    "operation",
                    "executable",
                    "session",
                    "lease_id",
                    "listener",
                    "source_alias",
                    "contract_sha256",
                    "catalogue_sha256",
                    "policy",
                },
            )
            if (
                type(value["version"]) is not int
                or value["version"] != 1
                or value["nonce"] != original_nonce
                or value["operation"] != operation
            ):
                raise AuthorityRefusal()
            if (
                not isinstance(value["executable"], str)
                or not Path(value["executable"]).is_absolute()
                or "\0" in value["executable"]
            ):
                raise AuthorityRefusal()
            value["session"] = validate_session(value["session"])
            value["listener"] = validate_listener(value["listener"])
            if value["lease_id"] != digest(value["session"]["token"].encode("ascii")) or any(
                value["listener"][name] != value["session"][name] for name in ("device", "inode")
            ):
                raise AuthorityRefusal()
            source_alias(value["source_alias"])
            if (
                value["source_alias"] is not None
                and value["source_alias"]["binary_sha256"] != value["session"]["binary_sha256"]
            ):
                raise AuthorityRefusal()
            hexadecimal(value["contract_sha256"])
            hexadecimal(value["catalogue_sha256"])
            policy = exact(value["policy"], {"retirement_ms", "idle_ms", "maximum_bytes"})
            for name in ("retirement_ms", "idle_ms", "maximum_bytes"):
                if type(policy[name]) is not int or not 1 <= policy[name] <= (
                    65536 if name == "maximum_bytes" else (1 << 31) - 1
                ):
                    raise AuthorityRefusal()
            clock = exact(
                document(self.window.data),
                {
                    "version",
                    "nonce",
                    "operation",
                    "authority_sha256",
                    "boot_session",
                    "started_monotonic_ns",
                    "deadline_monotonic_ns",
                    "retirement_ms",
                },
            )
            if (
                type(clock["version"]) is not int
                or clock["version"] != 1
                or clock["nonce"] != original_nonce
                or clock["operation"] != operation
                or clock["authority_sha256"] != handoff["authority"]["sha256"]
                or type(clock["retirement_ms"]) is not int
                or clock["retirement_ms"] != policy["retirement_ms"]
            ):
                raise AuthorityRefusal()
            started, deadline = (
                decimal(clock["started_monotonic_ns"]),
                decimal(clock["deadline_monotonic_ns"]),
            )
            if not started < deadline <= started + policy["retirement_ms"] * 1_000_000:
                raise AuthorityRefusal()
            if (
                not isinstance(clock["boot_session"], str)
                or re.fullmatch(
                    r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",
                    clock["boot_session"],
                )
                is None
            ):
                raise AuthorityRefusal()
            self.value, self.clock, self.handoff = value, clock, handoff
            self.fence()
        except BaseException:
            self.close()
            raise

    def fence(self):
        self.anchor.fence()
        current, named = os.fstat(self.directory_fd), self.directory.lstat()
        if (
            not private_directory(current)
            or stable(current) != self.directory_identity
            or stable(named) != self.directory_identity
            or set(os.listdir(self.directory_fd)) != {"authority.json", "window.json"}
        ):
            raise AuthorityRefusal()
        self.authority.fence()
        self.window.fence()

    def close(self):
        for target in (self.authority, self.window, self.anchor):
            if target is not None:
                target.close()
        if self.directory_fd is not None:
            fd, self.directory_fd = self.directory_fd, None
            os.close(fd)
