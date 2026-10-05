# tools/diagnostics/native_global_switcher/run_native_probe.py
"""Persistent native scope; no TCC grant, PID-only handoff or prior-corpus rewrite."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import signal
import sys
import time
from types import SimpleNamespace
import uuid
from urllib.request import urlopen

from native_controller_owner import ProbeControllerOwner
from probe_receipts import qualify

DEPENDENCIES = {
    "ownership": "d3bc862c737e444f22d84fc32368bb8669360bc33ba6008c208f7bf62001314b",
    "inventory": "e5a90e628149d29ae93e5dba5675d45ad4e7a51cdea1c2221b11677e439c7c0f",
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pinned_module(path, kind):
    """Execute the captured verified bytes, without a verify-to-second-read gap."""
    path = Path(path).resolve(strict=True)
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != DEPENDENCIES[kind]:
        raise RuntimeError("Native dependency source pin differs")
    spec = importlib.util.spec_from_file_location("global_switcher_" + kind, path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), "exec"), module.__dict__)
    return module


def file_pin(path):
    path = Path(path).resolve(strict=True)
    before = path.stat()
    raw = path.read_bytes()
    after = path.stat()
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise RuntimeError("Source identity changed during capture")
    return {
        "path": str(path),
        "dev": after.st_dev,
        "ino": after.st_ino,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def pins_current(pins):
    try:
        return all(file_pin(item["path"]) == item for item in pins)
    except Exception:
        return False


def read_receipt(path):
    try:
        raw = path.read_bytes()
        if len(raw) > 32768:
            return None

        def unique(pairs):
            value = {}
            for key, item in pairs:
                if key in value:
                    raise ValueError("Duplicate native receipt key")
                value[key] = item
            return value

        return json.loads(raw, object_pairs_hook=unique)
    except (OSError, ValueError):
        return None


def main(arguments=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--hammerspoon-app")
    parser.add_argument("--hammerspoon-archive")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--owner-library", required=True)
    parser.add_argument("--inventory-library", required=True)
    parser.add_argument("--scratch", required=True)
    args = parser.parse_args(arguments)
    if (
        args.download
        and (args.hammerspoon_app or args.hammerspoon_archive)
        or not args.download
        and (not args.hammerspoon_app or not args.hammerspoon_archive)
    ):
        parser.error("Choose official bootstrap or an archive/app pair")
    if sys.platform != "darwin":
        print(
            json.dumps(
                {
                    "status": "unexecuted",
                    "reason": "macos_required",
                    "native_switcher_qualified": False,
                }
            )
        )
        return 77
    here = Path(__file__).resolve().parent
    scratch = Path(args.scratch).resolve(strict=True)
    if (scratch.stat().st_mode & 0o777) != 0o700:
        raise RuntimeError("The dedicated native fixture directory must be private")
    if any(scratch.iterdir()):
        raise RuntimeError("The dedicated native fixture directory must be empty")
    ownership = pinned_module(args.owner_library, "ownership")
    inventory = pinned_module(args.inventory_library, "inventory")
    # CPython3.13+ is required on Darwin; failure is before any native child allocation.
    try:
        native = ownership.NativeProcessGroups()
    except Exception:
        print(
            json.dumps(
                {
                    "status": "externally_blocked_native_ownership",
                    "native_switcher_qualified": False,
                }
            )
        )
        return 77
    owner = ProbeControllerOwner(native, ownership, scratch)
    borrowed = SimpleNamespace(acquire_owned=owner.acquire_external)
    report = {
        "coverage": "isolated_fixture_only",
        "native_switcher_qualified": False,
        "scratch_preserved": True,
        "native_child_capabilities": [],
    }
    logs = []
    app_pids, initial_pins, source_pins = {}, [], []
    primary_error = None
    receipt_path = scratch / "native-result.json"
    old_handlers = {}
    for signum in (signal.SIGTERM, signal.SIGINT):
        old_handlers[signum] = signal.signal(
            signum, lambda _sig, _frame: owner.request_cancel("controller_signal")
        )

    def command(arguments):
        index = len(logs)
        out = (scratch / ("tool-" + str(index) + ".log")).open("xb")
        logs.append(out)
        group = owner.acquire("build_tool", arguments, stdout=out, stderr=out)
        group.wait_for_exit(90)
        if group.settle() is not True or group.process.returncode != 0:
            raise RuntimeError("Native tool did not physically retire successfully")

    try:
        for name in (
            "GlobalSwitcherFixture.swift",
            "GlobalSwitcherHardware.swift",
            "global-switcher.lua",
            "run_native_probe.py",
            "run_ci_probe.py",
            "native_controller_owner.py",
            "probe_receipts.py",
        ):
            initial_pins.append(file_pin(here / name))
        initial_pins.extend([file_pin(args.owner_library), file_pin(args.inventory_library)])
        report["source_pins_before"] = initial_pins
        asset = inventory.trusted_asset(scratch)
        if args.download:
            archive = scratch / inventory.ASSET
            with (
                urlopen(asset["browser_download_url"], timeout=30) as incoming,
                archive.open("xb") as destination,
            ):
                payload = incoming.read(asset["size"] + 1)
                if len(payload) != asset["size"]:
                    raise RuntimeError("Official archive size differs")
                destination.write(payload)
            inventory.verify_archive(archive, asset)
            extracted = scratch / "official"
            extracted.mkdir()
            command(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)])
            app = extracted / "Hammerspoon.app"
        else:
            archive = Path(args.hammerspoon_archive).resolve(strict=True)
            app = Path(args.hammerspoon_app).resolve(strict=True)
        inventory.verify_archive(archive, asset)
        report["official_runtime_asset"] = {
            "version": "1.1.1",
            "sha256": asset["digest"][7:],
            "bytes": asset["size"],
        }
        inventory.verify_bundle(app, archive, native, borrowed)
        copied = scratch / "Hammerspoon.app"
        command(["/usr/bin/ditto", str(app), str(copied)])
        hs_binary, _ = inventory.verify_bundle(copied, archive, native, borrowed)
        hardware, fixture = (
            scratch / "global-switcher-hardware",
            scratch / "global-switcher-fixture",
        )
        command(
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-swift-version",
                "5",
                str(here / "GlobalSwitcherHardware.swift"),
                "-o",
                str(hardware),
            ]
        )
        command(
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-swift-version",
                "5",
                str(here / "GlobalSwitcherFixture.swift"),
                "-o",
                str(fixture),
            ]
        )
        command(["/usr/bin/codesign", "--force", "--sign", "-", str(hardware)])
        nonce = uuid.uuid4().hex
        config = {"hardware": str(hardware), "result": str(receipt_path)}
        source_pins = list(initial_pins)
        source_pins.extend([file_pin(hardware), file_pin(fixture), file_pin(hs_binary)])
        for label in ("b", "a"):
            bundle = "org.ergopti.native-switcher-fixture." + label + "." + nonce
            target = scratch / ("Fixture-" + label + ".app")
            content = target / "Contents"
            binary = content / "MacOS" / "Fixture"
            binary.parent.mkdir(parents=True)
            command(["/bin/cp", str(fixture), str(binary)])
            (content / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": bundle,
                        "CFBundleExecutable": "Fixture",
                        "CFBundleName": "Switcher Fixture " + label,
                        "CFBundlePackageType": "APPL",
                        "NSPrincipalClass": "NSApplication",
                    }
                )
            )
            command(["/usr/bin/codesign", "--force", "--sign", "-", str(target)])
            source_pins.extend([file_pin(binary), file_pin(content / "Info.plist")])
            log = (scratch / (label + "-launch.log")).open("xb")
            logs.append(log)
            group = owner.acquire("fixture_" + label, [str(binary)], stdout=log, stderr=log)
            app_pids[label] = group.process.pid
            config["fixture_" + label], config["bundle_" + label] = (
                group.process.pid,
                bundle,
            )
        deadline = time.monotonic() + 8
        while not all(
            (scratch / (label + "-launch.log"))
            .read_bytes()
            .startswith(("READY " + str(pid) + "\n").encode())
            for label, pid in app_pids.items()
        ):
            if (
                owner.cancel_requested
                or any(
                    group.observe_exit() is not None
                    for role, group in owner.capabilities
                    if role.startswith("fixture_")
                )
                or time.monotonic() >= deadline
            ):
                raise RuntimeError("Independent fixture applications were not observed ready")
            time.sleep(0.05)
        init = scratch / "global-switcher.lua"
        init.write_bytes((here / "global-switcher.lua").read_bytes())
        source_pins.append(file_pin(init))
        # The Lua main loop rechecks only the small owned payload/configuration
        # artifacts. The persistent controller owns the full source/runtime pins.
        live_paths = {str(hardware), str(init)}
        for label in ("a", "b"):
            content = scratch / ("Fixture-" + label + ".app") / "Contents"
            live_paths.update([str(content / "MacOS" / "Fixture"), str(content / "Info.plist")])
        config["pins"] = [pin for pin in source_pins if pin["path"] in live_paths]
        (scratch / "probe-config.json").write_text(json.dumps(config), encoding="utf-8")
        report["source_pins_before_payload"] = source_pins
        if not pins_current(source_pins):
            raise RuntimeError("Native source changed before runtime acquisition")
        log = (scratch / "hammerspoon-launch.log").open("xb")
        logs.append(log)
        owner.acquire(
            "hammerspoon",
            [
                str(hs_binary),
                "-MJConfigFile",
                str(init),
                "-SUEnableAutomaticChecks",
                "NO",
                "-SUHasLaunchedBefore",
                "YES",
            ],
            stdout=log,
            stderr=log,
        )
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            receipt = read_receipt(receipt_path)
            if receipt and receipt.get("status") != "pending":
                break
            if (
                owner.cancel_requested
                or owner.hs.observe_exit() is not None
                or not pins_current(source_pins)
            ):
                raise RuntimeError("Native runtime or source was revoked before physical receipt")
            time.sleep(0.05)
        else:
            raise RuntimeError("Native observation deadline retains cleanup authority")
        # Recheck every official runtime member after payload observations as well;
        # an unchanged main executable alone is not the native C-extension proof.
        inventory.verify_archive(archive, asset)
        inventory.verify_bundle(copied, archive, native, borrowed)
        inventory.verify_bundle(app, archive, native, borrowed)
    except BaseException as error:
        primary_error = type(error).__name__
        owner.request_cancel("native_probe_failed")
        report["error_category"] = primary_error
    finally:
        # This controller stays alive and keeps every exact registered capsule and
        # WNOWAIT parent reservation until physical cleanup is acknowledged. It
        # never returns with a numeric-PID-only handoff or reaps an unsettled leader.
        def publish_pending(receipt):
            report.update(
                status="retained_native_cleanup_debt",
                native_child_capabilities=owner.receipts(),
                native_receipt=receipt,
                controller_alive=True,
            )
            (scratch / "report.json").write_text(
                json.dumps(report, indent=2) + "\n", encoding="utf-8"
            )

        owner.retire_until_settled(
            lambda: read_receipt(receipt_path),
            lambda: not source_pins or pins_current(source_pins),
            publish_pending,
            time.sleep,
        )
        current = pins_current(source_pins) and pins_current(initial_pins)
        report["source_pins_after_match"] = current
        report["native_receipt"] = read_receipt(receipt_path)
        report["native_child_capabilities"] = owner.receipts()
        report["controller_alive"] = True
        for log in logs:
            log.close()
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        value = report["native_receipt"]
        report["native_switcher_qualified"] = bool(
            not primary_error
            and not owner.qualification_refused
            and not owner.cancel_requested
            and current
            and owner.hs
            and qualify(value, app_pids["a"], app_pids["b"], owner.hs.process.pid)
        )
        if report["native_switcher_qualified"]:
            report["status"] = "isolated_native_switcher_observed"
        elif value and value.get("status") == "blocked_accessibility":
            report["status"] = "externally_blocked_accessibility"
        else:
            report["status"] = "native_observation_not_qualified"
        (scratch / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "status": report["status"],
                "native_switcher_qualified": report["native_switcher_qualified"],
                "physical_keyboard_qualified": False,
                "product_owner_qualified": False,
            }
        )
    )
    return 0 if report["native_switcher_qualified"] else (1 if primary_error else 77)


if __name__ == "__main__":
    raise SystemExit(main())
