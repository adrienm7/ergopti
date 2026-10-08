# tools/diagnostics/hs274_native_build_observation.py
"""Observe fixed retained baseline metadata without executing a native phase."""

import ast
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import sys

BUILDER_SHA256 = "e8891edda6f25de3ab4361143c51ce55b4289368e6dfb69102f671681081d1d6"
BUILDER_SOURCE_BYTES = 134280
MAX_RECORD_BYTES = 4096
MAX_CAPTURE_BYTES = 32 * 1024 * 1024
MAX_PUBLIC_BYTES = 2048


class UnsupportedObservation(Exception):
    """Unrecognized or unstable metadata cannot support an observation."""


def require(value):
    if not value:
        raise UnsupportedObservation()


def identity(info):
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


class BuilderProjection:
    """Hold the exact canonical phase declaration and its observed source images."""

    def __init__(self, phases, sources):
        self.BASELINE_PHASES = phases
        self.sources = sources

    def current(self):
        for path, descriptor, before in self.sources:
            require(identity(os.fstat(descriptor)) == identity(before) == identity(path.lstat()))
            require(path.resolve(strict=True) == path)

    def close(self):
        refused = False
        for _, descriptor, _ in self.sources:
            try:
                os.close(descriptor)
            except OSError:
                refused = True
        self.sources = []
        require(not refused)


def source_image(path, wanted, sources):
    before = path.lstat()
    require(path.resolve(strict=True) == path and stat.S_ISREG(before.st_mode))
    require(before.st_uid == os.geteuid() and before.st_nlink == 1)
    require(
        not before.st_mode & 0o022
        and (
            before.st_size == BUILDER_SOURCE_BYTES
            if wanted == BUILDER_SHA256
            else 0 < before.st_size <= 128 * 1024
        )
    )
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    sources.append((path, descriptor, before))
    require(identity(os.fstat(descriptor)) == identity(before))
    data = bytearray()
    while len(data) <= before.st_size:
        chunk = os.read(descriptor, before.st_size + 1 - len(data))
        if not chunk:
            break
        data.extend(chunk)
    require(len(data) == before.st_size)
    require(identity(os.fstat(descriptor)) == identity(before) == identity(path.lstat()))
    require(hashlib.sha256(data).hexdigest() == wanted)
    return data


def load_builder():
    """Import only the fixed builder's literal declaration, never its engine code."""
    root = Path(__file__).resolve().parents[1]
    sources = []
    try:
        data = source_image(root / "build/remap_runtime_build.py", BUILDER_SHA256, sources)
        source_image(
            root / "diagnostics/hs274_native_build.py",
            "ff8de375cb2fc8a801a144974418300e8e290a1efe2107338972b937d659dd80",
            sources,
        )
        declarations = [
            node
            for node in ast.parse(data).body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "BASELINE_PHASES"
                for target in node.targets
            )
        ]
        require(len(declarations) == 1)
        phases = ast.literal_eval(declarations[0].value)
        require(type(phases) is tuple and len(phases) == 19 and len(set(phases)) == 19)
        require(all(type(phase) is str and phase.isascii() for phase in phases))
        result = BuilderProjection(phases, sources)
        result.current()
        return result
    except BaseException:
        for _, descriptor, _ in sources:
            os.close(descriptor)
        raise


def strict_json(data):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value)
            value[key] = item
        return value

    def nonfinite(_value):
        raise UnsupportedObservation()

    value = json.loads(data, object_pairs_hook=unique, parse_constant=nonfinite)
    require(type(value) is dict)
    return value


def regular(info, maximum):
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid())
    require(stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1)
    require(0 <= info.st_size <= maximum)


def leaf(directory, name, capture, retained):
    """Use the held directory and retain both present and absent observations."""
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        retained.append((name, None))
        return None
    maximum = MAX_CAPTURE_BYTES if capture else MAX_RECORD_BYTES
    regular(before, maximum)
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        require(identity(os.fstat(descriptor)) == identity(before))
        data = bytearray()
        if not capture:
            while len(data) <= before.st_size:
                chunk = os.read(descriptor, before.st_size + 1 - len(data))
                if not chunk:
                    break
                data.extend(chunk)
            require(len(data) == before.st_size)
        after = os.stat(name, dir_fd=directory, follow_symlinks=False)
        require(identity(before) == identity(os.fstat(descriptor)) == identity(after))
        retained.append((name, identity(before)))
        return before.st_size if capture else strict_json(data)
    finally:
        os.close(descriptor)


def frame(record, phase, begin=False):
    require(type(record.get("schema")) is int and record["schema"] == 1)
    require(record.get("phase") == phase)
    if begin:
        require(set(record) == {"schema", "phase", "status"})
        require(record["status"] == "pending")
        return "begun"
    elapsed = record.get("elapsed_seconds")
    require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0)
    fields = {"schema", "phase", "status", "elapsed_seconds"}
    status = record.get("status")
    if phase == "xcodegen_acquisition":
        if status == "passed":
            require(set(record) == fields | {"operation", "child_process_executed"})
            require(record["operation"] == "verified-HTTPS-download-and-ordinary-extraction")
            require(record["child_process_executed"] is False)
        else:
            require(status == "refused")
            require(
                set(record)
                in (
                    fields | {"code", "acquisition_stage"},
                    fields | {"code", "acquisition_stage", "transport_diagnostic"},
                )
            )
            require(record["acquisition_stage"] in {"metadata", "archive"})
            require(
                record["code"]
                in {
                    "phase_deadline",
                    "xcodegen_transport",
                    "xcodegen_metadata",
                    "xcodegen_size",
                    "xcodegen_digest",
                    "xcodegen_archive",
                    "xcodegen_limit",
                    "xcodegen_member",
                    "xcodegen_binary",
                    "unsafe_path",
                    "owner_path",
                    "owner_mode",
                    "owner_identity",
                }
            )
            if "transport_diagnostic" in record:
                transport(record["transport_diagnostic"])
    elif status == "launch_refused":
        require(set(record) == fields)
    else:
        require(set(record) == fields | {"exit_status"})
        require(status in {"passed", "failed", "refused"})
        exit_status = record["exit_status"]
        require(type(exit_status) is int and -(2**31) <= exit_status <= 2**31 - 1)
        require(status != "passed" or exit_status == 0)
        require(status != "failed" or exit_status != 0)
    return status


def transport(value):
    """Validate the existing special writer shape without reflecting its fields."""
    require(type(value) is dict)
    kind = value.get("kind")
    optional = {"http_status": (100, 599), "verify_code": (0, 2**31 - 1), "errno": (1, 4095)}
    fields = {
        "http_status": "http_status",
        "tls_certificate_verification": "verify_code",
        "os_error": "errno",
    }
    require(
        kind
        in {
            "http_status",
            "tls_certificate_verification",
            "os_error",
            "tls_error",
            "timeout",
            "dns_resolution",
            "connection_refused",
            "connection_reset",
            "connection_error",
            "protocol_error",
            "other_transport",
            "deadline",
        }
    )
    key = fields.get(kind)
    require(set(value) == {"kind"} or key is not None and set(value) == {"kind", key})
    if key is not None and key in value:
        low, high = optional[key]
        require(type(value[key]) is int and low <= value[key] <= high)


def packet(status, rows=(), last=None):
    return {
        "schema": 1,
        "kind": "baseline_phase_observations",
        "status": status,
        "last_recorded_phase": last,
        "native_verdict": "unchanged",
        "authority": False,
        "rows": list(rows),
    }


def transport_packet(evidence=None):
    """A sibling schema reflects only the already closed transport evidence."""
    value = {
        "schema": 1,
        "kind": "xcodegen_transport_observation",
        "status": "unsupported",
        "native_verdict": "unchanged",
        "authority": False,
        "acquisition_stage": None,
        "transport_kind": None,
        "http_status": None,
        "verify_code": None,
        "errno": None,
    }
    if evidence is not None:
        stage, diagnostic = evidence
        require(stage in {"metadata", "archive"})
        transport(diagnostic)
        value.update(
            status="observed",
            acquisition_stage=stage,
            transport_kind=diagnostic["kind"],
            http_status=diagnostic.get("http_status"),
            verify_code=diagnostic.get("verify_code"),
            errno=diagnostic.get("errno"),
        )
    return value


def render(value):
    body = (
        json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":"), sort_keys=True)
        + "\n"
    )
    require(len(body.encode("ascii")) <= MAX_PUBLIC_BYTES)
    return body


def observe(owner, *, transport_only=False):
    """Sample closed metadata only; the caller owns the genuine retirement gate."""
    require(type(transport_only) is bool)
    builder = load_builder()
    try:
        owner = Path(owner)
        require(owner.is_absolute() and owner.resolve(strict=True) == owner)
        before = owner.lstat()
        require(stat.S_ISDIR(before.st_mode) and stat.S_IMODE(before.st_mode) == 0o700)
        require(before.st_uid == os.geteuid())
        directory = os.open(owner, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            require(identity(os.fstat(directory)) == identity(before))
            rows, retained, last = [], [], None
            stopped = False
            evidence = None
            for phase in builder.BASELINE_PHASES:
                begin = leaf(directory, phase + ".begin.json", False, retained)
                receipt = leaf(directory, phase + ".receipt.json", False, retained)
                stdout = leaf(directory, phase + ".stdout", True, retained)
                stderr = leaf(directory, phase + ".stderr", True, retained)
                require(begin is not None or receipt is None)
                require(begin is not None or stdout is None and stderr is None)
                if phase == "xcodegen_acquisition":
                    require(stdout is None and stderr is None)
                    stdout = stderr = "not-produced"
                else:
                    stdout = "missing" if stdout is None else stdout
                    stderr = "missing" if stderr is None else stderr
                status = "absent"
                if begin is not None:
                    require(not stopped)
                    status = frame(begin, phase, True)
                    last = phase
                    if receipt is not None:
                        status = frame(receipt, phase)
                        if (
                            transport_only
                            and phase == "xcodegen_acquisition"
                            and status == "refused"
                            and "transport_diagnostic" in receipt
                        ):
                            evidence = (
                                receipt["acquisition_stage"],
                                receipt["transport_diagnostic"],
                            )
                        if (
                            status in {"passed", "failed", "refused"}
                            and phase != "xcodegen_acquisition"
                        ):
                            require(type(stdout) is int and type(stderr) is int)
                rows.append([phase, status, stdout, stderr])
                stopped = stopped or status != "passed"
            for name, wanted in retained:
                try:
                    current = identity(os.stat(name, dir_fd=directory, follow_symlinks=False))
                except FileNotFoundError:
                    current = None
                require(current == wanted)
            require(identity(os.fstat(directory)) == identity(before) == identity(owner.lstat()))
            require(owner.resolve(strict=True) == owner)
            builder.current()
            if transport_only:
                return transport_packet(evidence)
            return packet("observed", rows, last)
        finally:
            os.close(directory)

    finally:
        builder.close()


def retired_failure(original_status, retired, read, *, unsupported=None):
    """A passive observation cannot replace the caller's original native status."""
    require(type(original_status) is int and type(retired) is bool)
    if original_status == 0 or not retired:
        return original_status, None
    try:
        summary = render(read())
    except Exception:
        summary = render(packet("unsupported") if unsupported is None else unsupported())
    return original_status, summary


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    transport_only = len(arguments) == 3 and arguments[2] == "--transport"
    try:
        require(len(arguments) == (3 if transport_only else 2))
        original = int(arguments[1])
        require(str(original) == arguments[1] and -(2**31) <= original <= 2**31 - 1)
        unchanged, result = retired_failure(
            original,
            True,
            lambda: observe(arguments[0], transport_only=transport_only),
            unsupported=transport_packet if transport_only else None,
        )
        require(unchanged == original and result is not None)
    except Exception:
        result = render(transport_packet() if transport_only else packet("unsupported"))
    sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
