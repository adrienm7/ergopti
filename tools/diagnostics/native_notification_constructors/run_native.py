#!/usr/bin/env python3
# tools/diagnostics/native_notification_constructors/run_native.py
"""Authenticate actual notification construction, never delivery or user clicks."""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
import zipfile

from receipt import validate

DEPENDENCIES = {
    "ownership": "d3bc862c737e444f22d84fc32368bb8669360bc33ba6008c208f7bf62001314b",
    "inventory": "ec22906ec34b4b7efdf304dab81ab62cee0ad03148e6006bcbdf4276c8976afe",
}
PINS = (
    "static/ergopti_plus/macos/adapters/application_notifier.lua",
    "static/ergopti_plus/_shared/lua/application_notifier.lua",
    "static/ergopti_plus/_shared/lua/window_titles.lua",
    "static/ergopti_plus/_shared/ui/apps.manifest.json",
    "tools/diagnostics/macos_owned_process.py",
    "tools/diagnostics/native_hs_program_providers/run_native.py",
    "tools/diagnostics/native_notification_constructors/fixture.lua",
    "tools/diagnostics/native_notification_constructors/run_native.py",
    "tools/diagnostics/native_notification_constructors/receipt.py",
)
NOTIFY_SOURCE = "e1559c20e0b695dfd185807575e4ecb9accce0dabdfd7a0bff87066bf10f34d1"


def require(condition, category):
    if condition is not True:
        raise ValueError(category)


def pinned_module(path, kind):
    """Execute the verified bytes without reopening the source after verification."""
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == DEPENDENCIES[kind], "dependency_source_refused")
    spec = importlib.util.spec_from_file_location("notification_" + kind, path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), "exec"), module.__dict__)
    return module


def retained_acquirer(ownership, native, owners):
    """Retain each existing native capability before its caller's adoption boundary."""

    def acquire(arguments, actual_native, adopter, **options):
        require(actual_native is native, "foreign_native_owner_refused")

        def register(capability):
            owners.append(capability)
            adopter(capability)

        return ownership.acquire_owned(arguments, native, register, **options)

    return SimpleNamespace(acquire_owned=acquire)


def retire_registered(inventory, owners, output):
    """Retry the existing native owner's retirement; a refusal never drops custody."""
    refused = False
    while not all(capability.reaped is True for capability in owners):
        try:
            inventory.settle_registered(owners)
        except BaseException:
            refused = True
        if not all(capability.reaped is True for capability in owners):
            try:
                (output / "pending-retirement.json").write_text(
                    json.dumps(
                        {
                            "native_pass": False,
                            "controller_retains_capabilities": True,
                            "capabilities": [capability.receipt() for capability in owners],
                        }
                    )
                    + "\n"
                )
            except BaseException:
                refused = True
            try:
                time.sleep(0.05)
            except BaseException:
                # Cancellation during retry pause cannot abandon acquired capabilities.
                refused = True
    return not refused


def notify_source_member(app, archive):
    """Locate the exact official public constructor source inside the verified bundle."""
    with zipfile.ZipFile(archive) as bundle:
        members = [
            item.filename
            for item in bundle.infolist()
            if item.filename.startswith("Hammerspoon.app/")
            and not item.is_dir()
            and hashlib.sha256(bundle.read(item)).hexdigest() == NOTIFY_SOURCE
        ]
    require(len(members) == 1, "native_notify_source_refused")
    return str((app / members[0][len("Hammerspoon.app/") :]).resolve(strict=True))


def main(arguments=None):
    # Remove before platform checks, Git/source checks, or any child allocation.
    metadata_token = os.environ.pop("ERGOPTI_NATIVE_HS_METADATA_TOKEN", None)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args(arguments)
    if sys.platform != "darwin" or sys.version_info < (3, 13):
        print(json.dumps({"native_pass": False, "reason": "native_macos_python_required"}))
        return 77
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_sha) is not None, "source_sha_refused")
    root = args.source_root.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    ownership = pinned_module(root / PINS[4], "ownership")
    inventory = pinned_module(root / PINS[5], "inventory")
    metadata_token = inventory.validate_metadata_token(metadata_token)
    native = ownership.NativeProcessGroups()
    owners = []
    borrowed = retained_acquirer(ownership, native, owners)
    old_handlers = {}
    failure = None
    group = None
    preference = None
    physical = None

    def interrupted(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("notification_probe_interrupted")

    for signum in (signal.SIGTERM, signal.SIGINT):
        old_handlers[signum] = signal.signal(signum, interrupted)
    try:
        hashes = inventory.source_hashes(root, args.source_sha, PINS)
        asset = inventory.trusted_asset(output, metadata_token=metadata_token)
        metadata_token = None
        app, archive = args.app, args.archive
        if args.download:
            require(app is None and archive is None, "bootstrap_arguments_refused")
            archive = output / inventory.ASSET
            with (
                inventory.bootstrap_response(
                    "archive_download", asset["browser_download_url"], timeout=30
                ) as incoming,
                archive.open("xb") as destination,
            ):
                payload = incoming.read(asset["size"] + 1)
                require(len(payload) == asset["size"], "archive_size_refused")
                destination.write(payload)
            inventory.verify_archive(archive, asset)
            extracted = output / "official"
            extracted.mkdir()
            inventory.owned_tool(
                ["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], native, borrowed
            )
            app = extracted / "Hammerspoon.app"
        else:
            require(app is not None and archive is not None, "bootstrap_arguments_refused")
        inventory.verify_archive(archive, asset)
        binary, domain = inventory.verify_bundle(app, archive, native, borrowed)
        graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        graphics.CGMainDisplayID.restype = ctypes.c_uint32
        graphics.CGDisplayPixelsWide.argtypes = [ctypes.c_uint32]
        graphics.CGDisplayPixelsWide.restype = ctypes.c_size_t
        require(
            graphics.CGDisplayPixelsWide(graphics.CGMainDisplayID()) > 0,
            "window_server_unavailable",
        )
        pref_command = ["/usr/bin/defaults", "read", domain, "MJConfigFile"]
        before, _, before_status = inventory.owned_tool(
            pref_command, native, borrowed, accepted=(0, 1)
        )
        preference = (pref_command, before, before_status)
        nonce = secrets.token_hex(16)
        value = {
            "source_root": str(root),
            "source_sha": args.source_sha,
            "nonce": nonce,
            "source_hashes": hashes,
            "receipt": str(output / "receipt.json"),
            "native_notify_source": notify_source_member(app, archive),
        }
        fixture = (root / PINS[6]).read_text()
        startup = output / "init.lua"
        startup.write_text(
            fixture.replace(
                "__INPUT_JSON__", inventory.lua_string(json.dumps(value, ensure_ascii=False))
            )
        )
        environment = dict(os.environ)
        for key in (
            "__CFBundleIdentifier",
            "__CFBundlePath",
            "LUA_INIT",
            "LUA_PATH",
            "LUA_CPATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
        ):
            environment.pop(key, None)
        verified_binary, verified_domain = inventory.verify_bundle(app, archive, native, borrowed)
        require((verified_binary, verified_domain) == (binary, domain), "native_route_changed")
        require(
            inventory.source_hashes(root, args.source_sha, PINS) == hashes, "source_prelaunch_drift"
        )
        group = borrowed.acquire_owned(
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
            lambda capability: None,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        inventory.await_packet(Path(value["receipt"]), group)
        packet = inventory.read_packet(Path(value["receipt"]))
        validate(packet, args.source_sha, nonce, group.process.pid, hashes)
        group.wait_for_exit(5)
        inventory.verify_archive(archive, asset)
        inventory.verify_bundle(app, archive, native, borrowed)
        require(
            inventory.source_hashes(root, args.source_sha, PINS) == hashes, "source_postrun_drift"
        )
    except BaseException as error:
        failure = type(error).__name__ if type(error) is not ValueError else str(error)
    finally:
        # No input or notification was dispatched: existing native process retirement
        # is the destruction boundary, including a partial constructor/receipt failure.
        settled_without_refusal = retire_registered(inventory, owners, output)
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        physical = {
            "source_sha": args.source_sha,
            "capabilities": [capability.receipt() for capability in owners],
            "closed": all(capability.reaped is True for capability in owners),
        }
        (output / "physical-group.json").write_text(json.dumps(physical) + "\n")
        if settled_without_refusal is not True:
            failure = "native_retirement_refused"
    if preference is not None:
        # The inert runtime has retired before this independent persistent-value check.
        check_owners = []
        check_borrowed = retained_acquirer(ownership, native, check_owners)
        try:
            after, _, after_status = inventory.owned_tool(
                preference[0], native, check_borrowed, accepted=(0, 1)
            )
            require(
                (after, after_status) == (preference[1], preference[2]),
                "persistent_configuration_changed",
            )
        except BaseException as error:
            failure = type(error).__name__ if type(error) is not ValueError else str(error)
        finally:
            if retire_registered(inventory, check_owners, output) is not True:
                failure = "native_retirement_refused"
            owners.extend(check_owners)
    try:
        if preference is not None:
            require(
                inventory.source_hashes(root, args.source_sha, PINS) == hashes, "source_final_drift"
            )
    except BaseException as error:
        failure = type(error).__name__ if type(error) is not ValueError else str(error)
    physical = {
        "source_sha": args.source_sha,
        "capabilities": [capability.receipt() for capability in owners],
        "closed": all(capability.reaped is True for capability in owners),
    }
    (output / "physical-group.json").write_text(json.dumps(physical) + "\n")
    if failure is not None:
        category = failure if re.fullmatch(r"[a-z_]+", failure) else "native_probe_failed"
        (output / "failure.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "source_sha": args.source_sha,
                    "native_pass": False,
                    "reason": category,
                    "native_processes_retired": physical["closed"],
                }
            )
            + "\n"
        )
    require(
        failure is None,
        failure if failure and re.fullmatch(r"[a-z_]+", failure) else "native_probe_failed",
    )
    require(
        group is not None and group.process.returncode == 0 and physical["closed"],
        "native_runtime_status_refused",
    )
    summary = {
        "schema": 1,
        "native_pass": True,
        "source_sha": args.source_sha,
        "contract": "macos-native-application-notification-constructors",
        "passed": 9,
        "failed": 0,
        "skipped": 0,
        "notification_delivery": False,
        "callback_invocation": False,
        "native_process_retired": True,
    }
    (output / "summary.json").write_text(json.dumps(summary) + "\n")
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(
            json.dumps(
                {
                    "native_pass": False,
                    "reason": str(error)
                    if type(error) is ValueError and re.fullmatch(r"[a-z_]+", str(error))
                    else type(error).__name__,
                }
            )
        )
        raise SystemExit(1)
