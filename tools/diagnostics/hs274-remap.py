# tools/diagnostics/hs274-remap.py
"""Observe actual remapping of the owned virtual input fixture on macOS CI."""

from contextlib import contextmanager, ExitStack
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time


@contextmanager
def owned_process(command, name, output, report):
    """Reap the exact process group while its owned leader remains alive."""
    with (output / ("hs274-remap-" + name + ".log")).open("x", encoding="utf-8") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        state = report.setdefault("processes", {}).setdefault(name, {"pid": process.pid})
        try:
            yield process
        finally:
            if process.poll() is None:
                subprocess.run(["sudo", "-n", "/bin/kill", "-TERM", "--", "-" + str(process.pid)],
                               check=True, timeout=3)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    subprocess.run(["sudo", "-n", "/bin/kill", "-KILL", "--", "-" + str(process.pid)],
                                   check=True, timeout=3)
                    process.wait(timeout=3)
            state["reaped"] = process.poll() is not None
            state["exit"] = process.returncode


def fixture_profile(device, ledger):
    """Mirror the Escape tap and none/none Space paths without foreign rules."""
    def physical_line(value):
        return {"shell_command": "printf '%s\\n' " + shlex.quote(value) + " >> " + shlex.quote(str(ledger))}

    def source(key):
        return {"key_code": key, "modifiers": {"optional": ["any"]}}

    condition = {"type": "device_if", "identifiers": [{
        "vendor_id": device["vendor_id"], "product_id": device["product_id"], "is_keyboard": True,
    }]}
    return {"global": {"check_for_updates_on_startup": False}, "profiles": [{
        "name": "HS274 Native Fixture", "selected": True,
        "complex_modifications": {"rules": [{
            "description": "HS274 Native Fixture", "manipulators": [
                {"type": "basic", "from": source("escape"), "conditions": [condition],
                 "to": [physical_line("escape")], "to_if_alone": [{"key_code": "spacebar"}],
                 "to_if_held_down": [{"key_code": "escape"}],
                 "to_after_key_up": [physical_line("U:escape")],
                 "parameters": {"basic.to_if_alone_timeout_milliseconds": 1000,
                                "basic.to_if_held_down_threshold_milliseconds": 250}},
                {"type": "basic", "from": source("spacebar"), "conditions": [condition],
                 "to": [{"set_variable": {"name": "hs274_space_held", "value": 1}},
                        {"key_code": "spacebar"}],
                 "to_after_key_up": [{"set_variable": {"name": "hs274_space_held", "value": 0}}]},
            ],
        }]},
    }]}


@contextmanager
def owned_configuration(device, ledger, report):
    """Create an isolated profile only when no user configuration exists."""
    home = Path.home().resolve()
    path = home / ".config/karabiner/karabiner.json"
    if path.parent.resolve() != path.parent:
        raise RuntimeError("Refusing a redirected Karabiner configuration directory")
    if path.exists() or path.is_symlink():
        raise RuntimeError("Refusing to replace an existing Karabiner configuration")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as handle:
        json.dump(fixture_profile(device, ledger), handle, indent=2)
        handle.write("\n")
    try:
        yield
    finally:
        if path.is_symlink():
            raise RuntimeError("Fixture configuration was replaced with a symlink")
        current = json.loads(path.read_text(encoding="utf-8"))
        profiles = current.get("profiles", [])
        if len(profiles) != 1 or profiles[0].get("name") != "HS274 Native Fixture":
            raise RuntimeError("Cannot prove ownership of the fixture configuration during cleanup")
        path.unlink()
        report["configuration_removed"] = True


def wait_ready(path, process, seconds):
    """Wait for a producer receipt, retaining process failure separately."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Input fixture exited before readiness")
        if path.is_file():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        time.sleep(0.1)
    raise RuntimeError("Input fixture readiness timed out")


def main():
    """Retain every native outcome; an observed device alone is not success."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() == 0:
        raise RuntimeError("Remapping observation requires the disposable Actions console user")
    output = Path(os.environ["RUNNER_TEMP"])
    report = {"hs274_fixed": False, "physical_keyboard_validated": False}
    native_path = output / "hs274-remap-native.json"
    ready_path = Path(str(native_path) + ".ready.json")
    start_path = Path(str(native_path) + ".start")
    abort_path = Path(str(native_path) + ".abort")
    ledger = output / "hs274-remap-ledger.log"
    base = Path("/Library/Application Support/org.pqrs/Karabiner-Elements")
    core = base / "Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service"
    console = base / "Karabiner-Console-User-Server.app/Contents/MacOS/Karabiner-Console-User-Server"
    daemon = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"
    try:
        permissions = json.loads((output / "hs274-core-permissions.json").read_text(encoding="utf-8"))
        if permissions["checks"]["direct"].get("permissions_granted") is not True:
            raise RuntimeError("Direct core permissions were not granted")
        if any(path.exists() for path in (native_path, ready_path, start_path, abort_path, ledger)):
            raise RuntimeError("A remapping fixture artifact already exists")
        with ExitStack() as stack:
            stack.enter_context(owned_process(["sudo", "-n", daemon], "provider", output, report))
            producer = stack.enter_context(owned_process(
                ["sudo", "-n", "env", "GITHUB_ACTIONS=true", str(output / "hs274-hid-stream"), str(native_path), "--remap"],
                "input", output, report))
            device = wait_ready(ready_path, producer, 20)
            if device.get("renamed") is not True:
                raise RuntimeError("Input fixture metadata was not renamed")
            report["input_fixture"] = device
            stack.enter_context(owned_configuration(device, ledger, report))
            stack.enter_context(owned_process(["sudo", "-n", str(core)], "core-daemon", output, report))
            stack.enter_context(owned_process([str(console)], "console-user-server", output, report))
            stack.enter_context(owned_process([str(core)], "core-agent", output, report))
            try:
                deadline = time.monotonic() + 25
                recognized = False
                while time.monotonic() < deadline:
                    try:
                        result = subprocess.run([str(base / "bin/karabiner_cli"), "--list-connected-devices"],
                                                capture_output=True, text=True,
                                                timeout=min(3, max(0.01, deadline - time.monotonic())), check=False)
                    except subprocess.TimeoutExpired:
                        report["device_query"] = {"timed_out": True}
                        continue
                    report["device_query"] = {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
                    try:
                        devices = json.loads(result.stdout)
                    except json.JSONDecodeError:
                        devices = []
                    if isinstance(devices, list):
                        matches = [row for row in devices if isinstance(row, dict) and all(
                            row.get("device_identifiers", {}).get(key) == device[key]
                            for key in ("vendor_id", "product_id"))]
                        # Upstream omits is_virtual_device when false.
                        recognized = len(matches) == 1 and matches[0].get("device_identifiers", {}).get("is_virtual_device", False) is False
                    if recognized:
                        break
                    time.sleep(0.2)
                report["fixture_recognized_as_input"] = recognized
                if not recognized:
                    raise RuntimeError("Karabiner did not recognize the renamed input fixture")
                with start_path.open("x", encoding="utf-8") as handle:
                    handle.write("run\n")
                producer.wait(timeout=12)
                report["native"] = json.loads(native_path.read_text(encoding="utf-8"))
                if producer.returncode != 0 or report["native"].get("escape_as_space") is not True:
                    raise RuntimeError("Native Escape/Space remapping did not pass")
            finally:
                if not abort_path.exists():
                    abort_path.write_text("abort\n", encoding="utf-8")
                producer.wait(timeout=10)
            deadline = time.monotonic() + 3
            while True:
                report["ledger_lines"] = ledger.read_text(encoding="utf-8").splitlines() if ledger.is_file() else []
                if len(report["ledger_lines"]) >= 2 or time.monotonic() >= deadline:
                    break
                time.sleep(0.1)
            if sorted(report["ledger_lines"]) != ["U:escape", "escape"]:
                raise RuntimeError("The owned physical ledger did not contain the expected Escape pair")
    except Exception as error:
        report["observation_error"] = f"{type(error).__name__}: {error}"
    finally:
        for name, path in (
            ("system-core", Path("/var/log/karabiner/core_service.log")),
            ("user-core", Path.home() / ".local/share/karabiner/log/core_service.log"),
            ("user-console", Path.home() / ".local/share/karabiner/log/console_user_server.log"),
        ):
            try:
                if path.is_file():
                    shutil.copyfile(path, output / ("hs274-remap-" + name + ".log"))
            except OSError as error:
                report.setdefault("log_copy_errors", {})[name] = str(error)
        with (output / "hs274-remap.json").open("x", encoding="utf-8", newline="\n") as receipt:
            json.dump(report, receipt, indent=2)
            receipt.write("\n")
    return 0 if "observation_error" not in report and report.get("native", {}).get("escape_as_space") is True else 1


if __name__ == "__main__":
    sys.exit(main())
