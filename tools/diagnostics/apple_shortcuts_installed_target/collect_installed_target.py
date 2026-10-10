"""Collect bounded installed metadata through the unchanged original Darwin owner."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
import types

from installed_target_reader import MetadataRefused, read_bundle, resolution_path

DEPENDENCIES = {
    "tools/diagnostics/macos_owned_process.py": "9b985af7e8bf549cb843b289885a2bea38a67ea3ce44defaf389dab1001fef98",
    "tools/diagnostics/apple_shortcuts_probe/run_probe.py": "eeb75f1686a4fb50e85e9e79e8a632f344c4e19d756fab7f5e086237520ab257",
}


def digest(path, maximum=65536):
    """Hash a bounded receiving dependency, refusing a final symlink."""
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
        raise MetadataRefused("source_refused")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def directory_identity(info):
    """Bind the named directory, allowing only content changes inside that inode."""
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)


def file_identity(info):
    """Capture replacement and in-place source changes before any execution."""
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


class RetainedDirectory:
    """Keep no-follow ancestor descriptors and exact named-entry identities."""

    def __init__(self, path):
        path = Path(path).absolute()
        parts = str(path).split("/")[1:]
        if any(part in ("", ".", "..") or "\x00" in part for part in parts):
            raise MetadataRefused("directory_path")
        self.descriptors = []
        self.edges = []
        try:
            fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            self.descriptors.append(fd)
            self.root_identity = directory_identity(os.fstat(fd))
            for name in parts:
                parent = fd
                fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                self.descriptors.append(fd)
                self.edges.append((parent, name, fd, directory_identity(os.fstat(fd))))
            self.fd = fd
            self.check()
        except BaseException:
            self.close()
            raise

    def check(self):
        """Refuse a moved/replaced ancestor before accepting or publishing bytes."""
        if directory_identity(os.fstat(self.descriptors[0])) != self.root_identity:
            raise MetadataRefused("directory_replaced")
        for parent, name, fd, expected in self.edges:
            if (
                directory_identity(os.fstat(fd)) != expected
                or directory_identity(os.stat(name, dir_fd=parent, follow_symlinks=False))
                != expected
            ):
                raise MetadataRefused("directory_replaced")

    def close(self):
        """Release only the descriptors opened by this exact receiver."""
        pending = None
        descriptors, self.descriptors = self.descriptors, []
        for fd in reversed(descriptors):
            try:
                os.close(fd)
            except BaseException as error:
                if pending is None:
                    pending = error
        if pending is not None:
            raise pending


def retained_source(path):
    """Return the validated bytes actually read, without a second path loader."""
    path = Path(path).absolute()
    directory = RetainedDirectory(path.parent)
    fd = None
    pending = None
    try:
        directory.check()
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory.fd)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 65536:
            raise MetadataRefused("source_refused")
        raw = bytearray()
        while len(raw) <= 65536:
            piece = os.read(fd, min(8192, 65537 - len(raw)))
            if not piece:
                break
            raw.extend(piece)
        expected = file_identity(before)
        if (
            len(raw) != before.st_size
            or len(raw) > 65536
            or file_identity(os.fstat(fd)) != expected
            or file_identity(os.stat(path.name, dir_fd=directory.fd, follow_symlinks=False))
            != expected
        ):
            raise MetadataRefused("source_changed")
        directory.check()
        return bytes(raw)
    except BaseException as error:
        pending = error
        raise
    finally:
        cleanup = None
        if fd is not None:
            try:
                os.close(fd)
            except BaseException as error:
                cleanup = error
        try:
            directory.close()
        except BaseException as error:
            if cleanup is None:
                cleanup = error
        if cleanup is not None and pending is None:
            raise cleanup


def load_original(root, relative, name):
    """Execute only retained validated source bytes; never reopen or load a pyc."""
    path = root / relative
    raw = retained_source(path)
    if hashlib.sha256(raw).hexdigest() != DEPENDENCIES[relative]:
        raise MetadataRefused("source_refused")
    code = compile(raw, str(path), "exec", dont_inherit=True)
    module = types.ModuleType(name)
    module.__file__ = str(path)
    module.__package__ = ""
    module.__loader__ = None
    module.__cached__ = None
    module.__spec__ = None
    exec(code, module.__dict__)
    return module


class OwnedOutput:
    """Publish only into a retained newly created directory with a current name."""

    def __init__(self, path):
        path = Path(path).absolute()
        if path.name in ("", ".", "..") or "\x00" in path.name:
            raise MetadataRefused("output_path")
        self.directory = RetainedDirectory(path.parent)
        self.fd = None
        self.name = path.name
        try:
            self.directory.check()
            os.mkdir(self.name, mode=0o700, dir_fd=self.directory.fd)
            self.fd = os.open(
                self.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.directory.fd
            )
            self.identity = directory_identity(os.fstat(self.fd))
            self.check()
        except BaseException:
            self.close()
            raise

    def check(self):
        """Join the original private directory to its still-current public name."""
        self.directory.check()
        if (
            directory_identity(os.fstat(self.fd)) != self.identity
            or directory_identity(
                os.stat(self.name, dir_fd=self.directory.fd, follow_symlinks=False)
            )
            != self.identity
        ):
            raise MetadataRefused("output_replaced")

    def write(self, name, raw):
        """Write exclusive bounded bytes through the held directory, then rejoin."""
        if name not in ("Info.plist.source", "dictionary.source", "observation.json"):
            raise MetadataRefused("output_name")
        if type(raw) is not bytes or not 0 < len(raw) <= 65536:
            raise MetadataRefused("output_bound")
        self.check()
        fd = os.open(
            name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd
        )
        try:
            before = os.fstat(fd)
            with os.fdopen(fd, "wb", closefd=False) as output:
                output.write(raw)
                output.flush()
            after = os.fstat(fd)
            named = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            if (
                directory_identity(after) != directory_identity(before)
                or file_identity(named) != file_identity(after)
                or after.st_size != len(raw)
            ):
                raise MetadataRefused("output_changed")
            self.check()
        finally:
            os.close(fd)

    def close(self):
        """Close the original output handles even if one close refuses."""
        pending = None
        if self.fd is not None:
            fd, self.fd = self.fd, None
            try:
                os.close(fd)
            except BaseException as error:
                pending = error
        try:
            self.directory.close()
        except BaseException as error:
            if pending is None:
                pending = error
        if pending is not None:
            raise pending


def finish_observation(output, packet, pending):
    """A best-effort secondary receipt must not replace native cancellation/debt."""
    secondary = None
    try:
        raw = (json.dumps(packet, sort_keys=True, separators=(",", ":")) + "\n").encode()
        output.write("observation.json", raw)
    except BaseException as error:
        secondary = error
    try:
        output.close()
    except BaseException as error:
        if secondary is None:
            secondary = error
    if pending is not None:
        raise pending
    if secondary is not None:
        raise secondary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--resolver", type=Path, required=True)
    parser.add_argument("--resolver-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or sys.version_info < (3, 13):
        raise MetadataRefused("native_unavailable")
    if not re.fullmatch(r"[0-9a-f]{64}", args.resolver_sha256):
        raise MetadataRefused("resolver_source")
    binary = args.resolver.absolute()
    info = binary.lstat()
    # The build receipt must independently bind this binary to the Swift source.
    # A supplied digest is artifact integrity, not native/principal qualification.
    if (
        not stat.S_ISREG(info.st_mode)
        or not info.st_mode & 0o111
        or info.st_size > 16777216
        or hashlib.sha256(binary.read_bytes()).hexdigest() != args.resolver_sha256
    ):
        raise MetadataRefused("resolver_source")
    root = args.source_root.absolute()
    ownership = load_original(root, "tools/diagnostics/macos_owned_process.py", "installed_owner")
    probe = load_original(
        root, "tools/diagnostics/apple_shortcuts_probe/run_probe.py", "installed_capture"
    )

    def interrupted(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("collector_interrupted")

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    output = OwnedOutput(args.output)
    operations = []
    packet = {
        "schema": 1,
        "status": "refused",
        "reason": "metadata_refused",
        "catalogue_observed": False,
        "permission_observed": False,
        "invocation_qualified": False,
        "running_target_observed": False,
        "physical_operations": operations,
        "source_hashes": DEPENDENCIES,
        "resolver_sha256": args.resolver_sha256,
    }
    failed = True
    pending = None
    try:
        native = ownership.NativeProcessGroups()
        # The native role uses the original owner/caps/20s acquisition budget.
        # Metadata reads must also finish before this original outer deadline.
        deadline = time.monotonic() + 20
        raw = probe.capture([str(binary)], native, ownership, operations, "installed_target")
        receipt, info_raw, dictionary_raw = read_bundle(resolution_path(raw), deadline)
        for relative, expected in DEPENDENCIES.items():
            if hashlib.sha256(retained_source(root / relative)).hexdigest() != expected:
                raise MetadataRefused("source_refused")
        if digest(binary, 16777216) != args.resolver_sha256:
            raise MetadataRefused("resolver_source")
        if time.monotonic() >= deadline:
            raise MetadataRefused("deadline")
        output.write("Info.plist.source", info_raw)
        output.write("dictionary.source", dictionary_raw)
        packet.update({"status": "metadata_observed", "reason": "none", "metadata": receipt})
        failed = False
    except MetadataRefused as error:
        packet["reason"] = str(error)
    except probe.ProbeObservationRefused as error:
        packet["reason"] = error.kind
    except BaseException as error:
        # Never suppress original cancellation or process retirement refusal.
        packet["reason"] = "capture_refused"
        pending = error
    finally:
        finish_observation(output, packet, pending)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
