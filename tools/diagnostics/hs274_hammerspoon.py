# tools/diagnostics/hs274_hammerspoon.py
"""Own a real Hammerspoon consumer of the experimental native physical stream."""

from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from hs274_capture import unique_object
from hs274_stream import decimal


def read_clock(information):
    """Require the native rational scale; never infer it from the architecture."""
    if (not isinstance(information, dict) or set(information) != {"version", "domain", "numer", "denom"}
            or type(information["version"]) is not int or information["version"] != 1
            or information["domain"] != "mach_absolute_time"
            or any(type(information[key]) is not int or not 1 <= information[key] <= (1 << 32) - 1
                   for key in ("numer", "denom"))):
        raise ValueError("Invalid native physical clock timebase")
    return information


def validate_clock(result, downs):
    """Independently recompute Lua conversion using Python integer arithmetic."""
    scale = read_clock(result.get("clock"))
    samples = result.get("clock_samples")
    if not isinstance(samples, list) or len(samples) != len(downs):
        raise ValueError("Missing original physical clock samples")
    start = decimal(result.get("capture_started_ns"), maximum=(1 << 63) - 1)
    for sample, row in zip(samples, downs):
        if not isinstance(sample, dict) or set(sample) != {"original_ns", "observed_ns"}:
            raise ValueError("Invalid original physical clock sample")
        original = decimal(sample["original_ns"], maximum=(1 << 63) - 1)
        observed = decimal(sample["observed_ns"], maximum=(1 << 63) - 1)
        if original != row["timestamp"] * scale["numer"] // scale["denom"] or not start <= original <= observed:
            raise ValueError("Physical timestamp is not in the native capture clock domain")


def native_lifecycle():
    """Reuse the existing exact-executable supervisor rather than PID-only cleanup."""
    path = Path(__file__).resolve().parents[1] / "bench/macos-metrics/run.py"
    spec = importlib.util.spec_from_file_location("hs274_native_lifecycle", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CaptureReceipt:
    """Expose the actual CLI completion reported by its Hammerspoon task owner."""

    def __init__(self, result, native, executable):
        self.path, self.native, self.executable = result, native, executable
        self.returncode = None
        self.result = None
        self.observed = False

    def poll(self):
        live = self.native.matching(self.executable)
        self.observed = self.observed or bool(live)
        if self.path.exists():
            try:
                receipt = json.loads(self.path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                return None
            if (not isinstance(receipt, dict) or type(receipt.get("error_count")) is not int
                    or receipt["error_count"] != 0 or receipt.get("errors") not in ([], {})):
                raise RuntimeError("Native Hammerspoon consumer failed: " + str(receipt))
            if receipt.get("settled") is not True or type(receipt.get("exit")) is not int:
                raise RuntimeError("Native Hammerspoon receipt does not prove task settlement")
            if not self.observed:
                raise RuntimeError("No exact Hammerspoon process was observed")
            self.result, self.returncode = receipt, receipt["exit"]
            return self.returncode
        if not live:
            raise RuntimeError("Native Hammerspoon exited before its capture receipt")
        return None

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            code = self.poll()
            if code is not None:
                return code
            time.sleep(0.05)
        raise RuntimeError("Native Hammerspoon capture did not settle before its deadline")


@contextmanager
def owned_capture(app, cli, output, report):
    """Launch one isolated app and keep both application and CLI evidence."""
    clock = subprocess.run([str(cli), "--hs274-clock"], check=True, capture_output=True, text=True, timeout=5)
    timebase = read_clock(json.loads(clock.stdout, object_pairs_hook=unique_object))
    lifecycle = native_lifecycle()
    native = lifecycle.NativeProcesses()
    scratch = Path(tempfile.mkdtemp(prefix="hs274-hammerspoon-")).resolve()
    copied = scratch / "Hammerspoon.app"
    executable = copied / "Contents/MacOS/Hammerspoon"
    subprocess.run(["/usr/bin/ditto", str(app), str(copied)], check=True, timeout=60)
    here = Path(__file__).resolve().parent
    shutil.copyfile(here / "hs274-hammerspoon.lua", scratch / "init.lua")
    result = output / "hs274-remap-hammerspoon.json"
    stop = scratch / "stop"
    configuration = {"repo": str(here.parents[1]), "cli": str(cli), "result": str(result),
                     "stream": str(output / "hs274-remap-physical-stream.log"),
                     "diagnostics": str(output / "hs274-remap-physical-stream-stderr.log"),
                     "stop": str(stop), "batch_limit": 64, "frame_limit": 65536, "clock": timebase}
    (scratch / "capture-config.json").write_text(json.dumps(configuration), encoding="utf-8")
    with (output / "hs274-remap-hammerspoon-launch.log").open("xb") as log:
        launcher = subprocess.Popen(["/usr/bin/open", "-n", "-g", "-W", str(copied),
                                     "--args", "-MJConfigFile", str(scratch / "init.lua")],
                                    stdout=log, stderr=subprocess.STDOUT)
        client = CaptureReceipt(result, native, executable)
        state = report.setdefault("processes", {}).setdefault("physical-stream", {"runtime": "native Hammerspoon"})
        try:
            deadline = time.monotonic() + 15
            while not native.matching(executable) or not Path(configuration["stream"]).is_file():
                if launcher.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Native Hammerspoon did not launch")
                time.sleep(0.05)
            client.observed = True
            yield client
        finally:
            try:
                stop.write_text("stop\n", encoding="utf-8")
                client.wait(timeout=10)
                state.update(exit=client.returncode, reaped=True)
                report["hammerspoon"] = client.result
            finally:
                lifecycle.cleanup(native, executable, launcher)
                state["application_cleanup"] = "confirmed"


def validate_consumer(result, capture):
    """Match real Lua credits and exact original context keys against native input."""
    if (not isinstance(result, dict) or result.get("runtime") != "native Hammerspoon" or result.get("coverage") != "fixture_only"
            or result.get("settled") is not True or result.get("stop_requested") is not True
            or type(result.get("error_count")) is not int or result["error_count"] != 0
            or result.get("errors") not in ([], {})
            or type(result.get("exit")) is not int or result["exit"] != 143
            or result.get("counts") != {"49": 1, "53": 1}
            or any(type(value) is not int for value in result["counts"].values())):
        raise ValueError("Native Hammerspoon did not prove complete fixture delivery")
    downs = [row for row in capture["records"] if row["has_page"] and row["has_usage"]
             and row["page"] == 7 and row["usage"] in (41, 44) and row["value"] == 1]
    if [row["usage"] for row in downs] != [41, 44]:
        raise ValueError("Independent fixture does not contain the expected physical pair")
    validate_clock(result, downs)
    expected_contexts = [{"device": str(row["device"]), "timestamp": str(row["timestamp"])} for row in downs]
    if (result.get("contexts") != expected_contexts or not isinstance(result.get("presses"), list)
            or len(result["presses"]) != len(downs)):
        raise ValueError("Native Hammerspoon changed physical timestamps or device identities")
    for press, row in zip(result["presses"], downs):
        if (not isinstance(press, dict) or type(press.get("keycode")) is not int
                or press["keycode"] != {41: 53, 44: 49}[row["usage"]] or press.get("device") != str(row["device"])):
            raise ValueError("Native Hammerspoon lost or changed a physical press")
