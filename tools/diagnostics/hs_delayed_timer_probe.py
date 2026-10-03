# tools/diagnostics/hs_delayed_timer_probe.py
"""Observe real packaged timers through the launch gate's existing native process."""

import json
import math
from pathlib import Path
import plistlib
import secrets
import subprocess
import time

CONTRACT = json.loads(Path(__file__).with_name("hs_delayed_timer_contract.json").read_text())
APPLE_SCRIPT_KEY = "HSAppleScriptEnabledKey"
SCRIPTING_TIMEOUT_SECONDS = 10
SCRIPT_SAMPLE_SECONDS = 1
SCRIPT_CLEANUP_TIMEOUT_SECONDS = 2
SCRIPT_SAMPLE_READ_LIMIT = 65536
SCRIPT_SAMPLE_FRAME_LIMIT = 6
CHECK_COUNT = (
    len(CONTRACT["boolean_observations"])
    + len(CONTRACT["remaining_limits"])
    + len(CONTRACT["deliveries"])
)


def unique_object(pairs):
    """Reject duplicate receipt fields instead of accepting the final value."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate native receipt field: {key}")
        result[key] = value
    return result


def validate_receipt(result, nonce, pid, executable, bundle_id):
    """Judge measured native observations without trusting callback assertions."""
    fields = {
        "schema_version",
        "contract",
        "nonce",
        "pid",
        "executable",
        "bundle_id",
        "version",
        "complete",
        "observations",
        "deliveries",
        "errors",
    }
    if not isinstance(result, dict) or set(result) != fields:
        raise ValueError("The native delayed-timer receipt is incomplete or has unknown fields")
    identity = {
        "schema_version": 1,
        "contract": CONTRACT["contract"],
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "bundle_id": bundle_id,
        "version": CONTRACT["runtime_version"],
        "complete": True,
    }
    for key, expected in identity.items():
        if type(result[key]) is not type(expected) or result[key] != expected:
            raise ValueError(f"Native delayed-timer identity or completion differs: {key}")
    if result["errors"] != []:
        raise ValueError(f"Native delayed-timer callbacks failed: {result['errors']!r}")
    observed = result["observations"]
    names = set(CONTRACT["boolean_observations"]) | set(CONTRACT["remaining_limits"])
    if not isinstance(observed, dict) or set(observed) != names:
        raise ValueError("The native delayed-timer observation inventory is incomplete")
    for name, expected in CONTRACT["boolean_observations"].items():
        if observed[name] is not expected:
            raise ValueError(f"Native delayed-timer observation differs: {name}")
    for name, maximum in CONTRACT["remaining_limits"].items():
        value = observed[name]
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= maximum:
            raise ValueError(f"Native delayed-timer countdown differs: {name}")
    for greater, smaller in CONTRACT["greater_than"]:
        if observed[greater] <= observed[smaller]:
            raise ValueError(f"The configured countdown did not replace its override: {greater}")
    delivered = result["deliveries"]
    if not isinstance(delivered, dict) or set(delivered) != set(CONTRACT["deliveries"]):
        raise ValueError("The native delayed-timer delivery inventory is incomplete")
    for name, expected in CONTRACT["deliveries"].items():
        if type(delivered[name]) is not int or delivered[name] != expected:
            raise ValueError(f"Native delayed-timer delivery count differs: {name}")
    return {
        "schema_version": 1,
        "contract": CONTRACT["contract"],
        "runtime": "native Hammerspoon",
        "version": CONTRACT["runtime_version"],
        "complete": True,
        "checks": CHECK_COUNT,
        "nonce": nonce,
        "pid": pid,
        "executable": str(executable),
        "preference_restored": False,
    }


def validate_summary(summary):
    """Require a complete native receipt and the preference owner's restoration."""
    if not isinstance(summary, dict) or set(summary) != {
        "schema_version",
        "contract",
        "runtime",
        "version",
        "complete",
        "checks",
        "nonce",
        "pid",
        "executable",
        "preference_restored",
    }:
        raise ValueError("Missing or malformed native delayed-timer summary")
    for key, expected in {
        "schema_version": 1,
        "contract": CONTRACT["contract"],
        "runtime": "native Hammerspoon",
        "version": CONTRACT["runtime_version"],
        "complete": True,
        "checks": CHECK_COUNT,
        "preference_restored": True,
    }.items():
        if type(summary[key]) is not type(expected) or summary[key] != expected:
            raise ValueError(f"Incomplete native delayed-timer summary: {key}")
    if not isinstance(summary["nonce"], str) or len(summary["nonce"]) != 32:
        raise ValueError("Invalid native delayed-timer nonce")
    if any(char not in "0123456789abcdef" for char in summary["nonce"]):
        raise ValueError("Invalid native delayed-timer nonce")
    if type(summary["pid"]) is not int or summary["pid"] <= 0:
        raise ValueError("Invalid native delayed-timer process identity")
    if summary["executable"] != str(
        NativeDelayedTimerProbe.executable_path(Path("/Applications/ErgoptiPlus.app"))
    ):
        raise ValueError("The delayed-timer probe observed a different installed executable")


class AppleScriptPreference:
    """Snapshot and restore the physical scripting key in the owned native domain."""

    def __init__(self, domain, runner=subprocess.run):
        self.domain = domain
        self.runner = runner
        self.snapshot = None
        self.mutation_attempted = False

    def read_domain(self):
        """Read native persisted preferences; recognize only a named absent domain."""
        result = self.runner(
            ["/usr/bin/defaults", "export", self.domain, "-"], capture_output=True, timeout=10
        )
        if result.returncode:
            absent = f"Domain {self.domain} does not exist"
            if absent in [line.strip() for line in result.stderr.decode("utf-8").splitlines()]:
                return {}
            raise RuntimeError("The native scripting preference domain could not be read")
        domain = plistlib.loads(result.stdout)
        if not isinstance(domain, dict):
            raise ValueError("The native scripting preference export is not a dictionary")
        return domain

    def enable(self):
        """Enable scripting only after retaining the original physical value."""
        self.snapshot = self.read_domain()
        self.mutation_attempted = True
        result = self.runner(
            ["/usr/bin/defaults", "write", self.domain, APPLE_SCRIPT_KEY, "-bool", "true"],
            capture_output=True,
            timeout=10,
        )
        if result.returncode or self.read_domain().get(APPLE_SCRIPT_KEY) is not True:
            raise RuntimeError("The native scripting preference did not acknowledge enable")

    def restore(self):
        """Restore only the owned key after the gate has stopped its native writer."""
        if not self.mutation_attempted:
            return
        current = self.read_domain()
        if APPLE_SCRIPT_KEY in self.snapshot:
            current[APPLE_SCRIPT_KEY] = self.snapshot[APPLE_SCRIPT_KEY]
        else:
            current.pop(APPLE_SCRIPT_KEY, None)
        result = self.runner(
            ["/usr/bin/defaults", "import", self.domain, "-"],
            input=plistlib.dumps(current),
            capture_output=True,
            timeout=10,
        )
        restored = self.read_domain()
        deleted = None
        if APPLE_SCRIPT_KEY not in self.snapshot and APPLE_SCRIPT_KEY in restored:
            # An imported dictionary can merge into the domain. Omission does
            # not acknowledge removal of the key this probe temporarily owned.
            deleted = self.runner(
                ["/usr/bin/defaults", "delete", self.domain, APPLE_SCRIPT_KEY],
                capture_output=True,
                timeout=10,
            )
            restored = self.read_domain()
        if (
            result.returncode
            or (deleted is not None and deleted.returncode)
            or plistlib.dumps(restored) != plistlib.dumps(current)
        ):
            raise RuntimeError("The native scripting preference did not acknowledge restoration")


class NativeDelayedTimerProbe:
    """Use the launch gate's signed embedded runtime without starting another process."""

    def __init__(self, app, output, domain):
        self.app = app / "Contents/Frameworks/Hammerspoon.app"
        self.output = output
        self.executable = self.executable_path(app)
        self.domain = domain
        self.preference = AppleScriptPreference(domain)
        self.nonce = secrets.token_hex(16)
        self.started = False
        self.scripting_commands = []
        self.scripting_command_number = 0
        self.runtime_owner = None

    @staticmethod
    def executable_path(app):
        """Return the exact installed native executable the launcher owns."""
        return app / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"

    def enable(self):
        """Verify installed identity before enabling the owned scripting channel."""
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", str(self.app)],
            check=True,
            capture_output=True,
            timeout=30,
        )
        with (self.app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        if (
            info["CFBundleIdentifier"] != self.domain
            or info["CFBundleShortVersionString"] != CONTRACT["runtime_version"]
        ):
            raise ValueError(
                "The packaged native timer runtime differs from its qualified identity"
            )
        self.preference.enable()

    def execute(self, source):
        """Target the already running installed bundle and require its exact reply."""
        if self.scripting_commands:
            raise RuntimeError("The prior native scripting command has not settled")
        script = (
            "on run argv\n"
            f"tell application {json.dumps(str(self.app))}\n"
            "return execute lua code (item 1 of argv)\nend tell\nend run"
        )
        command = subprocess.Popen(
            ["/usr/bin/osascript", "-e", script, source],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.scripting_commands.append(command)
        self.scripting_command_number += 1
        try:
            stdout, stderr = command.communicate(timeout=SCRIPTING_TIMEOUT_SECONDS)
        except Exception as primary:
            diagnostics = []
            if isinstance(primary, subprocess.TimeoutExpired):
                try:
                    diagnostics = self.sample_scripting_command(command)
                except Exception as sampling:
                    diagnostics.append(
                        f"native scripting sample failed: {type(sampling).__name__}: {sampling}"
                    )
                try:
                    diagnostics.extend(self.sample_native_runtime())
                except Exception as sampling:
                    diagnostics.append(
                        f"native Hammerspoon server sample failed: {type(sampling).__name__}: {sampling}"
                    )
            try:
                self.retire_scripting_command(command)
            except Exception as cleanup:
                diagnostics.append(
                    f"owned scripting process cleanup failed: {type(cleanup).__name__}: {cleanup}"
                )
            detail = "; ".join(diagnostics)
            raise RuntimeError(
                f"Native scripting command failed: {type(primary).__name__}: {primary}"
                + (f"; {detail}" if detail else "")
            ) from primary
        if command.returncode is None:
            raise RuntimeError(
                "The native scripting command did not acknowledge actual process exit"
            )
        self.scripting_commands.remove(command)
        if command.returncode != 0 or stdout.strip() != self.nonce:
            raise RuntimeError(
                "The packaged native timer scripting command did not acknowledge its nonce "
                f"(exit {command.returncode}): {stderr.strip()[:1000]}"
            )

    def sample_scripting_command(self, command):
        """Sample only an unreaped own child before any timeout retirement signal."""
        diagnostics = []
        if command.poll() is not None:
            return ["native scripting process exited before its timeout sample"]
        # This Popen has not reaped the child: its PID cannot be reused while
        # the independent sampler runs, even if the child exits meanwhile.
        sample = self.output / f"sample-osascript-{self.scripting_command_number}.txt"
        try:
            result = subprocess.run(
                [
                    "/usr/bin/sample",
                    str(command.pid),
                    str(SCRIPT_SAMPLE_SECONDS),
                    "-file",
                    str(sample),
                ],
                capture_output=True,
                text=True,
                timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS,
            )
            if result.returncode or not sample.is_file():
                diagnostics.append(
                    f"native scripting sample refused (exit {result.returncode}): {result.stderr.strip()[:1000]}"
                )
            else:
                diagnostics.append(f"native scripting sample retained: {sample.name}")
                # Job annotations remain readable when artifact downloads fail.
                # Report observed native frames, without guessing a permission
                # or run-loop diagnosis from an unresponsive AppleEvent alone.
                with sample.open(encoding="utf-8", errors="replace") as handle:
                    sample_text = handle.read(SCRIPT_SAMPLE_READ_LIMIT)
                markers = (
                    "TCC",
                    "AppleEvent",
                    "AESend",
                    "AEWait",
                    "NSAppleScript",
                    "LaunchServices",
                )
                frames = self.observed_sample_frames(sample_text, markers)
                if frames:
                    diagnostics.append("observed native scripting frames: " + " | ".join(frames))
        except Exception as error:
            diagnostics.append(f"native scripting sample failed: {type(error).__name__}: {error}")
        return diagnostics

    @staticmethod
    def observed_sample_frames(sample_text, markers):
        """Binary-image presence is not evidence that a stack executes there."""
        stacks = sample_text.split("Binary Images:", 1)[0]
        return list(
            dict.fromkeys(
                line.strip()
                for line in stacks.splitlines()
                if any(marker in line for marker in markers)
            )
        )[:SCRIPT_SAMPLE_FRAME_LIMIT]

    def bind_runtime(self, pid, processes):
        """Retain the exact installed server owner already admitted by the gate."""
        if type(pid) is not int or pid <= 0 or processes(self.executable) != [pid]:
            raise RuntimeError("The native probe cannot bind a foreign or changed runtime owner")
        self.runtime_owner = (pid, processes)

    def sample_native_runtime(self):
        """Observe the qualified server before retirement; never infer TCC causality."""
        if self.runtime_owner is None:
            return ["native Hammerspoon server sample unavailable: no qualified owner"]
        pid, processes = self.runtime_owner
        if processes(self.executable) != [pid]:
            return ["native Hammerspoon server sample unavailable: exact owner changed"]
        sample = self.output / f"sample-hammerspoon-{self.scripting_command_number}.txt"
        result = subprocess.run(
            ["/usr/bin/sample", str(pid), str(SCRIPT_SAMPLE_SECONDS), "-file", str(sample)],
            capture_output=True,
            text=True,
            timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS,
        )
        if result.returncode or not sample.is_file():
            return [
                f"native Hammerspoon server sample refused (exit {result.returncode}): {result.stderr.strip()[:1000]}"
            ]
        if processes(self.executable) != [pid]:
            return ["native Hammerspoon server sample unqualified: owner changed before admission"]
        with sample.open(encoding="utf-8", errors="replace") as handle:
            sample_text = handle.read(SCRIPT_SAMPLE_READ_LIMIT)
        header = sample_text.split("Call graph:", 1)[0]
        fields = {
            line.split(":", 1)[0].strip(): line.split(":", 1)[1].strip()
            for line in header.splitlines()
            if ":" in line
        }
        if (
            fields.get("Path") != str(self.executable)
            or fields.get("Process") != f"{self.executable.name} [{pid}]"
        ):
            return [
                "native Hammerspoon server sample unqualified: native Process/Path identity differs"
            ]
        diagnostics = [f"native Hammerspoon server sample retained: {sample.name}"]
        critical_frames = self.observed_sample_frames(
            sample_text,
            (
                "TCC",
                "AppleEvent",
                "AEWait",
                "NSAppleScript",
                "HSAppleScript",
                "NSAlert",
                "runModal",
                "lua_pcall",
                "dispatch_semaphore_wait",
            ),
        )
        context_frames = self.observed_sample_frames(
            sample_text, ("com.apple.main-thread", "CFRunLoop", "mach_msg")
        )
        frames = list(dict.fromkeys(critical_frames + context_frames))[:SCRIPT_SAMPLE_FRAME_LIMIT]
        if frames:
            diagnostics.append("observed native Hammerspoon server frames: " + " | ".join(frames))
        return diagnostics

    def retire_scripting_command(self, command):
        """Retain the child until bounded communicate acknowledges its actual exit."""
        if command.poll() is None:
            command.kill()
        command.communicate(timeout=SCRIPT_CLEANUP_TIMEOUT_SECONDS)
        if command.returncode is None:
            raise RuntimeError(
                "The native scripting cleanup did not acknowledge actual process exit"
            )
        self.scripting_commands.remove(command)

    def observe(self, pid, processes):
        """Retain and judge the async native receipt within a bounded observation."""
        fixture = Path(__file__).with_name("hs_delayed_timer_native.lua")
        receipt = self.output / "native-delayed-timers.json"
        if receipt.exists():
            raise RuntimeError("A native delayed-timer receipt already exists")
        if processes(self.executable) != [pid]:
            raise RuntimeError(
                "The native delayed-timer runtime is not the launcher's exact live process"
            )
        self.bind_runtime(pid, processes)
        source = "return dofile({}).run({}, {})".format(
            json.dumps(str(fixture), ensure_ascii=False),
            json.dumps(str(receipt), ensure_ascii=False),
            json.dumps(self.nonce),
        )
        self.started = True
        primary_error = None
        try:
            self.execute(source)
            deadline = time.monotonic() + 15
            while not receipt.exists():
                if time.monotonic() >= deadline or processes(self.executable) != [pid]:
                    raise RuntimeError(
                        "Native delayed-timer receipt timed out or its exact process exited"
                    )
                time.sleep(0.05)
            result = json.loads(
                receipt.read_text(encoding="utf-8"), object_pairs_hook=unique_object
            )
            if processes(self.executable) != [pid]:
                raise RuntimeError(
                    "The native delayed-timer process changed before receipt admission"
                )
            return validate_receipt(result, self.nonce, pid, self.executable, self.domain)
        except Exception as error:
            primary_error = error
            raise
        finally:
            try:
                if self.started and processes(self.executable) == [pid]:
                    self.execute(
                        "return dofile({}).cleanup({})".format(
                            json.dumps(str(fixture), ensure_ascii=False), json.dumps(self.nonce)
                        )
                    )
            except Exception as cleanup_error:
                cleanup_cause = f"{type(cleanup_error).__name__}: {cleanup_error}"
                if primary_error is None:
                    raise RuntimeError(
                        f"Native delayed-timer cleanup failed: {cleanup_cause}"
                    ) from cleanup_error
                raise RuntimeError(
                    "Native delayed-timer observation failed: "
                    f"{type(primary_error).__name__}: {primary_error}; "
                    f"native cleanup failed: {cleanup_cause}"
                ) from primary_error

    def restore(self):
        """Restore the scripting key after ordinary Quit or exact process cleanup."""
        for command in list(self.scripting_commands):
            self.retire_scripting_command(command)
        self.preference.restore()
