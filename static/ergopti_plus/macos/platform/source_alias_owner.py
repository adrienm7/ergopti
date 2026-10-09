# platform/source_alias_owner.py
"""Create one same-vnode source alias and retain its exact cleanup authority."""

import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import stat

SPEC = importlib.util.spec_from_file_location(
    "ergopti_source_alias_policy",
    Path(__file__).resolve().parents[2] / "_shared/python/managed_source_alias.py",
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class AliasOwner:
    """Hold private names until the bound native operation proves retirement.

    The source descriptor belongs to the caller. Acquisition happens before any
    original unlink; genuine linkat flags=0 is checked against its retained inode.
    Unknown names or uncertain close results retain explicit cleanup debt.
    """

    @classmethod
    def acquire(cls, root, retained_source, source_identity, fingerprint, *, register, progress):
        value = cls()
        value.root = Path(root)
        value.source_fd = retained_source
        value.identity = dict(source_identity)
        value.fingerprint = fingerprint
        value.progress = progress
        value.nonce = secrets.token_hex(16)
        value.image_name = ".ergopti-image-" + value.nonce
        value.lease_name = ".ergopti-lease-" + value.nonce
        value.proof = None
        value._fds = {}
        value._identities = {}
        value._created = set()
        value._close_debt = None
        value._operation = None
        value._marker_written = b""
        register(value)
        try:
            value._acquire()
            return value
        except BaseException as primary:
            try:
                value.retire()
            except BaseException as cleanup:
                raise POLICY.AliasRefusal(
                    "operation", primary=primary, cleanup=cleanup
                ) from primary
            raise

    def bind_operation(self, operation):
        """Bind before the actual start attempt; refusal cannot release live work."""
        if self._operation is not None or self.proof is None:
            raise POLICY.AliasRefusal("state")
        self._operation = operation

    def _open(self, key, name, *, parent=None, directory=False, create=False):
        self.progress()
        flags = os.O_NOFOLLOW | os.O_CLOEXEC
        flags |= os.O_RDWR | os.O_CREAT | os.O_EXCL if create else os.O_RDONLY
        if directory:
            flags |= os.O_DIRECTORY
        descriptor = os.open(name, flags, 0o600, dir_fd=parent)
        self._fds[key] = descriptor
        self._identities[key] = os.fstat(descriptor)
        return descriptor

    def _directory(self, key, *, private=False):
        value = os.fstat(self._fds[key])
        if (
            not stat.S_ISDIR(value.st_mode)
            or value.st_uid != os.geteuid()
            or value.st_mode & 0o022
            or (private and stat.S_IMODE(value.st_mode) != 0o700)
        ):
            raise POLICY.AliasRefusal("admission")
        return value

    def _source(self, *, links):
        value = os.fstat(self.source_fd)
        expected = (
            POLICY.decimal(self.identity.get("device"), 2**32 - 1),
            POLICY.decimal(self.identity.get("inode"), 2**64 - 1, positive=True),
        )
        if (
            set(self.identity) != {"device", "inode"}
            or not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.geteuid()
            or value.st_mode & 0o022
            or not value.st_mode & 0o111
            or value.st_nlink != links
            or fcntl.fcntl(self.source_fd, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY
            or POLICY.vnode(value) != expected
        ):
            raise POLICY.AliasRefusal("admission")
        return value

    def _acquire(self):
        if not self.root.is_absolute() or not callable(self.progress):
            raise POLICY.AliasRefusal("admission")
        directory = self._open("directory", self.root, directory=True)
        runtime = self._directory("directory")
        if POLICY.vnode(os.stat(self.root, follow_symlinks=False)) != POLICY.vnode(runtime):
            raise POLICY.AliasRefusal("admission")
        key = "directory"
        for index in range(len(self.root.parts) + 1):
            anchor = self._directory(key)
            if stat.S_IMODE(anchor.st_mode) == 0o700:
                break
            parent_key = "ancestor-" + str(index)
            self._open(parent_key, "..", parent=self._fds[key], directory=True)
            if POLICY.vnode(self._identities[parent_key]) == POLICY.vnode(anchor):
                raise POLICY.AliasRefusal("admission")
            key = parent_key
        else:
            raise POLICY.AliasRefusal("admission")
        original = self._source(links=1)
        named = os.stat("ollama", dir_fd=directory, follow_symlinks=False)
        if not stat.S_ISREG(named.st_mode) or POLICY.vnode(named) != POLICY.vnode(original):
            raise POLICY.AliasRefusal("admission")
        self.progress()
        os.mkdir(self.lease_name, 0o700, dir_fd=directory)
        self._created.add("lease")
        lease = self._open("lease", self.lease_name, parent=directory, directory=True)
        leased = self._directory("lease", private=True)
        self.progress()
        # This is a named link acquired while the original name still exists,
        # not an unsupported Darwin AT_EMPTY_PATH or /dev/fd execution fallback.
        os.link(
            "ollama",
            self.image_name,
            src_dir_fd=directory,
            dst_dir_fd=directory,
            follow_symlinks=False,
        )
        self._created.add("image")
        image = self._open("image", self.image_name, parent=directory)
        observed = os.fstat(image)
        original = self._source(links=2)
        if POLICY.vnode(observed) != POLICY.vnode(original):
            raise POLICY.AliasRefusal("admission")
        digest = hashlib.sha256()
        offset = 0
        while True:
            self.progress()
            chunk = os.pread(image, 65536, offset)
            if not chunk:
                break
            digest.update(chunk)
            offset += len(chunk)
        if (
            POLICY.unchanged(observed) != POLICY.unchanged(os.fstat(image))
            or digest.hexdigest() != self.fingerprint
        ):
            raise POLICY.AliasRefusal("admission")
        self.proof = POLICY.proof_fields(
            {
                "version": 1,
                "nonce": self.nonce,
                "binary_sha256": self.fingerprint,
                "directory_device": str(runtime.st_dev),
                "directory_inode": str(runtime.st_ino),
                "ancestor_device": str(anchor.st_dev),
                "ancestor_inode": str(anchor.st_ino),
                "lease_device": str(leased.st_dev),
                "lease_inode": str(leased.st_ino),
            }
        )
        marker = self._open("marker", "source.json", parent=lease, create=True)
        self._created.add("marker")
        payload = json.dumps(
            self.proof | self.identity, sort_keys=True, separators=(",", ":")
        ).encode()
        offset = 0
        while offset < len(payload):
            self.progress()
            count = os.write(marker, payload[offset:])
            if count <= 0:
                raise POLICY.AliasRefusal("file")
            offset += count
            self._marker_written = payload[:offset]
        os.fsync(marker)
        with self.context():
            pass

    @property
    def executable(self):
        """The physical alias spelling retains the runtime's genuine dylib layout."""
        if self.proof is None:
            raise POLICY.AliasRefusal("state")
        return self.root.resolve(strict=True) / self.image_name

    def context(self):
        return POLICY.AliasContext(
            self.root, self.proof, self.identity, self.fingerprint, progress=self.progress
        )

    def _same_name(self, key, name, parent):
        if key not in self._fds:
            raise POLICY.AliasRefusal("cleanup")
        held = os.fstat(self._fds[key])
        named = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if POLICY.vnode(held) != POLICY.vnode(self._identities[key]) or POLICY.vnode(
            named
        ) != POLICY.vnode(held):
            raise POLICY.AliasRefusal("cleanup")

    def _close(self, key):
        if key not in self._fds:
            return
        descriptor = self._fds.pop(key)
        try:
            os.close(descriptor)
        except BaseException as error:
            if self._close_debt is None:
                self._close_debt = error

    def retire(self):
        """Only exact bound-operation physical retirement permits name deletion."""
        if self._operation is not None and self._operation.physically_retired is not True:
            raise POLICY.AliasRefusal("cleanup")
        directory = self._fds.get("directory")
        if "image" in self._created:
            self._same_name("image", self.image_name, directory)
        if "lease" in self._created:
            self._same_name("lease", self.lease_name, directory)
        if "marker" in self._created:
            self._same_name("marker", "source.json", self._fds["lease"])
            if (
                os.pread(self._fds["marker"], len(self._marker_written) + 1, 0)
                != self._marker_written
            ):
                raise POLICY.AliasRefusal("cleanup")
            os.unlink("source.json", dir_fd=self._fds["lease"])
            self._created.remove("marker")
            self._close("marker")
        if "lease" in self._created:
            os.rmdir(self.lease_name, dir_fd=directory)
            self._created.remove("lease")
        if "image" in self._created:
            os.unlink(self.image_name, dir_fd=directory)
            self._created.remove("image")
        for key in tuple(self._fds):
            self._close(key)
        if self._close_debt is not None:
            raise POLICY.AliasRefusal("cleanup", cleanup=self._close_debt)
