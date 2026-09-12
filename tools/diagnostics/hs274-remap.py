# tools/diagnostics/hs274-remap.py
"""Observe actual remapping of the owned virtual input fixture on macOS CI."""

from contextlib import contextmanager, ExitStack
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time

from hs274_runtime import runtime_paths
from hs274_services import check_runtime_processes, disable_installed_peers, verify_disabled
from hs274_registration import suspended_registration, verify_registration_block
from hs274_capture import validate_capture
from hs274_stream import read_stream, validate_stream, fixture_drain, validate_interruption
from hs274_disconnect import disconnected_capture
from hs274_baseline import read_baseline, wait_baseline, validate_baseline_native, validate_baseline_capture


@contextmanager
def owned_process(command, name, output, report, separate_stderr=False):
    """Reap the exact process group while its owned leader remains alive."""
    with ExitStack() as handles:
        log = handles.enter_context((output / ("hs274-remap-" + name + ".log")).open("x", encoding="utf-8"))
        stderr = handles.enter_context((output / ("hs274-remap-" + name + "-stderr.log")).open("x", encoding="utf-8")) if separate_stderr else subprocess.STDOUT
        process = subprocess.Popen(command, stdout=log, stderr=stderr, start_new_session=True)
        state = report.setdefault("processes", {}).setdefault(name, {"pid": process.pid})
        try:
            yield process
        finally:
            if process.poll() is None:
                # sudo forwards TERM: signaling its whole group can terminate
                # the child twice and interrupt its graceful capture flush.
                target = str(process.pid) if command[0] == "sudo" else "-" + str(process.pid)
                subprocess.run(["sudo", "-n", "/bin/kill", "-TERM", "--", target],
                               check=True, timeout=3)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    subprocess.run(["sudo", "-n", "/bin/kill", "-KILL", "--", "-" + str(process.pid)],
                                   check=True, timeout=3)
                    process.wait(timeout=3)
            state["reaped"] = process.poll() is not None
            state["exit"] = process.returncode


def fixture_profile(device, ledger, ignored=False):
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
        "devices": [{"identifiers": condition["identifiers"][0], "ignore": ignored}],
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
def owned_configuration(device, ledger, report, ignored=False):
    """Create an isolated profile only when no user configuration exists."""
    home = Path.home().resolve()
    path = home / ".config/karabiner/karabiner.json"
    if path.parent.resolve() != path.parent:
        raise RuntimeError("Refusing a redirected Karabiner configuration directory")
    if path.exists() or path.is_symlink():
        raise RuntimeError("Refusing to replace an existing Karabiner configuration")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as handle:
        json.dump(fixture_profile(device, ledger, ignored), handle, indent=2)
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


def wait_stream(path, process, predicate, seconds):
    """Require complete validated frames while the owned stream client is alive."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Physical stream client exited during observation")
        stream = read_stream(path.read_text(encoding="utf-8"), partial=True)
        if stream is not None and predicate(stream):
            return stream
        time.sleep(0.1)
    raise RuntimeError("Physical stream observation timed out")


def finish_fixture_stream(stream_path, client, producer, scope, drained_path, device, before_release):
    """Release the native fixture only after full delivery and owned client exit."""
    wait_stream(stream_path, client, fixture_drain(device), 10)
    if producer.poll() is not None:
        raise RuntimeError("Input fixture exited before stream drain")
    scope.close()
    if client.returncode != 128 + signal.SIGTERM:
        raise RuntimeError("Physical stream client did not stop before fixture release")
    successor = before_release()
    with drained_path.open("x", encoding="utf-8") as handle:
        handle.write("drained\n")
    return successor


def validate_native_output(native, ignored):
    """Require both real output pairs independently of the producer success flag."""
    expected_escape = 53 if ignored else 49
    expected = [(10, expected_escape), (11, expected_escape), (10, 49), (11, 49)]
    actual = [(row["type"], row["keycode"]) for row in native["events"]]
    if actual != expected or native.get("space_pair_observed") is not True:
        raise ValueError("Native Escape/Space output differs from the selected fixture mode")
    if native.get("ignored_mode") is not ignored:
        raise ValueError("Native fixture did not acknowledge the ignored-device mode")
    if native.get("escape_as_space") is not (not ignored) or native.get("escape_passthrough") is not ignored:
        raise ValueError("Native Escape provenance contradicts the selected fixture mode")


def main():
    """Retain every native outcome; an observed device alone is not success."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() == 0:
        raise RuntimeError("Remapping observation requires the disposable Actions console user")
    output = Path(os.environ["RUNNER_TEMP"])
    report = {"hs274_fixed": False, "physical_keyboard_validated": False}
    mode = os.environ.get("HS274_IGNORED_FIXTURE", "false")
    if mode not in ("true", "false"):
        raise RuntimeError("Invalid ignored fixture mode")
    ignored = mode == "true"
    baseline_mode = os.environ.get("HS274_BASELINE_FIXTURE", "false")
    if baseline_mode not in ("true", "false"):
        raise RuntimeError("Invalid baseline fixture mode")
    baseline = baseline_mode == "true"
    if baseline and ignored:
        raise RuntimeError("Held baseline acquisition requires the managed fixture")
    report["ignored_fixture"] = ignored
    report["baseline_fixture"] = baseline
    native_path = output / "hs274-remap-native.json"
    ready_path = Path(str(native_path) + ".ready.json")
    start_path = Path(str(native_path) + ".start")
    abort_path = Path(str(native_path) + ".abort")
    drained_path = Path(str(native_path) + ".drained")
    ledger = output / "hs274-remap-ledger.log"
    stream_path = output / "hs274-remap-physical-stream.log"
    interruption_path = output / "hs274-remap-interrupted-stream.log"
    daemon = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"
    try:
        runtime = runtime_paths()
        core, console = runtime["core"], runtime["console"]
        report["runtime"] = {name: str(path) for name, path in runtime.items()}
        development = bool(os.environ.get("HS274_DEVELOPMENT_ROOT"))
        if ignored and not development:
            raise RuntimeError("Ignored fixture capture requires the development stream")
        if baseline and not development:
            raise RuntimeError("Held baseline acquisition requires the development core")
        permissions = json.loads((output / "hs274-core-permissions.json").read_text(encoding="utf-8"))
        if permissions["checks"]["direct"].get("permissions_granted") is not True:
            raise RuntimeError("Direct core permissions were not granted")
        if any(path.exists() for path in (native_path, ready_path, start_path, abort_path, drained_path, ledger)):
            raise RuntimeError("A remapping fixture artifact already exists")
        with ExitStack() as stack:
            if development:
                stack.enter_context(suspended_registration(report))
                disable_installed_peers(report)
                check_runtime_processes(runtime, report, "before", False)
            stack.enter_context(owned_process(["sudo", "-n", daemon], "provider", output, report))
            producer = stack.enter_context(owned_process(
                ["sudo", "-n", "env", "GITHUB_ACTIONS=true", str(output / "hs274-hid-stream"), str(native_path),
                 "--baseline-held" if baseline else "--ignored-hold" if ignored else "--remap-hold" if development else "--remap"],
                "input", output, report))
            device = wait_ready(ready_path, producer, 20)
            if device.get("renamed") is not True:
                raise RuntimeError("Input fixture metadata was not renamed")
            if development and not baseline and device.get("hold_for_drain") is not True:
                raise RuntimeError("Input fixture did not retain its lifetime for stream drain")
            if baseline and device.get("baseline_held") is not True:
                raise RuntimeError("Input fixture did not hold Space before core startup")
            report["input_fixture"] = device
            stack.enter_context(owned_configuration(device, ledger, report, ignored))
            core_process = stack.enter_context(owned_process(["sudo", "-n", str(core)], "core-daemon", output, report))
            stack.enter_context(owned_process([str(console)], "console-user-server", output, report))
            stack.enter_context(owned_process([str(core)], "core-agent", output, report))
            try:
                deadline = time.monotonic() + 25
                recognized = False
                while time.monotonic() < deadline:
                    try:
                        result = subprocess.run([str(runtime["cli"]), "--list-connected-devices"],
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
                if development:
                    verify_registration_block(report)
                    verify_disabled(report)
                    check_runtime_processes(runtime, report, "ready", True)
                    if baseline:
                        report["baseline_probe"] = wait_baseline(output / "hs274-remap-core-daemon.log",
                                                                   core_process, device["registry_entry_id"], 20)
                        if report["baseline_probe"]["held"] != {41: 0, 44: 1}:
                            raise RuntimeError("Core could not acquire the deliberately held Space")
                    else:
                        disconnected_capture([str(runtime["cli"]), "--hs274-capture", "25"], output, report)
                        stream_scope = stack.enter_context(ExitStack())
                        stream_client = stream_scope.enter_context(owned_process(
                            [str(runtime["cli"]), "--hs274-capture", "25"], "physical-stream", output, report,
                            separate_stderr=True))
                        report["stream_opened"] = wait_stream(stream_path, stream_client, lambda stream: True, 10)["opened"]
                        if report["stream_opened"]["lease"] != "2":
                            raise RuntimeError("Successor capture did not acquire the next lease in the isolated daemon")
                with start_path.open("x", encoding="utf-8") as handle:
                    handle.write("run\n")
                if development and not baseline:
                    def open_interruption():
                        observer = stack.enter_context(owned_process(
                            [str(runtime["cli"]), "--hs274-capture", "25"], "interrupted-stream", output, report,
                            separate_stderr=True))
                        opened = wait_stream(interruption_path, observer, lambda stream: True, 10)["opened"]
                        if opened != dict(report["stream_opened"], lease="3"):
                            raise RuntimeError("Interruption observer did not acquire the next lease in the same producer")
                        report["interruption_opened"] = opened
                        return observer

                    interruption_client = finish_fixture_stream(stream_path, stream_client, producer, stream_scope,
                                                                 drained_path, device["registry_entry_id"], open_interruption)
                producer.wait(timeout=12)
                report["native"] = json.loads(native_path.read_text(encoding="utf-8"))
                if producer.returncode != 0:
                    raise RuntimeError("Native Escape/Space fixture did not pass")
                if baseline:
                    validate_baseline_native(report["native"], report["baseline_probe"])
                else:
                    validate_native_output(report["native"], ignored)
                if development and not baseline and report["native"].get("drain_released") is not True:
                    raise RuntimeError("Native fixture did not confirm stream drain release")
                if development and not baseline:
                    if interruption_client.wait(timeout=10) != 1:
                        raise RuntimeError("Interrupted capture did not exit with a reported failure")
                    report["physical_interruption"] = validate_interruption(
                        interruption_path.read_text(encoding="utf-8"), report["interruption_opened"])
                    diagnostic = (output / "hs274-remap-interrupted-stream-stderr.log").read_text(encoding="utf-8")
                    if "Physical capture failed: Physical capture coverage lost" not in diagnostic:
                        raise RuntimeError("Interrupted capture diagnostic is missing")
            finally:
                if not abort_path.exists():
                    abort_path.write_text("abort\n", encoding="utf-8")
                producer.wait(timeout=10)
                if baseline and native_path.is_file() and "native" not in report:
                    report["native"] = json.loads(native_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while True:
                report["ledger_lines"] = ledger.read_text(encoding="utf-8").splitlines() if ledger.is_file() else []
                if len(report["ledger_lines"]) >= 2 or time.monotonic() >= deadline:
                    break
                time.sleep(0.1)
            if sorted(report["ledger_lines"]) != ([] if ignored or baseline else ["U:escape", "escape"]):
                raise RuntimeError("The owned physical ledger did not contain the expected Escape pair")
            if development:
                verify_registration_block(report)
                verify_disabled(report)
                check_runtime_processes(runtime, report, "after-input", True)
        if development:
            check_runtime_processes(runtime, report, "after-cleanup", False)
            core_output = (output / "hs274-remap-core-daemon.log").read_text(encoding="utf-8")
            if baseline:
                report["baseline_probe"] = read_baseline(core_output, report["input_fixture"]["registry_entry_id"])
                released = validate_baseline_native(report["native"], report["baseline_probe"])
                report["physical_capture"] = validate_baseline_capture(core_output,
                    report["input_fixture"]["registry_entry_id"], released)
            else:
                report["physical_capture"] = validate_capture(core_output, report["input_fixture"]["registry_entry_id"])
                report["physical_stream"] = validate_stream(stream_path.read_text(encoding="utf-8"), report["physical_capture"])
                report["baseline_probe"] = read_baseline(core_output, report["input_fixture"]["registry_entry_id"])
            if not baseline and report["processes"]["physical-stream"]["exit"] != 128 + signal.SIGTERM:
                raise RuntimeError("Physical stream client did not stop gracefully")
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
    return 0 if "observation_error" not in report and report.get("native", {}).get("space_pair_observed") is True else 1


if __name__ == "__main__":
    sys.exit(main())
