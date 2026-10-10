# _shared/python/managed_source_alias.py
"""Retained filesystem authority for one source-bound optional runtime alias."""

import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import stat


class AliasRefusal(Exception):
    """Fixed lexical errors retain distinct primary and physical cleanup debt."""

    def __init__(self, reason, *, primary=None, cleanup=None):
        super().__init__(reason)
        self.primary = primary
        self.cleanup = cleanup


def decimal(value, maximum, *, positive=False):
    if (
        type(value) is not str
        or re.fullmatch(r"0|[1-9][0-9]*", value) is None
        or len(value) > 20
        or int(value) > maximum
        or (positive and int(value) == 0)
    ):
        raise AliasRefusal("admission")
    return int(value)


def proof_fields(value):
    names = {
        "version",
        "nonce",
        "directory_device",
        "directory_inode",
        "ancestor_device",
        "ancestor_inode",
        "lease_device",
        "lease_inode",
        "binary_sha256",
    }
    if (
        type(value) is not dict
        or set(value) != names
        or type(value["version"]) is not int
        or value["version"] != 1
        or type(value["nonce"]) is not str
        or re.fullmatch(r"[a-f0-9]{32}", value["nonce"]) is None
        or type(value["binary_sha256"]) is not str
        or re.fullmatch(r"[a-f0-9]{64}", value["binary_sha256"]) is None
    ):
        raise AliasRefusal("admission")
    for stem in ("directory", "ancestor", "lease"):
        decimal(value[stem + "_device"], 2**32 - 1)
        decimal(value[stem + "_inode"], 2**64 - 1, positive=True)
    return dict(value)


def vnode(value):
    return value.st_dev, value.st_ino


def unchanged(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


class AliasContext:
    """Hold exact source, alias and private namespace FDs through native admission.

    The original session supplies source identity; the catalogue supplies SHA256.
    This context never derives authority from UI metadata or changes runtime bytes.
    """

    def __init__(self, root, proof, source_identity, fingerprint, *, progress):
        self.root = Path(root)
        self._fds = {}
        self._close_debt = None
        self._snapshots = {}
        self._chain = []
        self.progress = progress
        self.proof = proof_fields(proof)
        if type(source_identity) is not dict or set(source_identity) != {
            "device",
            "inode",
        }:
            raise AliasRefusal("admission")
        self.source = (
            decimal(source_identity["device"], 2**32 - 1),
            decimal(source_identity["inode"], 2**64 - 1, positive=True),
        )
        if fingerprint != self.proof["binary_sha256"] or not callable(progress):
            raise AliasRefusal("admission")
        self.image_name = ".ergopti-image-" + self.proof["nonce"]
        self.lease_name = ".ergopti-lease-" + self.proof["nonce"]
        self.additional_files = frozenset((self.image_name, self.lease_name + "/source.json"))
        try:
            self._acquire()
            self.validate()
        except BaseException as primary:
            try:
                self.close()
            except BaseException as cleanup:
                raise AliasRefusal("operation", primary=primary, cleanup=cleanup) from primary
            raise

    def _open(self, key, path, *, parent=None, directory=False):
        self.progress()
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
        if directory:
            flags |= os.O_DIRECTORY
        descriptor = os.open(path, flags, dir_fd=parent)
        self._fds[key] = descriptor
        observed = os.fstat(descriptor)
        if observed.st_uid != os.geteuid():
            raise AliasRefusal("admission")
        self._snapshots[key] = observed
        return descriptor, observed

    def _directory(self, key, expected=None, *, private=False):
        observed = os.fstat(self._fds[key])
        if (
            not stat.S_ISDIR(observed.st_mode)
            or observed.st_uid != os.geteuid()
            or observed.st_mode & 0o022
            or (private and stat.S_IMODE(observed.st_mode) != 0o700)
            or (expected is not None and vnode(observed) != expected)
        ):
            raise AliasRefusal("admission")
        return observed

    def _acquire(self):
        if not self.root.is_absolute():
            raise AliasRefusal("admission")
        directory, observed = self._open("directory", self.root, directory=True)
        expected = (
            int(self.proof["directory_device"]),
            int(self.proof["directory_inode"]),
        )
        self._directory("directory", expected)
        if vnode(os.stat(self.root, follow_symlinks=False)) != vnode(observed):
            raise AliasRefusal("admission")
        key, current = "directory", directory
        # An absolute named path bounds ancestor traversal; root itself never
        # admits a missing private anchor or a foreign/writable intermediate.
        for index in range(len(self.root.parts) + 1):
            held = self._directory(key)
            if stat.S_IMODE(held.st_mode) == 0o700:
                if vnode(held) != (
                    int(self.proof["ancestor_device"]),
                    int(self.proof["ancestor_inode"]),
                ):
                    raise AliasRefusal("admission")
                self._anchor = key
                break
            parent_key = "ancestor-" + str(index)
            parent, parent_stat = self._open(parent_key, "..", parent=current, directory=True)
            if vnode(parent_stat) == vnode(held):
                raise AliasRefusal("admission")
            self._chain.append((key, parent_key))
            key, current = parent_key, parent
        else:
            raise AliasRefusal("admission")
        lease, _ = self._open("lease", self.lease_name, parent=directory, directory=True)
        self._directory(
            "lease",
            (int(self.proof["lease_device"]), int(self.proof["lease_inode"])),
            private=True,
        )
        self._open("binary", "ollama", parent=directory)
        self._open("image", self.image_name, parent=directory)
        marker, observed = self._open("marker", "source.json", parent=lease)
        if (
            not stat.S_ISREG(observed.st_mode)
            or stat.S_IMODE(observed.st_mode) != 0o600
            or observed.st_nlink != 1
        ):
            raise AliasRefusal("admission")
        marker_value = self.proof | {
            "device": str(self.source[0]),
            "inode": str(self.source[1]),
        }
        self.marker_bytes = json.dumps(marker_value, sort_keys=True, separators=(",", ":")).encode()
        if os.pread(marker, len(self.marker_bytes) + 1, 0) != self.marker_bytes:
            raise AliasRefusal("admission")
        for key in ("binary", "image"):
            held = os.fstat(self._fds[key])
            if (
                not stat.S_ISREG(held.st_mode)
                or held.st_uid != os.geteuid()
                or held.st_mode & 0o022
                or not held.st_mode & 0o111
                or held.st_nlink != 2
                or vnode(held) != self.source
            ):
                raise AliasRefusal("admission")
            self._hash(key)

    def _hash(self, key):
        before = os.fstat(self._fds[key])
        digest = hashlib.sha256()
        offset = 0
        while True:
            self.progress()
            chunk = os.pread(self._fds[key], 65536, offset)
            if not chunk:
                break
            digest.update(chunk)
            offset += len(chunk)
        if unchanged(before) != unchanged(os.fstat(self._fds[key])) or not hmac.compare_digest(
            digest.hexdigest(), self.proof["binary_sha256"]
        ):
            raise AliasRefusal("admission")

    def validate(self):
        """Recheck retained objects and every corresponding named namespace edge."""
        self.progress()
        if not self._fds or self._close_debt is not None:
            raise AliasRefusal("cleanup")
        directory, lease = self._fds["directory"], self._fds["lease"]
        for key, snapshot in self._snapshots.items():
            current = os.fstat(self._fds[key])
            if key in ("binary", "image", "marker"):
                if unchanged(current) != unchanged(snapshot):
                    raise AliasRefusal("admission")
            else:
                self._directory(key, vnode(snapshot), private=key in ("lease", self._anchor))
        if vnode(os.stat(self.root, follow_symlinks=False)) != vnode(self._snapshots["directory"]):
            raise AliasRefusal("admission")
        for child, parent in self._chain:
            if vnode(os.stat("..", dir_fd=self._fds[child], follow_symlinks=False)) != vnode(
                self._snapshots[parent]
            ):
                raise AliasRefusal("admission")
        for key, name, parent in (
            ("lease", self.lease_name, directory),
            ("binary", "ollama", directory),
            ("image", self.image_name, directory),
            ("marker", "source.json", lease),
        ):
            if vnode(os.stat(name, dir_fd=parent, follow_symlinks=False)) != vnode(
                self._snapshots[key]
            ):
                raise AliasRefusal("admission")
        if set(os.listdir(lease)) != {"source.json"}:
            raise AliasRefusal("admission")
        for name in os.listdir(directory):
            if (name.startswith(".ergopti-image-") and name != self.image_name) or (
                name.startswith(".ergopti-lease-") and name != self.lease_name
            ):
                raise AliasRefusal("admission")
        if os.pread(self._fds["marker"], len(self.marker_bytes) + 1, 0) != self.marker_bytes:
            raise AliasRefusal("admission")

    def close(self):
        """Retire references before uncertain closes; never reclose a reused FD."""
        for key in tuple(self._fds):
            descriptor = self._fds.pop(key)
            try:
                os.close(descriptor)
            except BaseException as error:
                if self._close_debt is None:
                    self._close_debt = error
        if self._close_debt is not None:
            raise AliasRefusal("cleanup", cleanup=self._close_debt)

    def __enter__(self):
        return self

    def __exit__(self, kind, primary, traceback):
        if primary is None:
            try:
                self.validate()
            except BaseException as error:
                primary = error
        try:
            self.close()
        except BaseException as cleanup:
            raise AliasRefusal("operation", primary=primary, cleanup=cleanup) from primary
        if primary is not None and kind is None:
            raise primary
