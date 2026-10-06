# tools/build/remap_runtime_artifact.py
"""Prepare only retained unsigned ordinary snapshots; never grant native authority."""

from contextlib import contextmanager
from dataclasses import dataclass
import math
import os
from pathlib import Path, PurePosixPath
import stat
import time

MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_MEMBERS = 2048
_PRODUCTS = (
    (
        "core",
        "src/apps/CoreService/build/Release/ErgoptiPlus-Remap-Core.app",
        "Runtime/ErgoptiPlus-Remap-Core.app",
        "Contents/MacOS/ErgoptiPlus-Remap-Core",
    ),
    (
        "console",
        "src/apps/ConsoleUserServer/build/Release/ErgoptiPlus-Remap-Console.app",
        "Runtime/ErgoptiPlus-Remap-Console.app",
        "Contents/MacOS/ErgoptiPlus-Remap-Console",
    ),
    (
        "cli",
        "src/bin/cli/build/Release/ergoptiplus_remap_cli",
        "Runtime/bin/ergoptiplus_remap_cli",
        ".",
    ),
)
_MACHO_MAGIC = frozenset(
    bytes.fromhex(value)
    for value in (
        "feedface",
        "cefaedfe",
        "feedfacf",
        "cffaedfe",
        "cafebabe",
        "bebafeca",
        "cafebabf",
        "bfbafeca",
    )
)
_NESTED_CODE = (".app", ".framework", ".xpc", ".appex", ".bundle", ".dylib", ".so")


class ArtifactRefusal(Exception):
    """An unsigned snapshot failed a finite ordinary custody boundary."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _require(condition, code):
    if not condition:
        raise ArtifactRefusal(code)


def _deadline(deadline):
    _require(
        type(deadline) in (int, float)
        and 0 < deadline < 10**20
        and math.isfinite(deadline)
        and time.monotonic() < deadline,
        "deadline",
    )


def _identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _stable(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode)


@dataclass(frozen=True, slots=True)
class OwnerSnapshot:
    """Retain a stable original private directory incarnation."""

    path: Path
    identity: tuple[int, int, int, int]


@dataclass(frozen=True, slots=True)
class DirectoryObservation:
    """A detached directory observation, not an open descriptor capability."""

    path: str
    identity: tuple[int, ...]
    mode: int


@dataclass(frozen=True, slots=True)
class FileObservation:
    """Retain original bytes and their actually opened ordinary incarnation."""

    path: str
    identity: tuple[int, ...]
    mode: int
    data: bytes


@dataclass(frozen=True, slots=True)
class ShippingSnapshot:
    """Complete ordinary inventory from one fixed source; native status is absent."""

    target: str
    stage: Path
    stage_identity: tuple
    source: Path
    ancestors: tuple[DirectoryObservation, ...]
    directories: tuple[DirectoryObservation, ...]
    files: tuple[FileObservation, ...]


@dataclass(frozen=True, slots=True)
class PreparationOutcome:
    """Finite completed unsigned snapshot; all native qualification is false."""

    status: str
    root: Path
    products: tuple[str, str, str]
    signing_qualified: bool
    installation_qualified: bool
    native_build_qualified: bool


class _OneUse:
    """Consume one lexical handoff, including exceptional and caught nested entry."""

    def __init__(self):
        self._state = "unused"
        self._reentered = False

    @contextmanager
    def claim(self):
        if self._state == "active":
            self._reentered = True
            raise ArtifactRefusal("reentered")
        _require(self._state == "unused", "handoff_required")
        self._state = "active"
        try:
            yield
            _require(not self._reentered, "reentered")
        finally:
            self._state = "used"


def _path(path):
    path = Path(path)
    try:
        _require(path.is_absolute() and path.resolve(strict=True) == path, "unsafe_path")
        info = path.lstat()
    except OSError as error:
        raise ArtifactRefusal("unsafe_path") from error
    _require(info.st_uid == os.getuid(), "unsafe_path")
    return path, info


def _directory(path, mode=None):
    path, info = _path(path)
    _require(stat.S_ISDIR(info.st_mode), "unsafe_path")
    _require(not stat.S_IMODE(info.st_mode) & 0o7022, "unsafe_path")
    if mode is not None:
        _require(stat.S_IMODE(info.st_mode) == mode, "unsafe_path")
    return path, info


def capture_owner(owner, deadline):
    """Capture the original current-UID canonical mode-0700 owner before work."""
    _deadline(deadline)
    path, info = _directory(owner, 0o700)
    return OwnerSnapshot(path, _stable(info))


def _current_owner(snapshot, deadline):
    _deadline(deadline)
    _require(type(snapshot) is OwnerSnapshot, "inventory")
    try:
        current = capture_owner(snapshot.path, deadline)
    except ArtifactRefusal as error:
        if error.code == "unsafe_path":
            raise ArtifactRefusal("identity_changed") from error
        raise
    _require(current == snapshot, "identity_changed")


def _relative(value):
    _require(type(value) is str and value and value != ".", "unsafe_path")
    try:
        encoded = value.encode("utf-8", "strict")
        parts = PurePosixPath(value).parts
    except (UnicodeError, ValueError) as error:
        raise ArtifactRefusal("unsafe_path") from error
    _require(
        len(encoded) <= 1024
        and not PurePosixPath(value).is_absolute()
        and str(PurePosixPath(value)) == value
        and all(part not in ("", ".", "..") and len(part.encode("utf-8")) <= 255 for part in parts)
        and not any(ord(character) < 32 or ord(character) == 127 for character in value),
        "unsafe_path",
    )
    return value


def _validate_bounds(member_count, total_bytes, largest_file_bytes):
    """Check closed integer capacity without allocating or granting authority."""
    _require(
        type(member_count) is int
        and 0 <= member_count <= MAX_MEMBERS
        and type(total_bytes) is int
        and 0 <= total_bytes <= MAX_TOTAL_BYTES
        and type(largest_file_bytes) is int
        and 0 <= largest_file_bytes <= MAX_FILE_BYTES,
        "inventory",
    )


def _read(path, expected, deadline):
    _deadline(deadline)
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened = os.fstat(descriptor)
        _require(_identity(opened) == _identity(expected), "identity_changed")
        chunks, remaining = [], opened.st_size
        while remaining:
            _deadline(deadline)
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            _require(chunk, "identity_changed")
            chunks.append(chunk)
            remaining -= len(chunk)
        _require(not os.read(descriptor, 1), "identity_changed")
        _, selected = _path(path)
        _require(
            _identity(os.fstat(descriptor)) == _identity(selected) == _identity(opened),
            "identity_changed",
        )
        data = b"".join(chunks)
    except OSError as error:
        raise ArtifactRefusal("consumer_failed") from error
    finally:
        if descriptor is not None:
            # Never retry an uncertain close against a possibly reused descriptor.
            closing, descriptor = descriptor, None
            try:
                os.close(closing)
            except OSError as error:
                raise ArtifactRefusal("consumer_failed") from error
    _deadline(deadline)
    return data


def capture_shipping(
    target,
    stage,
    deadline,
    *,
    remaining_members=MAX_MEMBERS,
    remaining_bytes=MAX_TOTAL_BYTES,
):
    """Capture bounded complete fixed inventory from actual ordinary source bytes."""
    _deadline(deadline)
    _require(type(target) is str and target in {row[0] for row in _PRODUCTS}, "inventory")
    _validate_bounds(remaining_members, remaining_bytes, 0)
    stage, stage_info = _directory(stage)
    _, relative, _, primary = next(row for row in _PRODUCTS if row[0] == target)
    source = stage / relative
    ancestors = []
    current = stage
    for part in PurePosixPath(relative).parts[:-1]:
        current /= part
        _, info = _directory(current)
        ancestors.append(
            DirectoryObservation(
                str(current.relative_to(stage)),
                _stable(info),
                stat.S_IMODE(info.st_mode),
            )
        )
    directories, files = [], []
    total, largest = 0, 0

    def capture(path, member):
        nonlocal total, largest
        _deadline(deadline)
        if member != ".":
            _relative(member)
            _require(not path.name.lower().endswith(_NESTED_CODE), "inventory")
        _, info = _path(path)
        mode = stat.S_IMODE(info.st_mode)
        count = len(directories) + len(files) + 1
        _require(count <= remaining_members, "inventory")
        if stat.S_ISDIR(info.st_mode):
            _require(target != "cli" and mode == 0o755, "unsafe_path")
            directories.append(DirectoryObservation(member, _identity(info), mode))
            try:
                with os.scandir(path) as entries:
                    names = []
                    for entry in entries:
                        _deadline(deadline)
                        _require(
                            len(names) + len(directories) + len(files) < remaining_members,
                            "inventory",
                        )
                        names.append(entry.name)
                for name in sorted(names):
                    capture(path / name, name if member == "." else member + "/" + name)
            except OSError as error:
                raise ArtifactRefusal("unsafe_path") from error
        else:
            _require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "unsafe_path")
            _require(member == primary or not mode & 0o111, "inventory")
            _require(mode == (0o755 if member == primary else 0o644), "unsafe_path")
            prospective = total + info.st_size
            _validate_bounds(count, prospective, max(largest, info.st_size))
            _require(prospective <= remaining_bytes, "inventory")
            data = _read(path, info, deadline)
            _require(member == primary or data[:4] not in _MACHO_MAGIC, "inventory")
            files.append(FileObservation(member, _identity(info), mode, data))
            total, largest = prospective, max(largest, info.st_size)

    capture(source, ".")
    required = {primary} if target == "cli" else {primary, "Contents/Info.plist"}
    _require(required <= {row.path for row in files}, "inventory")
    for row in directories:
        path = source if row.path == "." else source / row.path
        _, info = _directory(path, row.mode)
        _require(_identity(info) == row.identity, "identity_changed")
    _require(_stable(_directory(stage)[1]) == _stable(stage_info), "identity_changed")
    for row in ancestors:
        _require(_stable(_directory(stage / row.path)[1]) == row.identity, "identity_changed")
    _deadline(deadline)
    return ShippingSnapshot(
        target,
        stage,
        _stable(stage_info),
        source,
        tuple(ancestors),
        tuple(sorted(directories, key=lambda row: row.path)),
        tuple(sorted(files, key=lambda row: row.path)),
    )


def current_shipping(snapshot, deadline):
    """Compare a complete bounded recut with the original retained incarnation."""
    _require(type(snapshot) is ShippingSnapshot, "inventory")
    try:
        current = capture_shipping(snapshot.target, snapshot.stage, deadline)
    except ArtifactRefusal as error:
        if error.code in ("inventory", "unsafe_path"):
            raise ArtifactRefusal("identity_changed") from error
        raise
    _require(current == snapshot, "identity_changed")


def prepare_unsigned(owner_snapshot, snapshots, deadline, guard):
    """Copy only original retained bytes into one exclusive private unsigned layout."""
    _require(type(guard) is _OneUse, "handoff_required")
    with guard.claim():
        _deadline(deadline)
        _require(
            type(snapshots) is tuple
            and len(snapshots) == 3
            and all(type(row) is ShippingSnapshot for row in snapshots)
            and tuple(row.target for row in snapshots) == ("core", "console", "cli"),
            "inventory",
        )
        _current_owner(owner_snapshot, deadline)
        _require(
            all(owner_snapshot.path in row.stage.parents for row in snapshots)
            and len({row.stage for row in snapshots}) == 1,
            "unsafe_path",
        )
        _validate_bounds(
            sum(len(row.directories) + len(row.files) for row in snapshots),
            sum(len(file.data) for row in snapshots for file in row.files),
            max(len(file.data) for row in snapshots for file in row.files),
        )
        root = owner_snapshot.path / ".unsigned-runtime-preparation"
        created_directories, completed_files = {}, {}
        root_identity = None

        def boundary():
            _current_owner(owner_snapshot, deadline)
            for snapshot in snapshots:
                current_shipping(snapshot, deadline)
            if root_identity is not None:
                _require(
                    _stable(_directory(root, 0o700)[1]) == root_identity,
                    "identity_changed",
                )
                for relative, identity in created_directories.items():
                    _require(
                        _stable(_directory(root / relative, 0o755)[1]) == identity,
                        "identity_changed",
                    )
                for relative, observation in completed_files.items():
                    path, info = _path(root / relative)
                    _require(_identity(info) == observation.identity, "identity_changed")
                    _require(
                        _read(path, info, deadline) == observation.data,
                        "identity_changed",
                    )
            _deadline(deadline)

        boundary()
        try:
            root.mkdir(mode=0o700)
        except OSError as error:
            raise ArtifactRefusal("unsafe_path") from error
        root_identity = _stable(_directory(root, 0o700)[1])
        boundary()
        planned_directories = {"Runtime", "Runtime/bin"}
        planned_files = {}
        for snapshot, (_, _, destination, _) in zip(snapshots, _PRODUCTS, strict=True):
            for directory in snapshot.directories:
                planned_directories.add(
                    destination if directory.path == "." else destination + "/" + directory.path
                )
            for file in snapshot.files:
                relative = destination if file.path == "." else destination + "/" + file.path
                planned_files[relative] = file
        for relative in sorted(planned_directories, key=lambda value: (value.count("/"), value)):
            boundary()
            path = root / relative
            descriptor = None
            try:
                path.mkdir(mode=0o700)
                _, selected = _directory(path, 0o700)
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
                _require(
                    _identity(os.fstat(descriptor)) == _identity(selected),
                    "identity_changed",
                )
                os.fchmod(descriptor, 0o755)
                _require(
                    _identity(os.fstat(descriptor)) == _identity(path.lstat()),
                    "identity_changed",
                )
            except OSError as error:
                raise ArtifactRefusal("consumer_failed") from error
            finally:
                if descriptor is not None:
                    closing, descriptor = descriptor, None
                    try:
                        os.close(closing)
                    except OSError as error:
                        raise ArtifactRefusal("consumer_failed") from error
            created_directories[relative] = _stable(_directory(path, 0o755)[1])
            boundary()
        for relative, original in sorted(planned_files.items()):
            boundary()
            path = root / relative
            descriptor, parent_descriptor = None, None
            try:
                parent, parent_info = _directory(path.parent, 0o755)
                parent_descriptor = os.open(parent, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
                _require(
                    _identity(os.fstat(parent_descriptor)) == _identity(parent_info),
                    "identity_changed",
                )
                boundary()
                descriptor = os.open(
                    path.name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    original.mode,
                    dir_fd=parent_descriptor,
                )
                opened = os.fstat(descriptor)
                _, selected = _path(path)
                _require(_identity(selected) == _identity(opened), "identity_changed")
                boundary()
                _require(
                    stat.S_ISREG(opened.st_mode)
                    and opened.st_nlink == 1
                    and opened.st_uid == os.getuid(),
                    "unsafe_path",
                )
                os.fchmod(descriptor, original.mode)
                opened = os.fstat(descriptor)
                _require(stat.S_IMODE(opened.st_mode) == original.mode, "unsafe_path")
                offset = 0
                while offset < len(original.data):
                    boundary()
                    count = os.write(descriptor, original.data[offset : offset + 1024 * 1024])
                    _require(
                        type(count) is int
                        and 0 < count <= min(1024 * 1024, len(original.data) - offset),
                        "consumer_failed",
                    )
                    offset += count
                    boundary()
                completed = os.fstat(descriptor)
                _require(
                    _stable(completed) == _stable(opened)
                    and completed.st_size == len(original.data),
                    "identity_changed",
                )
                _, selected = _path(path)
                _require(_identity(selected) == _identity(completed), "identity_changed")
            except OSError as error:
                raise ArtifactRefusal("consumer_failed") from error
            finally:
                try:
                    if descriptor is not None:
                        closing, descriptor = descriptor, None
                        try:
                            os.close(closing)
                        except OSError as error:
                            raise ArtifactRefusal("consumer_failed") from error
                finally:
                    if parent_descriptor is not None:
                        closing, parent_descriptor = parent_descriptor, None
                        try:
                            os.close(closing)
                        except OSError as error:
                            raise ArtifactRefusal("consumer_failed") from error
            completed_files[relative] = FileObservation(
                relative, _identity(completed), original.mode, original.data
            )
            boundary()
        boundary()
        actual_directories, actual_files = set(), set()
        pending = [root]
        try:
            while pending:
                _deadline(deadline)
                directory = pending.pop()
                with os.scandir(directory) as entries:
                    while True:
                        _deadline(deadline)
                        try:
                            entry = next(entries)
                        except StopIteration:
                            break
                        relative = str((directory / entry.name).relative_to(root))
                        _relative(relative)
                        _require(
                            relative in planned_directories or relative in planned_files,
                            "identity_changed",
                        )
                        _require(
                            len(actual_directories) + len(actual_files) < MAX_MEMBERS + 2,
                            "inventory",
                        )
                        path = directory / entry.name
                        if relative in planned_directories:
                            _directory(path, 0o755)
                            actual_directories.add(relative)
                            pending.append(path)
                        else:
                            _, info = _path(path)
                            _require(stat.S_ISREG(info.st_mode), "identity_changed")
                            actual_files.add(relative)
        except OSError as error:
            raise ArtifactRefusal("consumer_failed") from error
        _require(
            actual_directories == planned_directories and actual_files == set(planned_files),
            "identity_changed",
        )
        boundary()
        return PreparationOutcome(
            "prepared_unsigned_snapshot",
            root,
            tuple(row[2] for row in _PRODUCTS),
            False,
            False,
            False,
        )
