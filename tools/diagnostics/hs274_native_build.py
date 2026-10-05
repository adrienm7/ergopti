# tools/diagnostics/hs274_native_build.py
"""Compile an owned pinned source tree without signing, installing or activating it."""

import argparse
import errno
import hashlib
import http.client
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import socket
import stat
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib

UPSTREAM = "9312593e1a3bf72b94c63c524ebabe2637442e8a"
CPM = "6a8b2d64b993746d489432b45455e33b7fb8e09f"
VIRTUAL_HID = "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb"
CALIBRATION_SECONDS = 300
MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_LOG_BYTES = 32 * 1024 * 1024
XCODEGEN_VERSION = "2.46.0"
XCODEGEN_ASSET_ID = 478866069
XCODEGEN_ARCHIVE_BYTES = 4_278_764
XCODEGEN_ARCHIVE_SHA256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
XCODEGEN_BINARY_SHA256 = "8774da746668bc18fe74e54cbaf10f2631a1fb05947cd374179aa912f14f99db"
XCODEGEN_BINARY_RELATIVE = "xcodegen/bin/xcodegen"
XCODEGEN_URL = "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
XCODEGEN_METADATA_URL = "https://api.github.com/repos/yonaskolb/XcodeGen/releases/assets/478866069"


class NativeBuildError(RuntimeError):
    """A qualification refusal retains its owned inputs and exact phase evidence."""

    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def require(condition, code, message):
    """Keep refusal checks active even under optimized Python execution."""
    if not condition:
        raise NativeBuildError(code, message)


def validate_budget(value):
    """Admit only a finite integer calibration within the fixed XCTest envelope."""
    require(
        type(value) is int and 0 < value <= CALIBRATION_SECONDS,
        "invalid_budget",
        "Calibration deadline must be an integer in 1..300",
    )
    return value


def validate_owner_root(root):
    """Admit only an existing ordinary canonical directory owned privately by this UID."""
    root = Path(root)
    require(root.is_absolute(), "owner_path", "Owned directory must be absolute")
    try:
        info = root.lstat()
        canonical = root.resolve(strict=True)
    except OSError as error:
        raise NativeBuildError("owner_path", "Owned directory is unavailable") from error
    require(
        stat.S_ISDIR(info.st_mode) and canonical == root,
        "owner_path",
        "Owned directory may not redirect through a symlink",
    )
    require(
        stat.S_IMODE(info.st_mode) == 0o700,
        "owner_mode",
        "Owned directory must have mode 0700",
    )
    require(
        info.st_uid == os.getuid(),
        "owner_identity",
        "Owned directory belongs to another UID",
    )
    return root


def read_regular(path, maximum=MAX_INPUT_BYTES, bounds_code="unsafe_path"):
    """Refuse redirected, oversized or incomplete input files."""
    path = Path(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise NativeBuildError(
            "unsafe_path", "Input is unavailable or redirected: " + path.name
        ) from error
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(
            stat.S_ISREG(info.st_mode) and info.st_size >= 0,
            "unsafe_path",
            "Input is not an ordinary file: " + path.name,
        )
        require(
            info.st_size <= maximum,
            bounds_code,
            "Input exceeds its bounded file size: " + path.name,
        )
        data = stream.read(maximum + 1)
        require(
            len(data) == info.st_size,
            "unsafe_path",
            "Input changed while reading: " + path.name,
        )
    return data


def write_exclusive(path, data):
    """Publish only a new ordinary file, never replacing existing fixture state."""
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as error:
        raise NativeBuildError("unsafe_path", "Exclusive evidence path is unavailable") from error
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def write_json(path, value):
    """Retain a bounded structured phase record with ordinary exclusive ownership."""
    write_exclusive(path, (json.dumps(value, sort_keys=True, allow_nan=False) + "\n").encode())


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify_xcodegen_metadata(value):
    """Admit a fresh exact pinned asset identity from the official API response."""
    expected = {
        "id": XCODEGEN_ASSET_ID,
        "name": "xcodegen.zip",
        "size": XCODEGEN_ARCHIVE_BYTES,
        "digest": "sha256:" + XCODEGEN_ARCHIVE_SHA256,
        "browser_download_url": XCODEGEN_URL,
    }
    require(isinstance(value, dict), "xcodegen_metadata", "Official tool metadata is not an object")
    require(
        all(
            key in value and type(value[key]) is type(wanted) and value[key] == wanted
            for key, wanted in expected.items()
        ),
        "xcodegen_metadata",
        "Official tool metadata differs from the pinned asset",
    )
    return {key: value[key] for key in expected}


def verify_xcodegen_archive(data):
    """Authenticate the complete official artifact before persistence or extraction."""
    require(
        type(data) is bytes and len(data) == XCODEGEN_ARCHIVE_BYTES,
        "xcodegen_size",
        "Official tool archive does not have its exact pinned byte size",
    )
    require(
        digest(data) == XCODEGEN_ARCHIVE_SHA256,
        "xcodegen_digest",
        "Official tool archive does not match its authoritative digest",
    )
    return {"bytes": len(data), "sha256": digest(data)}


def _xcodegen_members(data):
    """Validate all bounded ordinary ZIP members and CRCs before creating output."""
    require(type(data) is bytes, "xcodegen_archive", "Tool archive is not ordinary bytes")
    require(len(data) <= 8 * 1024 * 1024, "xcodegen_limit", "Tool ZIP exceeds its structural bound")
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            inventory = archive.infolist()
            require(
                0 < len(inventory) <= 128,
                "xcodegen_limit",
                "Tool ZIP member count exceeds its bound",
            )
            require(
                all(0 <= item.file_size <= 16 * 1024 * 1024 for item in inventory)
                and sum(item.file_size for item in inventory) <= 32 * 1024 * 1024,
                "xcodegen_limit",
                "Tool ZIP expansion exceeds its bound",
            )
            paths = {}
            for item in inventory:
                name = item.filename
                directory = item.is_dir()
                ordinary_name = name[:-1] if directory else name
                components = ordinary_name.split("/")
                require(
                    item.orig_filename == name
                    and "\0" not in name
                    and len(name) <= 512
                    and len(components) <= 16
                    and components[0] == "xcodegen"
                    and all(
                        part not in {"", ".", ".."}
                        and re.fullmatch(r"[A-Za-z0-9_.-]+", part) is not None
                        for part in components
                    ),
                    "xcodegen_member",
                    "Tool ZIP member path is not canonical within its root",
                )
                mode = stat.S_IFMT(item.external_attr >> 16)
                require(
                    mode in ({0, stat.S_IFDIR} if directory else {0, stat.S_IFREG})
                    and not item.flag_bits & 1
                    and (not directory or item.file_size == 0),
                    "xcodegen_member",
                    "Tool ZIP member is encrypted or not ordinary",
                )
                require(
                    ordinary_name not in paths, "xcodegen_member", "Tool ZIP repeats a member path"
                )
                paths[ordinary_name] = (item, directory)
            for name in paths:
                for parent in PurePosixPath(name).parents:
                    require(
                        str(parent) not in paths or paths[str(parent)][1],
                        "xcodegen_member",
                        "Tool ZIP file shadows a parent directory",
                    )
            binary = paths.get(XCODEGEN_BINARY_RELATIVE)
            require(
                binary is not None and not binary[1] and binary[0].file_size > 0,
                "xcodegen_binary",
                "Tool ZIP lacks its nonempty expected binary",
            )
            rows = []
            for name, (item, directory) in paths.items():
                payload = archive.read(item)
                require(
                    len(payload) == item.file_size,
                    "xcodegen_archive",
                    "Tool ZIP member is incomplete",
                )
                rows.append((name, directory, payload))
            return rows
    except (
        zipfile.BadZipFile,
        zipfile.LargeZipFile,
        RuntimeError,
        NotImplementedError,
        EOFError,
        zlib.error,
    ) as error:
        if isinstance(error, NativeBuildError):
            raise
        raise NativeBuildError(
            "xcodegen_archive", "Tool ZIP is malformed or failed CRC validation"
        ) from error


def extract_xcodegen_zip(data, destination):
    """Extract only validated ordinary members into a new private owner directory."""
    destination = Path(destination)
    owner = validate_owner_root(destination.parent)
    require(
        destination.is_absolute()
        and destination.parent == owner
        and not destination.exists()
        and not destination.is_symlink(),
        "unsafe_path",
        "Tool extraction destination already exists or redirects",
    )
    rows = _xcodegen_members(data)
    # CRC, path, type and expansion checks above finish before any filesystem mutation.
    destination.mkdir(mode=0o700)
    directories = {destination}
    for name, directory, payload in rows:
        target = destination / name
        required_parent = target if directory else target.parent
        pending = []
        while required_parent not in directories:
            pending.append(required_parent)
            required_parent = required_parent.parent
        for parent in reversed(pending):
            parent.mkdir(mode=0o700)
            directories.add(parent)
        if not directory:
            write_exclusive(target, payload)
    binary = destination / XCODEGEN_BINARY_RELATIVE
    binary.chmod(0o700)
    return binary


class _PinnedToolRedirect(urllib.request.HTTPRedirectHandler):
    """Prevent transport downgrade or unrelated-host redirects before acquisition."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _tool_https_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _tool_https_url(url):
    """Allow only verified HTTPS destinations belonging to this official acquisition."""
    try:
        target = urllib.parse.urlsplit(url)
        admitted = (
            target.scheme == "https"
            and target.hostname
            in {
                "api.github.com",
                "github.com",
                "release-assets.githubusercontent.com",
                "objects.githubusercontent.com",
            }
            and target.port in {None, 443}
            and target.username is None
            and target.password is None
        )
    except ValueError as error:
        raise NativeBuildError("xcodegen_transport", "Official tool URL is malformed") from error
    require(admitted, "xcodegen_transport", "Official tool URL redirects outside verified HTTPS")
    return target


def _tool_http_failure(status):
    """Export only a typed public HTTP status, never response content or headers."""
    diagnostic = {"kind": "http_status"}
    if type(status) is int and 100 <= status <= 599:
        diagnostic["http_status"] = status
    return diagnostic


def _tool_transport_failure(error):
    """Classify bounded typed failures without formatting untrusted exception data."""
    # HTTPError also inherits URLError; preserve its public status before unwrapping.
    for _ in range(4):
        if isinstance(error, urllib.error.HTTPError):
            return _tool_http_failure(error.code)
        if not isinstance(error, urllib.error.URLError):
            break
        reason = error.reason
        if not isinstance(reason, BaseException) or reason is error:
            return {"kind": "other_transport"}
        error = reason
    if isinstance(error, ssl.SSLCertVerificationError):
        diagnostic = {"kind": "tls_certificate_verification"}
        code = getattr(error, "verify_code", None)
        if type(code) is int and 0 <= code <= 2**31 - 1:
            diagnostic["verify_code"] = code
        return diagnostic
    if isinstance(error, ssl.SSLError):
        return {"kind": "tls_error"}
    if isinstance(error, TimeoutError):
        return {"kind": "timeout"}
    if isinstance(error, socket.gaierror):
        return {"kind": "dns_resolution"}
    if isinstance(error, ConnectionRefusedError):
        return {"kind": "connection_refused"}
    if isinstance(error, ConnectionResetError):
        return {"kind": "connection_reset"}
    if isinstance(error, ConnectionError) or (
        isinstance(error, OSError)
        and type(error.errno) is int
        and error.errno in {errno.ENETUNREACH, errno.EHOSTUNREACH}
    ):
        return {"kind": "connection_error"}
    if isinstance(error, OSError):
        diagnostic = {"kind": "os_error"}
        if type(error.errno) is int and 0 < error.errno < 4096:
            diagnostic["errno"] = error.errno
        return diagnostic
    if isinstance(error, http.client.HTTPException):
        return {"kind": "protocol_error"}
    return {"kind": "other_transport"}


def _download_tool_input(url, maximum, deadline, metadata=False):
    """Acquire bounded complete bytes through the default verified TLS context."""
    _tool_https_url(url)
    require(
        type(deadline) in (int, float) and math.isfinite(deadline) and time.monotonic() < deadline,
        "phase_deadline",
        "Tool acquisition deadline elapsed before request",
    )
    headers = {"User-Agent": "Ergopti-owned-native-source-qualification"}
    if metadata:
        headers.update(
            {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        )
    try:
        opener = urllib.request.build_opener(
            _PinnedToolRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context())
        )
        # TLS context/opener acquisition can consume the remaining absolute budget.
        # Admit its freshly measured remainder before passing any timeout to urllib.
        remaining = deadline - time.monotonic()
        require(
            remaining > 0, "phase_deadline", "Tool TLS preparation exceeded calibration deadline"
        )
        with opener.open(
            urllib.request.Request(url, headers=headers),
            timeout=min(30, remaining),
        ) as response:
            final = _tool_https_url(response.geturl())
            if response.status != 200:
                failure = NativeBuildError(
                    "xcodegen_transport", "Official tool HTTP status is not 200"
                )
                failure.transport_diagnostic = _tool_http_failure(response.status)
                raise failure
            advertised = response.headers.get("Content-Length")
            require(
                advertised is None or (advertised.isdecimal() and int(advertised) <= maximum),
                "xcodegen_size",
                "Official tool response exceeds its advertised bound",
            )
            chunks, size = [], 0
            while True:
                require(
                    time.monotonic() < deadline,
                    "phase_deadline",
                    "Tool acquisition exceeded calibration deadline",
                )
                chunk = response.read(min(65_536, maximum + 1 - size))
                if not chunk:
                    break
                size += len(chunk)
                require(
                    size <= maximum,
                    "xcodegen_size",
                    "Official tool response exceeds its measured bound",
                )
                chunks.append(chunk)
            require(
                advertised is None or size == int(advertised),
                "xcodegen_size",
                "Official tool response ended before its advertised byte size",
            )
            require(
                time.monotonic() <= deadline,
                "phase_deadline",
                "Tool acquisition completed after its deadline",
            )
            return b"".join(chunks), {
                "status": response.status,
                "TLS": "default-verified",
                "final_host": final.hostname,
                "bytes": size,
            }
    except (OSError, urllib.error.URLError, http.client.HTTPException) as error:
        failure = NativeBuildError("xcodegen_transport", "Official tool HTTPS acquisition failed")
        failure.transport_diagnostic = _tool_transport_failure(error)
        raise failure from error


def acquire_xcodegen(owner, deadline):
    """Acquire the official fixed tool entirely within the existing worker's budget."""
    owner = validate_owner_root(owner)
    started = time.monotonic()
    name = "xcodegen_acquisition"
    stage = "metadata"
    write_json(owner / (name + ".begin.json"), {"schema": 1, "phase": name, "status": "pending"})
    try:
        raw, metadata_transport = _download_tool_input(
            XCODEGEN_METADATA_URL, 65_536, deadline, metadata=True
        )

        def unique(pairs):
            value = {}
            for key, item in pairs:
                require(
                    key not in value,
                    "xcodegen_metadata",
                    "Official tool metadata repeats a JSON key",
                )
                value[key] = item
            return value

        try:
            metadata = verify_xcodegen_metadata(json.loads(raw, object_pairs_hook=unique))
        except (ValueError, UnicodeError) as error:
            raise NativeBuildError(
                "xcodegen_metadata", "Official tool metadata is not complete JSON"
            ) from error
        stage = "archive"
        archive, transport = _download_tool_input(XCODEGEN_URL, XCODEGEN_ARCHIVE_BYTES, deadline)
        identity = verify_xcodegen_archive(archive)
        require(
            time.monotonic() <= deadline,
            "phase_deadline",
            "Tool admission exceeded calibration deadline",
        )
        write_exclusive(owner / "xcodegen-official.zip", archive)
        require(
            time.monotonic() <= deadline,
            "phase_deadline",
            "Tool persistence exceeded calibration deadline",
        )
        binary = extract_xcodegen_zip(archive, owner / "xcodegen-package")
        require(
            digest(read_regular(binary, 16 * 1024 * 1024)) == XCODEGEN_BINARY_SHA256,
            "xcodegen_digest",
            "Extracted official tool binary differs from its pinned digest",
        )
        require(
            time.monotonic() <= deadline,
            "phase_deadline",
            "Tool extraction exceeded calibration deadline",
        )
        write_json(
            owner / "xcodegen-identity.json",
            {
                "schema": 1,
                "version": XCODEGEN_VERSION,
                "metadata": metadata,
                "archive": identity,
                "metadata_transport": metadata_transport,
                "archive_transport": transport,
                "binary_sha256": XCODEGEN_BINARY_SHA256,
                "binary_relative_path": str(binary.relative_to(owner)),
                "global_installation_executed": False,
                "installer_executed": False,
            },
        )
        ended = time.monotonic()
        require(
            ended <= deadline,
            "phase_deadline",
            "Tool identity evidence exceeded calibration deadline",
        )
    except NativeBuildError as error:
        record = {
            "schema": 1,
            "phase": name,
            "status": "refused",
            "code": error.code,
            "elapsed_seconds": time.monotonic() - started,
            "acquisition_stage": stage,
        }
        if error.code == "phase_deadline":
            record["transport_diagnostic"] = {"kind": "deadline"}
        elif hasattr(error, "transport_diagnostic"):
            record["transport_diagnostic"] = error.transport_diagnostic
        write_json(owner / (name + ".receipt.json"), record)
        raise
    record = {
        "schema": 1,
        "phase": name,
        "status": "passed",
        "elapsed_seconds": ended - started,
        "operation": "verified-HTTPS-download-and-ordinary-extraction",
        "child_process_executed": False,
    }
    write_json(owner / (name + ".receipt.json"), record)
    return binary, record


def candidate_path(name):
    """The inactive patch may change diagnostic compilation inputs only."""
    return isinstance(name, str) and (
        re.fullmatch(r"hs274-[A-Za-z0-9_-]+\.(hpp|cpp)", name) is not None
        or name in {"hs274_raw_patch.py", "hs274_stream_patch.py"}
    )


def valid_digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def load_candidate_seal(path):
    """Validate the exact inactive compilation seal before trusting any patch path."""

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate_key", "Candidate seal repeats a JSON key")
            result[key] = value
        return result

    try:
        seal = json.loads(read_regular(path, 65_536, "invalid_seal"), object_pairs_hook=unique)
    except (ValueError, UnicodeError) as error:
        raise NativeBuildError(
            "invalid_seal", "Candidate seal is not complete ordinary JSON"
        ) from error
    require(
        isinstance(seal, dict)
        and set(seal) == {"schema", "purpose", "patch_file", "patch_sha256", "files"},
        "invalid_seal",
        "Candidate seal fields are not exact",
    )
    require(
        type(seal["schema"]) is int
        and seal["schema"] == 1
        and seal["purpose"] == "inactive-native-compilation-only",
        "invalid_seal",
        "Candidate seal does not name inactive compilation",
    )
    require(
        isinstance(seal["patch_file"], str)
        and re.fullmatch(r"[A-Za-z0-9_-]+\.patch", seal["patch_file"]) is not None,
        "unsafe_path",
        "Candidate patch must be an ordinary sibling basename",
    )
    require(
        valid_digest(seal["patch_sha256"]),
        "invalid_digest",
        "Candidate patch digest is invalid",
    )
    require(
        isinstance(seal["files"], list) and 0 < len(seal["files"]) <= 64,
        "invalid_seal",
        "Candidate seal needs a bounded nonempty file inventory",
    )
    seen = set()
    for row in seal["files"]:
        require(
            isinstance(row, dict) and set(row) == {"path", "preimage_sha256", "candidate_sha256"},
            "invalid_seal",
            "Candidate file fields are not exact",
        )
        require(
            candidate_path(row["path"]),
            "candidate_path",
            "Candidate file escapes diagnostic source scope",
        )
        require(
            row["path"] not in seen,
            "duplicate_candidate_path",
            "Candidate file inventory repeats a path",
        )
        seen.add(row["path"])
        require(
            row["preimage_sha256"] is None or valid_digest(row["preimage_sha256"]),
            "invalid_digest",
            "Candidate preimage digest is invalid",
        )
        require(
            valid_digest(row["candidate_sha256"]),
            "invalid_digest",
            "Candidate postimage digest is invalid",
        )
    return seal


def stage_diagnostics(source, destination):
    """Copy actual generator/header inputs into an exclusively owned private directory."""
    source, destination = Path(source), Path(destination)
    owner = validate_owner_root(destination.parent)
    require(
        source.is_absolute() and source.resolve(strict=True) == source and source.is_dir(),
        "unsafe_path",
        "Diagnostic source directory is not ordinary and canonical",
    )
    require(
        destination.parent == owner and not destination.exists() and not destination.is_symlink(),
        "unsafe_path",
        "Diagnostic staging directory already exists",
    )
    require(
        source != destination
        and destination not in source.parents
        and source not in destination.parents,
        "unsafe_path",
        "Diagnostic staging must be separate from source inputs",
    )
    inputs = [
        (item.name, read_regular(item))
        for item in sorted(source.iterdir())
        if candidate_path(item.name)
    ]
    names = {name for name, _data in inputs}
    require(
        {"hs274_raw_patch.py", "hs274_stream_patch.py", "hs274-stream-source.hpp"} <= names,
        "unsafe_path",
        "Diagnostic staging lacks actual generators or source headers",
    )
    destination.mkdir(mode=0o700)
    for name, data in inputs:
        write_exclusive(destination / name, data)
    return {"files": [{"path": name, "sha256": digest(data)} for name, data in inputs]}


def apply_candidate_patch(destination, seal_path):
    """Check a retained exact candidate and apply it only inside private diagnostics."""
    destination, seal_path = validate_owner_root(destination), Path(seal_path)
    seal = load_candidate_seal(seal_path)
    patch = read_regular(seal_path.parent / seal["patch_file"])
    require(
        digest(patch) == seal["patch_sha256"],
        "patch_hash",
        "Inactive candidate patch digest changed",
    )
    require(b"\r" not in patch, "patch_rejected", "Inactive candidate patch must use LF")
    for row in seal["files"]:
        target = destination / row["path"]
        if row["preimage_sha256"] is None:
            require(
                not target.exists() and not target.is_symlink(),
                "preimage_hash",
                "Inactive candidate new path already exists",
            )
        else:
            require(
                digest(read_regular(target)) == row["preimage_sha256"],
                "preimage_hash",
                "Inactive candidate preimage changed: " + row["path"],
            )
    patch_path = destination.parent / "inactive-candidate-input.patch"
    write_exclusive(patch_path, patch)
    result = subprocess.run(
        ["git", "apply", "--numstat", "-z", str(patch_path)],
        cwd=destination,
        capture_output=True,
    )
    require(
        result.returncode == 0,
        "patch_rejected",
        "Inactive candidate patch inventory cannot be read",
    )
    paths = []
    try:
        for record in result.stdout.decode("utf-8").split("\0"):
            if record:
                added, removed, name = record.split("\t")
                require(
                    added.isdecimal() and removed.isdecimal(),
                    "patch_scope",
                    "Binary candidate mutation refused",
                )
                paths.append(name)
    except (ValueError, UnicodeError) as error:
        raise NativeBuildError(
            "patch_scope", "Inactive candidate patch paths are not ordinary"
        ) from error
    require(
        len(paths) == len(set(paths)) and set(paths) == {row["path"] for row in seal["files"]},
        "patch_scope",
        "Inactive candidate mutation paths differ from its seal",
    )
    for arguments in (
        ["--check", "--whitespace=error-all"],
        ["--whitespace=error-all"],
    ):
        result = subprocess.run(
            ["git", "apply"] + arguments + [str(patch_path)],
            cwd=destination,
            capture_output=True,
        )
        require(
            result.returncode == 0,
            "patch_rejected",
            "Inactive candidate application refused",
        )
    for row in seal["files"]:
        require(
            digest(read_regular(destination / row["path"])) == row["candidate_sha256"],
            "postimage_hash",
            "Inactive candidate postimage differs from its seal",
        )
    return {
        "seal_sha256": digest(read_regular(seal_path, 65_536)),
        "patch_sha256": seal["patch_sha256"],
        "files": seal["files"],
    }


def verify_pins(observed):
    """Compare actual acquired source and submodule identities with the pinned tuple."""
    expected = {"upstream": UPSTREAM, "cpm": CPM, "vhd": VIRTUAL_HID}
    require(
        observed == expected,
        "invalid_seal",
        "Acquired source/submodule tuple differs from exact pins",
    )
    return dict(expected)


def run_phase(name, args, cwd, owner, deadline):
    """Run one foreground child inside the guardian's inherited group and retain evidence."""
    owner, cwd = validate_owner_root(owner), Path(cwd)
    require(
        isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", name) is not None,
        "unsafe_path",
        "Phase name is not an ordinary evidence basename",
    )
    require(
        cwd.is_absolute()
        and cwd.resolve(strict=True) == cwd
        and cwd.is_dir()
        and (cwd == owner or owner in cwd.parents),
        "unsafe_path",
        "Phase working directory escapes ownership",
    )
    require(
        isinstance(args, list)
        and args
        and all(isinstance(item, str) and "\0" not in item for item in args),
        "unsafe_path",
        "Phase child arguments are not exact ordinary strings",
    )
    require(
        type(deadline) in (int, float) and math.isfinite(deadline) and time.monotonic() < deadline,
        "phase_deadline",
        "Calibration deadline elapsed before child acquisition",
    )
    started = time.monotonic()
    write_json(
        owner / (name + ".begin.json"),
        {"schema": 1, "phase": name, "status": "pending"},
    )
    stdout, stderr = owner / (name + ".stdout"), owner / (name + ".stderr")
    try:
        out = os.open(stdout, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            err = os.open(stderr, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except BaseException:
            os.close(out)
            raise
        with os.fdopen(out, "wb") as output, os.fdopen(err, "wb") as errors:
            result = subprocess.run(
                args, cwd=cwd, stdin=subprocess.DEVNULL, stdout=output, stderr=errors
            )
            output.flush()
            errors.flush()
            os.fsync(output.fileno())
            os.fsync(errors.fileno())
    except OSError as error:
        write_json(
            owner / (name + ".receipt.json"),
            {
                "schema": 1,
                "phase": name,
                "status": "launch_refused",
                "elapsed_seconds": time.monotonic() - started,
            },
        )
        raise NativeBuildError(
            "phase_failed", "Native phase child acquisition failed: " + name
        ) from error
    ended = time.monotonic()
    record = {
        "schema": 1,
        "phase": name,
        "status": "refused"
        if ended > deadline
        else ("passed" if result.returncode == 0 else "failed"),
        "exit_status": result.returncode,
        "elapsed_seconds": ended - started,
    }
    write_json(owner / (name + ".receipt.json"), record)
    require(
        stdout.stat().st_size <= MAX_LOG_BYTES and stderr.stat().st_size <= MAX_LOG_BYTES,
        "phase_log_limit",
        "Native phase output exceeded its retained evidence bound",
    )
    require(
        result.returncode == 0,
        "phase_failed",
        "Native phase exited unsuccessfully: " + name,
    )
    require(
        ended <= deadline,
        "phase_deadline",
        "Native phase completed after calibration deadline: " + name,
    )
    return record


def compile_native(source, owner, seconds, seal_path=None):
    """Calibrate actual unsigned pinned Core-Service/CLI compilation without activation."""
    owner, seconds = validate_owner_root(owner), validate_budget(seconds)
    require(
        sys.platform == "darwin",
        "tool_unavailable",
        "Actual Darwin SDK qualification requires macOS",
    )
    tools = {name: shutil.which(name) for name in ["git", "xcodebuild", "xcrun"]}
    require(
        all(tools.values()),
        "tool_unavailable",
        "Native build tools are unavailable; qualification cannot skip",
    )
    deadline, phases = time.monotonic() + seconds, []
    diagnostics = owner / "diagnostics"
    inputs = stage_diagnostics(Path(source), diagnostics)
    candidate = apply_candidate_patch(diagnostics, Path(seal_path)) if seal_path else None
    write_json(
        owner / "inputs.json",
        {
            "schema": 1,
            "inputs": inputs,
            "candidate": candidate,
            "architecture": os.uname().machine,
            "tools": tools,
        },
    )

    def phase(name, args, cwd=owner):
        phases.append(run_phase(name, args, cwd, owner, deadline))

    phase("xcode_version", [tools["xcodebuild"], "-version"])
    binary, acquisition = acquire_xcodegen(owner, deadline)
    phases.append(acquisition)
    tools["xcodegen"] = str(binary)
    phase("xcodegen_version", [tools["xcodegen"], "--version"])
    phase("sdk_path", [tools["xcrun"], "--show-sdk-path"])
    checkout = owner / "upstream"
    phase(
        "acquisition",
        [
            tools["git"],
            "-c",
            "http.sslVerify=true",
            "-c",
            "transfer.fsckObjects=true",
            "clone",
            "--no-checkout",
            "https://github.com/pqrs-org/Karabiner-Elements.git",
            str(checkout),
        ],
    )
    phase(
        "checkout",
        [tools["git"], "-C", str(checkout), "checkout", "--detach", UPSTREAM],
    )
    phase(
        "submodules",
        [
            tools["git"],
            "-C",
            str(checkout),
            "submodule",
            "update",
            "--init",
            "--recursive",
        ],
    )
    observed = {}
    for key, relative in [
        ("upstream", ""),
        ("cpm", "vendor/cpm-cmake-package-lock"),
        ("vhd", "vendor/Karabiner-DriverKit-VirtualHIDDevice"),
    ]:
        phase(
            "identity_" + key,
            [tools["git"], "-C", str(checkout / relative), "rev-parse", "HEAD"],
        )
        observed[key] = read_regular(owner / ("identity_" + key + ".stdout")).decode().strip()
    pins = verify_pins(observed)
    phase("source_clean", [tools["git"], "-C", str(checkout), "diff", "--exit-code"])
    headers = sorted((checkout / "vendor/vendor/include/nlohmann").rglob("*.hpp"))
    require(
        len(headers) == 46,
        "source_identity",
        "Pinned actual JSON header inventory is incomplete",
    )
    write_json(
        owner / "source-identity.json",
        {
            "schema": 1,
            "pins": pins,
            "json_headers": [
                {
                    "path": str(path.relative_to(checkout)),
                    "sha256": digest(read_regular(path)),
                }
                for path in headers
            ],
        },
    )
    phase(
        "version",
        [sys.executable, str(checkout / "scripts/update_version.py")],
        checkout,
    )
    phase(
        "instrumentation",
        [
            sys.executable,
            str(diagnostics / "hs274_raw_patch.py"),
            str(checkout),
            "--stream",
        ],
        checkout,
    )
    products = []
    for label, relative, product in [
        ("duktape", "vendor/duktape-src", "build/Release/libduktape.a"),
        (
            "core",
            "src/apps/CoreService",
            "build/Release/Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service",
        ),
        ("cli", "src/bin/cli", "build/Release/karabiner_cli"),
    ]:
        project = checkout / relative
        phase(label + "_generate", [tools["xcodegen"], "generate"], project)
        phase(
            label + "_build",
            [
                tools["xcodebuild"],
                "-configuration",
                "Release",
                "-alltargets",
                "SYMROOT=" + str(project / "build"),
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
            ],
            project,
        )
        path = project / product
        data = read_regular(path, 128 * 1024 * 1024)
        require(data, "phase_failed", "Native compiler product is empty: " + label)
        products.append(
            {
                "target": label,
                "path": str(path.relative_to(owner)),
                "sha256": digest(data),
                "bytes": len(data),
            }
        )
    record = {
        "schema": 1,
        "qualification": "unsigned-pinned-source-compilation-only",
        "status": "passed",
        "budget_seconds": seconds,
        "candidate": candidate,
        "pins": pins,
        "phases": phases,
        "products": products,
        "native_capture_executed": False,
        "installation_executed": False,
    }
    write_json(owner / "native-build-result.json", record)
    print(
        "PASS unsigned pinned Core-Service and CLI compilation; native capture and installation unexecuted",
        flush=True,
    )
    for row in phases:
        print(
            "PHASE " + row["phase"] + " seconds=" + format(row["elapsed_seconds"], ".3f"),
            flush=True,
        )
    print(
        "CANDIDATE "
        + (candidate["patch_sha256"] if candidate else "none; actual diagnostic inputs compiled"),
        flush=True,
    )
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("owner", type=Path)
    parser.add_argument("--budget", type=int, default=CALIBRATION_SECONDS)
    parser.add_argument("--candidate-seal", type=Path)
    options = parser.parse_args()
    try:
        compile_native(options.source, options.owner, options.budget, options.candidate_seal)
        return 0
    except NativeBuildError as failure:
        try:
            write_json(
                validate_owner_root(options.owner) / "native-build-refusal.json",
                {
                    "schema": 1,
                    "status": "refused",
                    "code": failure.code,
                    "reason": str(failure),
                },
            )
        except (NativeBuildError, OSError):
            pass  # A refusal never authorizes replacement or deletion of existing state.
        print(
            "Native compilation qualification refused: " + failure.code + "; " + str(failure),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
