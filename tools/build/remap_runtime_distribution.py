# tools/build/remap_runtime_distribution.py
"""Encode one bounded TEST-ONLY container; never mint production or runtime authority."""

from dataclasses import dataclass
import gzip
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import threading
import time

MAX_MEMBERS = 2054
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_PROVENANCE_BYTES = 4 * 1024 * 1024
_PRODUCTS = (
    "Runtime/ErgoptiPlus-Remap-Core.app",
    "Runtime/ErgoptiPlus-Remap-Console.app",
    "Runtime/bin/ergoptiplus_remap_cli",
)
_PRIMARIES = frozenset(
    (
        _PRODUCTS[0] + "/Contents/MacOS/ErgoptiPlus-Remap-Core",
        _PRODUCTS[1] + "/Contents/MacOS/ErgoptiPlus-Remap-Console",
        _PRODUCTS[2],
    )
)
_CODE_MAGIC = frozenset(
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
_DENIED_SUFFIXES = (
    ".p12",
    ".pem",
    ".keychain",
    ".keychain-db",
    ".log",
    ".dylib",
    ".so",
    ".a",
    ".pkg",
)
_active = {}
_lock = threading.RLock()


class DistributionRefusal(Exception):
    """A finite ordinary export failed; earlier native facts are not erased."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _require(value, code):
    if not value:
        raise DistributionRefusal(code)


def _tick(deadline):
    _require(
        type(deadline) in (int, float)
        and math.isfinite(deadline)
        and 0 < deadline < 10**20
        and time.monotonic() < deadline,
        "deadline",
    )


def _stamp(info):
    return info.st_dev, info.st_ino, info.st_uid, info.st_mode


def _file_stamp(info):
    return _stamp(info) + (info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _name(value, code):
    _require(
        type(value) is str
        and 0 < len(value) <= 255
        and re.fullmatch(r"[A-Za-z0-9_.+/-]+", value) is not None
        and not value.startswith("/")
        and str(PurePosixPath(value)) == value
        and all(part not in ("", ".", "..") for part in value.split("/")),
        code,
    )
    return value


def _hash(value, count, code):
    _require(
        type(value) is str and re.fullmatch(r"[A-Fa-f0-9]{" + str(count) + r"}", value) is not None,
        code,
    )


def _provenance(value):
    code = "provenance"
    _require(
        type(value) is dict
        and set(value)
        == {
            "schema",
            "scope",
            "test_only",
            "pins",
            "identity",
            "sources",
            "native_observations",
            "shipping_qualified",
            "installation_qualified",
            "authentication_qualified",
        },
        code,
    )
    _require(
        type(value["schema"]) is int
        and value["schema"] == 1
        and value["scope"] == "captured_live_export_inputs"
        and value["test_only"] is True
        and all(
            value[field] is False
            for field in (
                "shipping_qualified",
                "installation_qualified",
                "authentication_qualified",
            )
        ),
        code,
    )
    pins = value["pins"]
    _require(type(pins) is dict and set(pins) == {"upstream", "cpm", "vhd"}, code)
    for pin in pins.values():
        _hash(pin, 40, code)
    identity = value["identity"]
    _require(
        type(identity) is dict and set(identity) == {"certificate_sha1", "public_leaf_sha256"}, code
    )
    _hash(identity["certificate_sha1"], 40, code)
    _hash(identity["public_leaf_sha256"], 64, code)
    sources = value["sources"]
    _require(
        type(sources) is dict and set(sources) == {"owned_inputs", "staged_inputs", "staged_links"},
        code,
    )
    for category in ("owned_inputs", "staged_inputs", "staged_links"):
        rows = sources[category]
        _require(
            type(rows) is list
            and len(rows) <= 5000
            and (category == "staged_links" or len(rows) > 0),
            code,
        )
        seen = set()
        for row in rows:
            _require(type(row) is dict and set(row) == {"path", "bytes", "sha256"}, code)
            path = _name(row["path"], code)
            _require(
                path not in seen
                and type(row["bytes"]) is int
                and 0 <= row["bytes"] <= MAX_FILE_BYTES,
                code,
            )
            seen.add(path)
            _hash(row["sha256"], 64, code)
    rows = value["native_observations"]
    _require(type(rows) is list and len(rows) == 3, code)
    _require(
        {row.get("phase") for row in rows if type(row) is dict}
        == {"xcode_version", "xcodegen_version", "sdk_path"},
        code,
    )
    for row in rows:
        _require(
            type(row) is dict
            and set(row)
            == {
                "phase",
                "stdout_bytes",
                "stdout_sha256",
                "stderr_bytes",
                "stderr_sha256",
            },
            code,
        )
        for stream in ("stdout", "stderr"):
            _require(
                type(row[stream + "_bytes"]) is int and 0 <= row[stream + "_bytes"] <= 65536, code
            )
            _hash(row[stream + "_sha256"], 64, code)
        _require(row["stdout_bytes"] > 0, code)
    try:
        data = (
            json.dumps(
                value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
            ).encode()
            + b"\n"
        )
    except (ValueError, TypeError, UnicodeError) as error:
        raise DistributionRefusal(code) from error
    _require(len(data) <= MAX_PROVENANCE_BYTES, code)
    return data


def _members(directories, files):
    code = "inventory"
    _require(
        type(directories) is tuple
        and type(files) is tuple
        and 0 < len(directories) + len(files) <= MAX_MEMBERS,
        code,
    )
    directory_map, file_map, total = {}, {}, 0
    for row in directories:
        _require(type(row) is tuple and len(row) == 2, code)
        name, mode = row
        _name(name, code)
        _require(
            type(mode) is int
            and mode == 0o755
            and name not in directory_map
            and (
                name in ("Runtime", "Runtime/bin")
                or any(
                    name == product or name.startswith(product + "/Contents")
                    for product in _PRODUCTS[:2]
                )
            ),
            code,
        )
        directory_map[name] = mode
    for row in files:
        _require(type(row) is tuple and len(row) == 3, code)
        name, mode, data = row
        _name(name, code)
        _require(
            name not in file_map
            and name not in directory_map
            and type(data) is bytes
            and len(data) <= MAX_FILE_BYTES
            and type(mode) is int
            and (
                name == _PRODUCTS[2]
                or any(name.startswith(product + "/Contents/") for product in _PRODUCTS[:2])
            )
            and mode == (0o755 if name in _PRIMARIES else 0o644)
            and not name.endswith(_DENIED_SUFFIXES)
            and (name in _PRIMARIES or data[:4] not in _CODE_MAGIC),
            code,
        )
        _require(str(PurePosixPath(name).parent) in directory_map, code)
        total += len(data)
        _require(total <= MAX_TOTAL_BYTES, code)
        file_map[name] = (mode, data)
    required = set(_PRIMARIES)
    for product in _PRODUCTS[:2]:
        required.update(
            (product + "/Contents/Info.plist", product + "/Contents/_CodeSignature/CodeResources")
        )
    _require(required <= set(file_map) and {"Runtime", "Runtime/bin"} <= set(directory_map), code)
    for name in directory_map:
        _require(name == "Runtime" or str(PurePosixPath(name).parent) in directory_map, code)
    # USTAR has separate finite name/prefix fields; reject unsupported shapes
    # before allocating output rather than relying on a later serializer error.
    for name in tuple(directory_map) + tuple(file_map):
        try:
            tarfile.TarInfo(name).tobuf(
                format=tarfile.USTAR_FORMAT, encoding="ascii", errors="strict"
            )
        except (ValueError, UnicodeError) as error:
            raise DistributionRefusal(code) from error
    return directory_map, file_map


@dataclass(frozen=True, slots=True)
class DistributionOutcome:
    """Retain ordinary TEST-ONLY container paths; every production capability is false."""

    root: Path
    status: str = "prepared_test_only_distribution"
    test_only: bool = True
    shipping_qualified: bool = False
    installation_qualified: bool = False
    authentication_qualified: bool = False


def export_live(owner, directories, files, provenance, deadline, current):
    """Publish fixed ordinary bytes only; the caller retains the live signing guard.

    Calling this encoder directly cannot verify a signature, establish compiler
    custody, match an application wrapper, install a product or admit a stream.
    """
    _tick(deadline)
    owner = Path(owner)
    try:
        _require(owner.is_absolute() and owner.resolve(strict=True) == owner, "owner")
        info = owner.lstat()
        _require(
            stat.S_ISDIR(info.st_mode)
            and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700,
            "owner",
        )
        stamp = _stamp(info)
        ancestors = tuple((path, _stamp(path.lstat())) for path in reversed(owner.parents))
        _require(all(stat.S_ISDIR(value[3]) for _, value in ancestors), "owner")
    except OSError as error:
        raise DistributionRefusal("owner") from error
    key = str(owner)
    with _lock:
        if key in _active:
            _active[key]["poisoned"] = True
            raise DistributionRefusal("reentered")
        state = {"poisoned": False}
        _active[key] = state
    root, root_stamp, descriptor, root_descriptor = (
        owner / ".test-only-runtime-distribution",
        None,
        None,
        None,
    )
    observations = {}

    def guard():
        _tick(deadline)
        _require(not state["poisoned"], "reentered")
        _require(callable(current) and current() is True, "source_current")
        _require(not state["poisoned"], "reentered")
        try:
            _require(
                owner.resolve(strict=True) == owner and _stamp(owner.lstat()) == stamp, "owner"
            )
            for path, selected in ancestors:
                _require(_stamp(path.lstat()) == selected, "owner")
            if root_stamp is not None:
                _require(
                    root.resolve(strict=True) == root
                    and _stamp(root.lstat()) == root_stamp
                    and (
                        root_descriptor is None or _stamp(os.fstat(root_descriptor)) == root_stamp
                    ),
                    "owner",
                )
                _require({path.name for path in root.iterdir()} == set(observations), "inventory")
                for name, held in observations.items():
                    _require(_file_stamp((root / name).lstat()) == held, "inventory")
        except OSError as error:
            raise DistributionRefusal("owner") from error
        _tick(deadline)

    try:
        guard()
        directory_map, file_map = _members(directories, files)
        public = _provenance(provenance)
        guard()
        _require(not os.path.lexists(root), "collision")
        root.mkdir(mode=0o700)
        root_stamp = _stamp(root.lstat())
        root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        guard()

        def publish(name, producer):
            nonlocal descriptor
            guard()
            descriptor = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=root_descriptor,
            )
            opened = os.fstat(descriptor)
            _require(
                stat.S_ISREG(opened.st_mode)
                and opened.st_uid == os.getuid()
                and opened.st_nlink == 1
                and stat.S_IMODE(opened.st_mode) == 0o600
                and _file_stamp(opened) == _file_stamp((root / name).lstat()),
                "inventory",
            )
            observations[name] = _file_stamp(opened)

            class Writer:
                def write(self, data):
                    guard()
                    _require(type(data) is bytes, "io")
                    offset = 0
                    while offset < len(data):
                        guard()
                        count = os.write(descriptor, data[offset : offset + 65536])
                        _require(0 < count <= min(65536, len(data) - offset), "io")
                        observations[name] = _file_stamp(os.fstat(descriptor))
                        _require(
                            observations[name] == _file_stamp((root / name).lstat()), "inventory"
                        )
                        offset += count
                        guard()
                    return len(data)

                def flush(self):
                    guard()

            producer(Writer())
            guard()
            os.fsync(descriptor)
            guard()
            selected, descriptor = descriptor, None
            os.close(selected)
            guard()

        def archive(writer):
            entries = [(name, True, mode, b"") for name, mode in directory_map.items()]
            entries += [(name, False, mode, data) for name, (mode, data) in file_map.items()]
            entries.append(("PROVENANCE.json", False, 0o644, public))
            with gzip.GzipFile(
                fileobj=writer, mode="wb", filename="", mtime=0, compresslevel=9
            ) as compressed:
                with tarfile.open(
                    fileobj=compressed, mode="w|", format=tarfile.USTAR_FORMAT
                ) as output:
                    for name, directory, mode, data in sorted(entries):
                        guard()
                        entry = tarfile.TarInfo(name)
                        entry.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
                        entry.mode, entry.uid, entry.gid, entry.uname, entry.gname, entry.mtime = (
                            mode,
                            0,
                            0,
                            "",
                            "",
                            0,
                        )
                        entry.size = 0 if directory else len(data)
                        output.addfile(entry, None if directory else io.BytesIO(data))
                        guard()

        publish("runtime.tar.gz", archive)
        guard()
        digest = hashlib.sha256()
        reader = os.open("runtime.tar.gz", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=root_descriptor)
        try:
            _require(_file_stamp(os.fstat(reader)) == observations["runtime.tar.gz"], "inventory")
            while True:
                guard()
                data = os.read(reader, 65536)
                guard()
                if not data:
                    break
                digest.update(data)
            _require(_file_stamp(os.fstat(reader)) == observations["runtime.tar.gz"], "inventory")
        finally:
            os.close(reader)
        guard()
        publish(
            "runtime.sha256",
            lambda writer: writer.write((digest.hexdigest() + "  runtime.tar.gz\n").encode()),
        )
        publish("provenance.json", lambda writer: writer.write(public))
        guard()
        os.fsync(root_descriptor)
        guard()
        selected, root_descriptor = root_descriptor, None
        os.close(selected)
        guard()
        return DistributionOutcome(root)
    except OSError as error:
        raise DistributionRefusal("io") from error
    finally:
        try:
            if descriptor is not None:
                selected, descriptor = descriptor, None
                os.close(selected)
        finally:
            try:
                if root_descriptor is not None:
                    selected, root_descriptor = root_descriptor, None
                    os.close(selected)
            finally:
                with _lock:
                    if _active.get(key) is state:
                        del _active[key]
