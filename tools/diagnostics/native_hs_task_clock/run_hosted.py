"""PRIVATE hosted mechanism experiment; not enrolled and never a lease authority."""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
import re
import types
from pathlib import Path
import secrets
import signal
import stat
import subprocess
import sys
import tempfile


def load(name, path, root, revision):
    # Execute exact held Git/source bytes, never an old Python bytecode cache.
    relative = str(path.relative_to(root))
    held = subprocess.check_output(["git", "-C", str(root), "show", revision + ":" + relative])
    if path.read_bytes() != held:
        raise ValueError("source_custody_refused")
    module = types.ModuleType(name)
    module.__file__ = str(path)
    exec(compile(held, str(path), "exec"), module.__dict__)
    return module


def main():
    parser = argparse.ArgumentParser()
    for name in ("source-root", "source-sha", "output", "app", "archive"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    root, output = Path(args.source_root).resolve(), Path(args.output)
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
        raise ValueError("source_revision_refused")
    head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"]).decode().strip()
    if head != args.source_sha:
        raise ValueError("source_head_refused")
    here = Path(__file__).resolve().parent
    expected_here = root / "tools/diagnostics/native_hs_task_clock"
    if here != expected_here:
        raise ValueError("diagnostic_origin_refused")
    diagnostic_pins = {}
    for name in ("run_hosted.py", "fixture.lua", "controlled_child.py"):
        relative = "tools/diagnostics/native_hs_task_clock/" + name
        held = subprocess.check_output(
            ["git", "-C", str(root), "show", args.source_sha + ":" + relative]
        )
        if (here / name).is_symlink() or (here / name).read_bytes() != held:
            raise ValueError("diagnostic_source_custody_refused")
        diagnostic_pins[name] = hashlib.sha256(held).hexdigest()
    api = load(
        "verified_hs_runner",
        root / "tools/diagnostics/native_hs_program_providers/run_native.py",
        root,
        args.source_sha,
    )
    metadata_token = api.validate_metadata_token(os.environ.pop(api.METADATA_TOKEN_ENV, None))
    api.require(sys.platform == "darwin" and sys.version_info >= (3, 13), "native_python_refused")
    owner = load(
        "native_owner", root / "tools/diagnostics/macos_owned_process.py", root, args.source_sha
    )

    def interrupted(_signal, _frame):
        raise owner.OwnedProcessInterrupted("owned_experiment_interrupted")

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    native = owner.NativeProcessGroups()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    asset = api.trusted_asset(output, metadata_token=metadata_token)
    metadata_token = None
    api.verify_archive(Path(args.archive), asset)
    binary, domain = api.verify_bundle(Path(args.app), Path(args.archive), native, owner)
    graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayPixelsWide.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayPixelsWide.restype = ctypes.c_size_t
    api.require(
        graphics.CGDisplayPixelsWide(graphics.CGMainDisplayID()) > 0, "window_server_refused"
    )
    paths = tuple(
        "static/ergopti_plus/macos/" + x
        for x in (
            "adapters/shell_runner.lua",
            "adapters/timer_scheduler.lua",
            "adapters/task_environment.lua",
            "infra/deferred_work.lua",
            "infra/launcher_environment.lua",
        )
    ) + ("static/ergopti_plus/_shared/lua/diagnostics/runtime_log.lua",)
    pins = api.source_hashes(root, args.source_sha, paths)
    _, _, present = api.owned_tool(
        ["/usr/bin/pgrep", "-x", "Hammerspoon"], native, owner, accepted=(0, 1)
    )
    api.require(present == 1, "existing_hammerspoon_session_refused")
    preference = ["/usr/bin/defaults", "read", domain, "MJConfigFile"]
    before, _, before_status = api.owned_tool(preference, native, owner, accepted=(0, 1))
    base = Path(tempfile.mkdtemp(prefix="task-clock-", dir=output))
    base.chmod(0o700)
    nonce = secrets.token_hex(16)
    receipt, child_receipt = base / "lua.json", base / "child.json"
    value = dict(
        source_root=str(root),
        source_sha=args.source_sha,
        nonce=nonce,
        receipt=str(receipt),
        child_receipt=str(child_receipt),
        python=str(Path(sys.executable).resolve()),
        child=str(here / "controlled_child.py"),
    )
    startup = base / "init.lua"
    startup.write_text(
        (here / "fixture.lua")
        .read_text()
        .replace("__INPUT_JSON__", api.lua_string(json.dumps(value)))
    )
    owners = []
    try:
        _, _, present = api.owned_tool(
            ["/usr/bin/pgrep", "-x", "Hammerspoon"], native, owner, accepted=(0, 1)
        )
        api.require(present == 1, "existing_hammerspoon_session_refused")
        environment = dict(os.environ, PATH="/usr/bin:/bin")
        environment.pop("__CFBundleIdentifier", None)
        environment.pop("__CFBundlePath", None)
        group = owner.acquire_owned(
            [
                str(binary),
                "-MJConfigFile",
                str(startup),
                "-SUEnableAutomaticChecks",
                "NO",
                "-SUHasLaunchedBefore",
                "YES",
            ],
            native,
            owners.append,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        api.await_packet(receipt, group)  # Original45 seconds; no new retry/poll policy.
        packet = api.read_packet(receipt)
        group.wait_for_exit(5)
        api.require(group.process.returncode == 0, "owned_runtime_failed")
    finally:
        api.settle_registered(owners)
        after, _, after_status = api.owned_tool(preference, native, owner, accepted=(0, 1))
        api.require(
            before == after and before_status == after_status, "persistent_preference_changed"
        )
    fields = {
        "schema",
        "contract",
        "source_sha",
        "nonce",
        "pid",
        "outcome",
        "events",
        "startup_prompt_state",
        "native_lease_authority",
    }
    api.require(
        type(packet) is dict
        and set(packet) == fields
        and type(packet["schema"]) is int
        and packet["schema"] == 1
        and packet["contract"] == "hosted-hs-task-five-boundary"
        and packet["source_sha"] == args.source_sha
        and packet["nonce"] == nonce
        and type(packet["pid"]) is int
        and packet["pid"] == group.process.pid
        and packet["outcome"] == "observed-task-boundaries"
        and packet["startup_prompt_state"] == "unobserved"
        and packet["native_lease_authority"] is False,
        "lua_receipt_refused",
    )
    opened = child_receipt.lstat()
    api.require(
        stat.S_ISREG(opened.st_mode)
        and opened.st_uid == os.getuid()
        and opened.st_nlink == 1
        and stat.S_IMODE(opened.st_mode) == 0o600,
        "child_identity_refused",
    )
    child = api.read_packet(child_receipt)
    api.require(
        type(child) is dict
        and set(child) == {"schema", "outcome", "events"}
        and type(child["schema"]) is int
        and child["schema"] == 1
        and child["outcome"] == "completed",
        "child_receipt_refused",
    )
    lua_order = (
        "timer-tick",
        "stdin-request-accepted",
        "lua-stream-entry",
        "matching-sequence-admitted",
    )
    api.require(
        type(packet["events"]) is list
        and len(packet["events"]) == 12
        and type(child["events"]) is list
        and len(child["events"]) == 3,
        "event_count_refused",
    )
    for events, clock, expected in (
        (packet["events"], "hs-absolute-relative", [(s, k) for s in (1, 2, 3) for k in lua_order]),
        (
            child["events"],
            "child-monotonic-relative",
            [(s, "controlled-child-ack-write") for s in (1, 2, 3)],
        ),
    ):
        previous = -1
        for event, (seq, boundary) in zip(events, expected):
            api.require(
                type(event) is dict
                and set(event) == {"seq", "boundary", "clock", "elapsed_ns"}
                and type(event["seq"]) is int
                and event["seq"] == seq
                and event["boundary"] == boundary
                and event["clock"] == clock
                and type(event["elapsed_ns"]) is int
                and 0 <= event["elapsed_ns"] <= 45_000_000_000
                and previous <= event["elapsed_ns"],
                "event_shape_refused",
            )
            previous = event["elapsed_ns"]
    api.require(api.source_hashes(root, args.source_sha, paths) == pins, "source_drift")
    api.require(
        all(
            hashlib.sha256((here / p).read_bytes()).hexdigest() == h
            for p, h in diagnostic_pins.items()
        ),
        "diagnostic_drift",
    )
    print(
        json.dumps(
            {
                "contract": "hosted-hs-task-five-boundary",
                "outcome": "observed-task-boundaries",
                "startup_prompt_state": "unobserved",
                "native_lease_authority": False,
                "events": packet["events"] + child["events"],
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        print(
            '{"contract":"hosted-hs-task-five-boundary","outcome":"blocked","reason":"prerequisite-or-receipt-refused"}'
        )
        raise SystemExit(1)
