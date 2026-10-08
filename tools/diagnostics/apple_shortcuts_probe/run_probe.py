#!/usr/bin/env python3
# tools/diagnostics/apple_shortcuts_probe/run_probe.py
"""Hosted read-only Shortcuts API observation; never executes a user automation."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

LIMIT = 65536
CONTRACT = "macos-shortcuts-discovery-probe"


def require(condition):
    if condition is not True:
        raise ValueError("probe_refused")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def retire(owners):
    old = {}
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            old[sig] = signal.signal(sig, signal.SIG_IGN)
        for group in owners:
            require(group.settle())
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


class ProbeObservationRefused(ValueError):
    """Closed diagnostic cause; neither private native text nor a success verdict."""

    def __init__(self, kind):
        super().__init__("probe_refused")
        self.kind = kind


def permission_preflight_summary(raw, role):
    """Parse only a fixed optional diagnostic segment in this owned discovery stream."""
    absent = {"state": "absent", "call_attempted": False, "native_returned": False}
    invalid = {"state": "invalid_grammar", "call_attempted": False, "native_returned": False}
    if type(raw) is not bytes or len(raw) > LIMIT:
        return None, invalid
    if role != "discovery" or b"ASCP:P:" not in raw:
        return raw, absent
    prefix = b"ASCP:1\nASCP:P:BEGIN\n"
    if not raw.startswith(prefix):
        return None, invalid
    remainder = raw[len(prefix) :]
    unavailable_parts = {
        b"ASCP:B:API": "api",
        b"ASCP:B:METADATA": "metadata",
        b"ASCP:B:CONSTANTS": "constants",
        b"ASCP:B:DESCRIPTOR": "descriptor",
        b"ASCP:B:POINTER": "pointer",
    }
    unavailable_part = None
    if remainder.startswith(b"ASCP:B:"):
        label, separator, remainder = remainder.partition(b"\n")
        if not separator or label not in unavailable_parts:
            return None, invalid
        if not remainder.startswith(b"ASCP:P:UNAVAILABLE\n"):
            return None, invalid
        unavailable_part = unavailable_parts[label]
    attempted = False
    call = b"ASCP:P:CALL_ATTEMPT\n"
    if remainder.startswith(call):
        attempted = True
        remainder = remainder[len(call) :]
    if remainder == b"":
        return b"ASCP:1\n", {
            "state": "call_unreturned" if attempted else "preparing",
            "call_attempted": attempted,
            "native_returned": False,
        }
    line, separator, tail = remainder.partition(b"\n")
    if not separator:
        return None, invalid
    endings = {
        b"ASCP:P:UNAVAILABLE": "bridge_unavailable",
        b"ASCP:P:REFUSED": "bridge_refused",
        b"ASCP:P:INVALID": "invalid_native_status",
    }
    packet = {"call_attempted": attempted, "native_returned": False}
    if line.startswith(b"ASCP:P:RETURN:") and attempted:
        encoded = line[len(b"ASCP:P:RETURN:") :]
        try:
            text = encoded.decode("ascii")
            code = int(text)
        except (UnicodeDecodeError, ValueError):
            return None, invalid
        if str(code) != text or not -2147483648 <= code <= 2147483647:
            return None, invalid
        packet.update({"state": "observed", "native_returned": True, "code": code})
    elif line in endings:
        if (line == b"ASCP:P:UNAVAILABLE" and attempted) or (
            line == b"ASCP:P:INVALID" and not attempted
        ):
            return None, invalid
        packet["state"] = endings[line]
        if unavailable_part is not None:
            packet["unavailable_part"] = unavailable_part
    else:
        return None, invalid
    expected = [b"ASCP:2\n", b"ASCP:3\n", b"ASCP:4\n"]
    if tail not in [b"".join(expected[:count]) for count in range(4)]:
        return None, invalid
    return b"ASCP:1\n" + tail, packet


def checkpoint_summary(raw, role):
    """Admit only an ordered fixed marker prefix, never native names or errors."""
    expected = [b"ASCP:1\n", b"ASCP:2\n", b"ASCP:3\n", b"ASCP:4\n"]
    raw, _ = permission_preflight_summary(raw, role)
    if role != "discovery":
        return {"valid": raw == b"", "last": 0}
    for count in range(5):
        if raw == b"".join(expected[:count]):
            return {"valid": True, "last": count}
    return {"valid": False, "last": 0}


def terminal_summary(observation, group):
    """Copy the existing WNOWAIT sample before retirement, with exact child binding."""
    if observation is None:
        return None
    values = [getattr(observation, key, None) for key in ("si_pid", "si_code", "si_status")]
    if (
        any(type(value) is not int for value in values)
        or values[0] != group.process.pid
        or values[0] <= 0
        or not 1 <= values[1] <= 6
        or not 0 <= values[2] <= 255
    ):
        raise ProbeObservationRefused("terminal_shape")
    return dict(zip(("pid", "code", "status"), values))


def observation_interrupted(error, ownership):
    """Recognize the exact native owner's cancellation without replacing its object."""
    interruption = getattr(ownership, "OwnedProcessInterrupted", None)
    return not isinstance(error, Exception) or (
        isinstance(interruption, type)
        and issubclass(interruption, BaseException)
        and isinstance(error, interruption)
    )


def capture(arguments, native, ownership, evidence, role):
    owners = []
    started = time.monotonic()
    failure_kind = "none"
    observed_terminal = None
    primary_error = None
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            group = ownership.acquire_owned(
                arguments, native, owners.append, stdout=out, stderr=err
            )
            deadline = time.monotonic() + 20
            while True:
                observation = group.observe_exit()
                if observation is not None:
                    observed_terminal = terminal_summary(observation, group)
                    break
                if time.monotonic() >= deadline:
                    raise ProbeObservationRefused("deadline")
                if os.fstat(out.fileno()).st_size > LIMIT or os.fstat(err.fileno()).st_size > LIMIT:
                    raise ProbeObservationRefused("output_bound")
                time.sleep(0.02)
        except BaseException as error:
            primary_error = error
            failure_kind = (
                error.kind if isinstance(error, ProbeObservationRefused) else "capture_refused"
            )
            raise
        finally:
            acknowledged = False
            retirement_error = None
            try:
                retire(owners)
                acknowledged = True
            except BaseException as error:
                # The original retirement refusal keeps priority over capture.
                retirement_error = error
                raise
            finally:
                pending_error = retirement_error if retirement_error is not None else primary_error
                observation = {
                    "failure": failure_kind,
                    "terminal_before_retirement": observed_terminal,
                    "metadata_available": False,
                    "metadata_failure": "pending",
                }
                diagnostic_error = None
                try:
                    elapsed_us = min(
                        86400000000, max(0, int((time.monotonic() - started) * 1000000))
                    )
                    stdout_bytes = os.fstat(out.fileno()).st_size
                    stderr_bytes = os.fstat(err.fileno()).st_size
                    checkpoint = _checkpoint_from_capture(err, role)
                    if (
                        type(stdout_bytes) is not int
                        or stdout_bytes < 0
                        or type(stderr_bytes) is not int
                        or stderr_bytes < 0
                        or type(checkpoint) is not dict
                        or set(checkpoint) != {"valid", "last"}
                        or type(checkpoint["valid"]) is not bool
                        or type(checkpoint["last"]) is not int
                        or not 0 <= checkpoint["last"] <= 4
                        or (checkpoint["valid"] is False and checkpoint["last"] != 0)
                    ):
                        raise ProbeObservationRefused("diagnostic_shape")
                    err.seek(0)
                    _, preflight = permission_preflight_summary(err.read(LIMIT + 1), role)
                    if preflight["state"] == "invalid_grammar":
                        raise ProbeObservationRefused("diagnostic_shape")
                    if preflight["state"] != "absent":
                        observation["permission_preflight"] = preflight
                    observation.update(
                        {
                            "elapsed_us": elapsed_us,
                            "stdout_bytes": stdout_bytes,
                            "stderr_bytes": stderr_bytes,
                            "checkpoint": checkpoint,
                            "metadata_available": True,
                            "metadata_failure": "none",
                        }
                    )
                except BaseException as error:
                    diagnostic_error = error
                    if observation_interrupted(error, ownership):
                        observation["metadata_failure"] = "observation_interrupted"
                    elif isinstance(error, OSError):
                        observation["metadata_failure"] = "capture_io"
                    elif isinstance(error, ProbeObservationRefused):
                        observation["metadata_failure"] = error.kind
                    else:
                        observation["metadata_failure"] = "capture_refused"
                    if failure_kind == "none":
                        observation["failure"] = observation["metadata_failure"]
                evidence.append(
                    {
                        "role": role,
                        "registered": len(owners),
                        "retirement_ack": acknowledged,
                        "groups": [retained.receipt() for retained in owners],
                        "observation": observation,
                    }
                )
                if diagnostic_error is not None:
                    # A new cancellation wins even over an earlier ordinary
                    # error. Optional metadata IO cannot replace a pending one.
                    if observation_interrupted(diagnostic_error, ownership):
                        raise diagnostic_error
                    if pending_error is None:
                        raise ProbeObservationRefused(observation["metadata_failure"]) from None
        if group.process.returncode != 0:
            evidence[-1]["observation"]["failure"] = "native_exit"
            raise ProbeObservationRefused("native_exit")
        out.seek(0)
        err.seek(0)
        raw, errors = out.read(LIMIT + 1), err.read(LIMIT + 1)
        if not 0 < len(raw) <= LIMIT or len(errors) > LIMIT:
            evidence[-1]["observation"]["failure"] = "output_bound"
            raise ProbeObservationRefused("output_bound")
        checkpoints = checkpoint_summary(errors, role)
        if not checkpoints["valid"]:
            evidence[-1]["observation"]["failure"] = "diagnostic_shape"
            raise ProbeObservationRefused("diagnostic_shape")
        return raw


def _checkpoint_from_capture(stream, role):
    """Read the same acquired temporary descriptor after physical retirement."""
    stream.seek(0)
    return checkpoint_summary(stream.read(LIMIT + 1), role)


def validate(raw):
    require(type(raw) is bytes and 0 < len(raw) <= LIMIT)
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    require(type(value) is dict and type(value.get("version")) is int and value["version"] == 1)
    if value.get("status") in ("refused", "stale"):
        require(set(value) == {"version", "status", "stage", "reason"})
        require(type(value["stage"]) is int and 1 <= value["stage"] <= 5)
        require(value["reason"] in ("native_refused", "automation_permission_refused"))
        return {
            "observed": False,
            "status": value["status"],
            "stage": value["stage"],
            "reason": value["reason"],
        }
    require(value.get("status") == "observed")
    require(set(value) == {"version", "status", "choices", "truncated"})
    require(
        type(value["choices"]) is list
        and len(value["choices"]) <= 64
        and type(value["truncated"]) is bool
    )
    identifiers = set()
    for row in value["choices"]:
        require(type(row) is dict and set(row) == {"id", "name", "accepts_input"})
        require(type(row["id"]) is str and 0 < len(row["id"].encode("utf-8")) <= 256)
        require(type(row["name"]) is str and len(row["name"].encode("utf-8")) <= 4096)
        require("\0" not in row["name"] and "\0" not in row["id"] and row["id"] not in identifiers)
        require(type(row["accepts_input"]) is bool)
        identifiers.add(row["id"])
    # Never emit or persist discovered identifiers/names, even hashed names.
    return {
        "observed": True,
        "observed_choices": len(value["choices"]),
        "truncated": value["truncated"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin" and sys.version_info >= (3, 13))
    require(re.fullmatch("[0-9a-f]{40}", args.source_sha) is not None)
    root = args.source_root.resolve()
    owner_path = root / "tools/diagnostics/macos_owned_process.py"
    script = Path(__file__).with_name("discover.js").resolve()
    source_files = (owner_path, Path(__file__).resolve(), script)
    hashes = {}
    for path in source_files:
        relative = str(path.relative_to(root))
        raw = path.read_bytes()
        require(
            subprocess.check_output(["git", "show", args.source_sha + ":" + relative], cwd=root)
            == raw
        )
        hashes[relative] = hashlib.sha256(raw).hexdigest()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("native_shortcuts_owner", owner_path)
    ownership = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ownership)

    def interrupted(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("probe_interrupted")

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    native = ownership.NativeProcessGroups()
    evidence = []
    result = {
        "schema": 1,
        "contract": CONTRACT,
        "source_sha": args.source_sha,
        "source_hashes": hashes,
        "discovery_observed": False,
        "invocation_qualified": False,
        "automation_cancellation_qualified": False,
        "native_catalogue_retrieval_bounded": False,
        "cli_identifier_help_observed": False,
        "physical_operations": evidence,
        "permission": "not_determined",
        "reason": "probe_refused",
    }
    failure = True
    try:
        for tool in ("/usr/bin/osascript", "/usr/bin/shortcuts"):
            info = os.stat(tool)
            require(stat.S_ISREG(info.st_mode) and bool(info.st_mode & 0o111))
        help_bytes = capture(
            ["/usr/bin/shortcuts", "run", "--help"], native, ownership, evidence, "cli_help"
        )
        require(b"shortcut-name-or-identifier" in help_bytes)
        result["cli_identifier_help_observed"] = True
        raw = capture(
            ["/usr/bin/osascript", "-l", "JavaScript", str(script), "--permission-preflight"],
            native,
            ownership,
            evidence,
            "discovery",
        )
        observed = validate(raw)
        result["inventory"] = observed
        result["discovery_observed"] = observed["observed"]
        if observed["observed"]:
            result["reason"] = "none"
            failure = False
        else:
            result["reason"] = observed["reason"]
            if observed["reason"] == "automation_permission_refused":
                result["permission"] = "refusal_code_observed"
        for path in source_files:
            require(
                hashlib.sha256(path.read_bytes()).hexdigest() == hashes[str(path.relative_to(root))]
            )
    except Exception:
        failure = True
        result["discovery_observed"] = False
        result["reason"] = "probe_refused"
    finally:
        # Includes exact physical receipts on declined native API/start/timeout,
        # without including stdout, stderr, identifiers or discovered names.
        (args.output / "observation.json").write_text(json.dumps(result, sort_keys=True) + "\n")
        print(json.dumps(result, sort_keys=True))
    return 1 if failure else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        print(
            json.dumps(
                {
                    "contract": CONTRACT,
                    "discovery_observed": False,
                    "invocation_qualified": False,
                    "automation_cancellation_qualified": False,
                    "reason": "probe_refused",
                }
            )
        )
        raise SystemExit(1)
