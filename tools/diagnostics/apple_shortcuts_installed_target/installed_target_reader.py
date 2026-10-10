"""Read only a LaunchServices-resolved bundle's explicitly declared dictionary."""

import hashlib
import json
import os
import plistlib
import re
import stat
import time

TARGET = "com.apple.shortcuts.events"
LIMIT = 65536
DECLARATIONS = ("OSAScriptingDefinition", "NSScriptingDefinition")


class MetadataRefused(RuntimeError):
    """Carry a finite reason, never native paths, dictionary text or errors."""


class UniquePlistDict(dict):
    """Reject conflicting plist entries instead of accepting the final duplicate."""

    def __setitem__(self, key, value):
        if key in self:
            raise ValueError("duplicate plist key")
        super().__setitem__(key, value)


def require(condition, reason):
    """Refuse malformed metadata without granting runtime authority."""
    if not condition:
        raise MetadataRefused(reason)


def unique_object(pairs):
    """Keep duplicate native packet fields from selecting a different route."""
    result = {}
    for key, value in pairs:
        require(key not in result, "resolution_duplicate")
        result[key] = value
    return result


def resolution_path(raw):
    """Validate the exact private resolver packet; never accept a fallback path."""
    require(type(raw) is bytes and 0 < len(raw) <= LIMIT, "resolution_bound")
    try:
        packet = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        raise MetadataRefused("resolution_shape") from None
    require(
        type(packet) is dict and set(packet) == {"version", "status", "target", "urls"},
        "resolution_shape",
    )
    require(
        type(packet["version"]) is int
        and packet["version"] == 1
        and packet["status"] == "resolved"
        and packet["target"] == TARGET,
        "resolution_identity",
    )
    urls = packet["urls"]
    require(type(urls) is list and len(urls) == 1 and type(urls[0]) is str, "resolution_ambiguous")
    path = urls[0]
    require(
        path.startswith("/") and "\x00" not in path and len(path.encode("utf-8")) <= 4096,
        "resolution_path",
    )
    require(all(part not in ("", ".", "..") for part in path.split("/")[1:]), "resolution_path")
    return path


def identity(info):
    """Record exact descriptor identity, not a target-process or permission lease."""
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def check_deadline(deadline):
    """Use the caller's original capture deadline without refreshing it."""
    require(type(deadline) is float and time.monotonic() < deadline, "deadline")


def read_bundle(path, deadline):
    """Read and rejoin retained directory/file descriptors with their named entries.

    The caller supplies only the genuine resolver's validated private output.
    This produces metadata evidence, never installed code or native capability.
    No callbacks, symlink traversal, directory scan or bundle fallback is used.
    """
    check_deadline(deadline)
    require(type(path) is str and path.startswith("/") and "\x00" not in path, "bundle_path")
    parts = path.split("/")[1:]
    require(
        parts
        and all(part not in ("", ".", "..") for part in parts)
        and len(path.encode("utf-8")) <= 4096,
        "bundle_path",
    )
    descriptors = []
    edges = []
    files = []

    def open_directory(parent, name):
        check_deadline(deadline)
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        descriptors.append(fd)
        held = os.fstat(fd)
        require(stat.S_ISDIR(held.st_mode), "directory_type")
        edges.append((parent, name, fd, identity(held)))
        return fd

    def read_file(parent, name, reason):
        check_deadline(deadline)
        # O_NONBLOCK ensures an unexpected FIFO cannot stall before type refusal.
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        descriptors.append(fd)
        held = os.fstat(fd)
        require(stat.S_ISREG(held.st_mode), reason + "_type")
        require(0 < held.st_size <= LIMIT, reason + "_bound")
        raw = bytearray()
        while len(raw) <= LIMIT:
            check_deadline(deadline)
            chunk = os.read(fd, min(8192, LIMIT + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        require(len(raw) == held.st_size and 0 < len(raw) <= LIMIT, reason + "_bound")
        require(identity(os.fstat(fd)) == identity(held), "source_changed")
        files.append((parent, name, fd, identity(held)))
        return bytes(raw), identity(held)

    try:
        root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(root_fd)
        bundle = root_fd
        for part in parts:
            bundle = open_directory(bundle, part)
        bundle_identity = identity(os.fstat(bundle))
        contents = open_directory(bundle, "Contents")
        info_raw, info_identity = read_file(contents, "Info.plist", "info")
        try:
            info = plistlib.loads(info_raw, dict_type=UniquePlistDict)
        except Exception:
            raise MetadataRefused("info_shape") from None
        require(
            isinstance(info, UniquePlistDict) and info.get("CFBundleIdentifier") == TARGET,
            "bundle_identifier",
        )
        declarations = [(key, info[key]) for key in DECLARATIONS if key in info]
        require(declarations, "dictionary_undeclared")
        # Preserve exact declared names; never guess an extension or search.
        for _key, value in declarations:
            require(
                type(value) is str
                and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,254}", value)
                and value not in (".", ".."),
                "dictionary_declaration",
            )
        require(len({value for _key, value in declarations}) == 1, "dictionary_conflict")
        resources = open_directory(contents, "Resources")
        dictionary_raw, dictionary_identity = read_file(resources, declarations[0][1], "dictionary")
        # Byte-preserving observation only: no dictionary parser, entities or AE.
        check_deadline(deadline)
        for parent, name, fd, expected in edges + files:
            require(identity(os.fstat(fd)) == expected, "source_changed")
            named = os.stat(name, dir_fd=parent, follow_symlinks=False)
            require(identity(named) == expected, "source_replaced")
        require(identity(os.fstat(bundle)) == bundle_identity, "bundle_changed")
        check_deadline(deadline)
        receipt = {
            "version": 1,
            "status": "metadata_observed",
            "target": TARGET,
            "bundle_identity": list(bundle_identity),
            "info_identity": list(info_identity),
            "info_sha256": hashlib.sha256(info_raw).hexdigest(),
            "info_bytes": len(info_raw),
            "dictionary_identity": list(dictionary_identity),
            "dictionary_sha256": hashlib.sha256(dictionary_raw).hexdigest(),
            "dictionary_bytes": len(dictionary_raw),
            "declaration_keys": [key for key, _value in declarations],
            "running_target_observed": False,
            "catalogue_observed": False,
            "permission_observed": False,
            "invocation_qualified": False,
        }
        return receipt, info_raw, dictionary_raw
    except OSError:
        raise MetadataRefused("metadata_io") from None
    finally:
        for fd in reversed(descriptors):
            os.close(fd)
