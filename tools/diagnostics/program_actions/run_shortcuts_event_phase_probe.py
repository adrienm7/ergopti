#!/usr/bin/env python3
# tools/diagnostics/program_actions/run_shortcuts_event_phase_probe.py
"""Bounded readonly native comparators; never infer the old JXA stall's cause."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

BASELINE = "72599cb78fc02d5ae9656d94a8e31d09eb4adbbb"
DIRECTORY = "tools/diagnostics/program_actions/"
OWNED = "tools/diagnostics/macos_owned_process.py"
RETAINED = {}


class Refused(RuntimeError):
    """Closed observation failure; native error text never enters evidence."""


def require(value, reason):
    if not value:
        raise Refused(reason)


def digest(path):
    require(path.is_file() and not path.is_symlink(), "nonregular_source")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_frames(raw, role):
    """Admit only one ordered native phase prefix, including stopped prefixes."""
    require(type(raw) is bytes and len(raw) <= 4096, "phase_limit")
    require(role in {"raw-version", "sb-count", "native-fixture"}, "unknown_role")
    lines = raw.splitlines(keepends=True)
    frames = []
    for line in lines:
        match = re.fullmatch(rb"EP1 ([A-Z_]+) (-?(?:0|[1-9][0-9]*))\n", line)
        require(match is not None, "invalid_phase_frame")
        value = int(match[2])
        require(-(2**31) <= value < 2**31, "invalid_phase_value")
        frames.append((match[1].decode(), value))
    require(len(frames) <= 24, "phase_limit")
    position = 0
    values = {}

    class PrefixEnd(Exception):
        pass

    def take(name, allowed=None):
        nonlocal position
        if position == len(frames):
            raise PrefixEnd()
        phase, value = frames[position]
        require(phase == name and (allowed is None or value in allowed), "phase_order")
        require(name not in values, "duplicate_phase")
        values[name] = value
        position += 1
        return value

    def optional(name):
        return position < len(frames) and frames[position][0] == name

    complete = False
    try:
        if role == "native-fixture":
            take("FIXTURE", {1})
            take("FIXTURE_STATUS")
            take("FIXTURE_HANDLER", {0, 1})
            complete = True
        else:
            take("START", {1 if role == "raw-version" else 2})
            endpoint = take("ENDPOINT", {0, 1})
            if endpoint:
                take("RUNNING_BEFORE", {0, 1, 2})
                if optional("REQUEST_REFUSED"):
                    require(take("REQUEST_REFUSED") != 0, "invalid_refusal")
                else:
                    take("PREFLIGHT_ENTER", {0})
                    take("PREFLIGHT_RETURN")
                    if role == "raw-version":
                        if optional("REQUEST_REFUSED"):
                            require(take("REQUEST_REFUSED") != 0, "invalid_refusal")
                        else:
                            take("RAW_SEND_ENTER", {0})
                            if take("RAW_SEND_RETURN") == 0:
                                correlated = take("REPLY_CORRELATED", {0, 1})
                                shape = take("REPLY_ERROR_SHAPE", {0, 1})
                                take("REPLY_ERROR")
                                service = take("SERVICE_REPLY", {0, 1})
                                require(
                                    not service or correlated and shape,
                                    "unproved_service_reply",
                                )
                    else:
                        take("SB_CONSTRUCT_ENTER", {0})
                        if take("SB_CONSTRUCT_RETURN", {0, 1}):
                            take("SB_COLLECTION_ENTER", {0})
                            collection = take("SB_COLLECTION_RETURN", {0, 1})
                            if optional("SB_COUNT_ENTER"):
                                require(collection == 1, "invalid_count")
                                take("SB_COUNT_ENTER", {0})
                                take("SB_COUNT_RETURN", {0, 1})
                            failed = take("SB_FAILED", {0, 1})
                            error = take("SB_ERROR")
                            require(failed or error == 0, "invented_sb_error")
                            require(
                                values.get("SB_COUNT_RETURN") != 1 or not failed,
                                "failed_sb_count",
                            )
                    take("RUNNING_AFTER", {0, 1, 2})
            take("END", {0})
            complete = True
    except PrefixEnd:
        pass
    require(position == len(frames), "extra_phase")
    return {
        "complete": complete,
        "last": frames[-1][0] if frames else "none",
        "values": values,
    }


def facts(parsed, role, retired):
    """Keep sender-specific facts separate from catalogue and historical causes."""
    values = parsed["values"]
    return {
        "sender_equal_to_baseline": False,
        "effective_tcc_principal_proved": False,
        "effective_tcc_principal_equal_to_baseline": None,
        "baseline_cause": "not_determined",
        "catalogue_observed": False,
        "invocation_qualified": False,
        "remote_cancellation_qualified": False,
        "opaque_native_allocation_bounded": False,
        "fixture_only": role == "native-fixture",
        "endpoint_verified": values.get("ENDPOINT") == 1,
        "running_before_observed": values.get("RUNNING_BEFORE") == 1,
        "running_after_observed": values.get("RUNNING_AFTER") == 1,
        "permission_status": values.get("PREFLIGHT_RETURN"),
        "permission_event": "core/getd" if "PREFLIGHT_ENTER" in values else None,
        "send_entered": "RAW_SEND_ENTER" in values,
        "send_returned": "RAW_SEND_RETURN" in values,
        "send_status": values.get("RAW_SEND_RETURN"),
        "reply_correlated": values.get("REPLY_CORRELATED") == 1,
        "reply_error": values.get("REPLY_ERROR")
        if values.get("REPLY_ERROR_SHAPE") == 1
        else None,
        "service_reply_proved": retired and values.get("SERVICE_REPLY") == 1,
        "sb_count_returned": "SB_COUNT_RETURN" in values,
        "sb_failed": values.get("SB_FAILED") == 1,
        "sb_error": values.get("SB_ERROR") if values.get("SB_FAILED") == 1 else None,
    }


def operation_reason(parsed, role):
    """Typed current-sender outcomes never become a historical TCC explanation."""
    value = parsed["values"]
    if role == "native-fixture":
        return (
            "none"
            if value.get("FIXTURE_STATUS") == 0 and value.get("FIXTURE_HANDLER") == 1
            else "native_fixture_refused"
        )
    if value.get("ENDPOINT") != 1:
        return "endpoint_not_verified"
    code = (
        value.get("RAW_SEND_RETURN") if role == "raw-version" else value.get("SB_ERROR")
    )
    if code == -1744:
        return "this_sender_would_require_consent"
    if code == -1743:
        return "this_sender_permission_refused"
    if code == -600:
        return "this_sender_target_not_found"
    if code == -1712:
        return "this_sender_event_timeout"
    if role == "raw-version":
        if code != 0:
            return "native_send_refused"
        if value.get("REPLY_CORRELATED") != 1 or value.get("REPLY_ERROR_SHAPE") != 1:
            return "reply_not_validated"
        if value.get("REPLY_ERROR") != 0:
            return "remote_read_refused"
        if value.get("SERVICE_REPLY") != 1:
            return "reply_source_not_proved"
    elif value.get("SB_COUNT_RETURN") != 1 or value.get("SB_FAILED") != 0:
        return "native_bridge_refused"
    return "none"


def load_owner(root):
    spec = importlib.util.spec_from_file_location("native_phase_owner", root / OWNED)
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    return owner


def terminal_sample(observation, group):
    """Copy an unreaped native sample only when it binds this acquired leader."""
    values = [
        getattr(observation, name, None) for name in ("si_pid", "si_code", "si_status")
    ]
    require(
        all(type(value) is int for value in values)
        and values[0] == group.process.pid
        and values[0] > 0
        and 1 <= values[1] <= 6
        and 0 <= values[2] <= 255,
        "terminal_shape_refused",
    )
    return dict(zip(("pid", "code", "status"), values))


def capture(arguments, native, owner, timeout, limit=4096, cwd=None):
    """A twenty-second business limit never releases uncertain native custody."""
    started = time.monotonic()
    group = None
    failure = "none"
    observed_terminal = None
    business_elapsed_us = None
    old = {}

    def interrupted(_signum, _frame):
        raise Refused("interrupted")

    def register(acquired):
        nonlocal group
        group = acquired
        RETAINED[id(group)] = group

    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            for signum in (signal.SIGTERM, signal.SIGINT):
                old[signum] = signal.signal(signum, interrupted)
            owner.acquire_owned(
                arguments, native, register, stdout=out, stderr=err, cwd=cwd
            )
            while True:
                # Deadline includes acquisition; no payload or bridge phase resets it.
                if time.monotonic() - started >= timeout:
                    raise Refused("deadline")
                if (
                    os.fstat(out.fileno()).st_size > limit
                    or os.fstat(err.fileno()).st_size > limit
                ):
                    raise Refused("output_limit")
                observation = group.observe_exit()
                if observation is not None:
                    observed_terminal = terminal_sample(observation, group)
                    break
                time.sleep(0.02)
        except BaseException as error:
            failure = (
                str(error) if isinstance(error, Refused) else "native_capture_refused"
            )
        finally:
            business_elapsed_us = max(0, int((time.monotonic() - started) * 1000000))
            try:
                for signum in old:
                    signal.signal(signum, signal.SIG_IGN)
                if group is not None:
                    while True:
                        closed = False
                        if not group.reservation_lost and not group.reap_started:
                            try:
                                closed = group.settle()
                            except Exception:
                                pass
                        elif group.reaped:
                            closed = True
                        if closed:
                            del RETAINED[id(group)]
                            break
                        # No signal/reap retry after loss. Keep owner and streams alive.
                        time.sleep(0.1)
            finally:
                for signum, previous in old.items():
                    signal.signal(signum, previous)
        sizes = {
            "stdout_bytes": os.fstat(out.fileno()).st_size,
            "stderr_bytes": os.fstat(err.fileno()).st_size,
        }
        require(group is not None and group.reaped, "unretired_capture")
        oversized = sizes["stdout_bytes"] > limit or sizes["stderr_bytes"] > limit
        if oversized and failure == "none":
            failure = "output_limit"
        out.seek(0)
        return {
            "failure": failure,
            "status": group.process.returncode,
            "retired": True,
            "business_deadline_seconds": timeout,
            "business_elapsed_us": business_elapsed_us,
            "terminal_before_retirement": observed_terminal,
            "receipt": group.receipt(),
            **sizes,
        }, b"" if oversized else out.read(limit)


def source_snapshot(root, sha):
    require(re.fullmatch("[0-9a-f]{40}", sha), "source_refused")
    require(
        subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root).decode().strip()
        == sha,
        "source_refused",
    )
    require(
        os.environ.get("GITHUB_SHA") == sha
        and os.environ.get("GITHUB_ACTIONS") == "true",
        "source_refused",
    )
    require(
        re.fullmatch("[1-9][0-9]*", os.environ.get("GITHUB_RUN_ID", ""))
        and re.fullmatch("[1-9][0-9]*", os.environ.get("GITHUB_RUN_ATTEMPT", "")),
        "ci_identity_refused",
    )
    paths = [OWNED] + [
        DIRECTORY + name
        for name in [
            "ShortcutsEventPhaseProbe.m",
            "run_shortcuts_event_phase_probe.py",
            "test_shortcuts_event_phase_probe.py",
            "README-shortcuts-event-phase.md",
        ]
    ]
    hashes = {}
    for relative in paths:
        require(
            subprocess.check_output(["git", "show", sha + ":" + relative], cwd=root)
            == (root / relative).read_bytes(),
            "source_refused",
        )
        hashes[relative] = digest(root / relative)
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--baseline-sha", default=BASELINE)
    parser.add_argument(
        "--role", choices=["raw-version", "sb-count", "native-fixture"], required=True
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(
        sys.platform == "darwin" and sys.version_info >= (3, 13), "native_unavailable"
    )
    root = args.source_root.resolve()
    hashes = source_snapshot(root, args.source_sha)
    require(args.baseline_sha == BASELINE, "baseline_refused")
    baseline = subprocess.check_output(
        [
            "git",
            "show",
            BASELINE + ":tools/diagnostics/apple_shortcuts_probe/discover.js",
        ],
        cwd=root,
    )
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {
        "schema": 1,
        "contract": "readonly-shortcuts-event-phase",
        "result": "REFUSED",
        "reason": "native_unavailable",
        "source_sha": args.source_sha,
        "source_hashes": hashes,
        "baseline_sha": BASELINE,
        "baseline_discover_sha256": hashlib.sha256(baseline).hexdigest(),
        "baseline_cause": "not_determined",
        "role": args.role,
        "sender_equal_to_baseline": False,
        "catalogue_observed": False,
        "invocation_qualified": False,
        "remote_cancellation_qualified": False,
        "native_execution": True,
        "ci_run_id": os.environ.get("GITHUB_RUN_ID"),
        "ci_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "captures": [],
    }
    exit_status = 1
    try:
        owner = load_owner(root)
        native = owner.NativeProcessGroups()
        clang = Path(
            subprocess.check_output(["/usr/bin/xcrun", "--find", "clang"], timeout=10)
            .decode()
            .strip()
        )
        compiler_target = clang.resolve(strict=True)
        compiler_hash = digest(compiler_target)
        worker = args.output.absolute() / "ShortcutsEventPhaseProbe"
        command = [
            str(clang),
            "-fobjc-arc",
            "-mmacosx-version-min=13.0",
            "-O0",
            str(root / DIRECTORY / "ShortcutsEventPhaseProbe.m"),
            "-framework",
            "AppKit",
            "-framework",
            "Foundation",
            "-framework",
            "CoreServices",
            "-framework",
            "ScriptingBridge",
            "-framework",
            "Security",
            "-o",
            str(worker),
        ]
        if args.role == "native-fixture":
            command.insert(1, "-DERGOPTI_PHASE_FIXTURE=1")
        compiled, _private = capture(command, native, owner, 120, 65536, root)
        result["captures"].append({"operation": "compile", **compiled})
        require(
            compiled["failure"] == "none" and compiled["status"] == 0, "compile_refused"
        )
        require(
            source_snapshot(root, args.source_sha) == hashes
            and clang.resolve(strict=True) == compiler_target
            and digest(compiler_target) == compiler_hash,
            "compiler_source_changed",
        )
        signed, _private = capture(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                "com.ergoptiplus.diagnostics.shortcuts-event-phase",
                str(worker),
            ],
            native,
            owner,
            10,
            65536,
        )
        result["captures"].append({"operation": "sign", **signed})
        require(
            signed["failure"] == "none" and signed["status"] == 0, "signature_refused"
        )
        verified, _private = capture(
            ["/usr/bin/codesign", "--verify", "--strict", str(worker)],
            native,
            owner,
            10,
            65536,
        )
        result["captures"].append({"operation": "verify-signature", **verified})
        require(
            verified["failure"] == "none" and verified["status"] == 0,
            "signature_refused",
        )
        result["worker_sha256"] = digest(worker)
        result["compiler_target_sha256"] = compiler_hash
        observed, raw = capture([str(worker), args.role], native, owner, 20)
        result["captures"].append({"operation": "observe", **observed})
        require(
            digest(worker) == result["worker_sha256"]
            and source_snapshot(root, args.source_sha) == hashes,
            "source_changed",
        )
        parsed = parse_frames(raw, args.role)
        result["last_phase"] = parsed["last"]
        result["phase_values"] = parsed["values"]
        result.update(facts(parsed, args.role, observed["retired"]))
        require(
            observed["failure"] == "none"
            and observed["status"] == 0
            and parsed["complete"],
            observed["failure"] if observed["failure"] != "none" else "native_refused",
        )
        reason = operation_reason(parsed, args.role)
        require(reason == "none", reason)
        if args.role == "native-fixture":
            result["result"] = "FIXTURE_ONLY"
        else:
            result["result"] = "PARTIAL_READONLY_COMPARATOR"
        result["reason"] = "baseline_cause_not_determined"
        exit_status = 2  # Refusal and readonly comparisons are never a product qualification PASS.
    except (Refused, OSError, ValueError, subprocess.SubprocessError) as error:
        result["reason"] = (
            str(error) if isinstance(error, Refused) else "native_refused"
        )
        if result.get("captures") and result["captures"][-1].get("failure") != "none":
            result["reason"] = result["captures"][-1]["failure"]
    finally:
        with (args.output / "observation.json").open("x", encoding="utf-8") as stream:
            json.dump(result, stream, sort_keys=True, indent=2)
            stream.write("\n")
    return exit_status


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Refused, OSError, ValueError, subprocess.SubprocessError):
        print("Readonly event phase probe REFUSED", file=sys.stderr)
        raise SystemExit(1)
