# tools/diagnostics/hs274_native_build.py
"""Compile an owned pinned source tree without signing, installing or activating it."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

UPSTREAM = "9312593e1a3bf72b94c63c524ebabe2637442e8a"
CPM = "6a8b2d64b993746d489432b45455e33b7fb8e09f"
VIRTUAL_HID = "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb"
CALIBRATION_SECONDS = 300
MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_LOG_BYTES = 32 * 1024 * 1024


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
    tools = {name: shutil.which(name) for name in ["git", "xcodegen", "xcodebuild", "xcrun"]}
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
