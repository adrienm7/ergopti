# tools/diagnostics/hs_delayed_timer_probe.py
"""Observe real packaged timers through the launch gate's existing native process."""

import base64
import json
import math
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import sys
import time

CONTRACT = json.loads(Path(__file__).with_name("hs_delayed_timer_contract.json").read_text())
APPLE_SCRIPT_KEY = "HSAppleScriptEnabledKey"
SCRIPTING_TIMEOUT_SECONDS = 10
SCRIPT_SAMPLE_SECONDS = 1
SCRIPT_CLEANUP_TIMEOUT_SECONDS = 2
SCRIPT_SAMPLE_READ_LIMIT = 65536
SCRIPT_SAMPLE_FRAME_LIMIT = 6
SCRIPT_SAMPLE_CONTEXT_THREAD_LIMIT = 3
SCRIPT_SAMPLE_CONTEXT_FRAME_LIMIT = 24
SCRIPT_SAMPLE_CONTEXT_CHARACTER_LIMIT = 4096
SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT = 8192
SCRIPT_DIAGNOSTIC_LINE_LIMIT = 128
SCRIPTING_PHASES = ("control", "constructor", "pid_control", "observation", "cleanup")
SCRIPT_DIAGNOSTIC_RECEIPT_LIMIT = len(SCRIPTING_PHASES)
CONTROL_CONTRACT = "hs.applescript.control"
PID_CONTROL_CONTRACT = "hs.applescript.pid-control"
CONSTRUCTOR_CONTRACT = "hs.applescript.constructor"
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


def validate_control_summary(summary, feature=None):
    """Require exact owned control identity without treating it as feature proof."""
    _validate_owned_control(summary, CONTROL_CONTRACT, "control", feature)


def validate_pid_control_summary(summary, feature=None):
    """Qualify only the separate PID diagnostic, never a path or feature proof."""
    _validate_owned_control(summary, PID_CONTROL_CONTRACT, "pid_control", feature)


def _validate_owned_control(summary, contract, phase, feature):
    """Check one explicitly named control's acknowledgement and native identity."""
    fields = {"schema_version", "contract", "phase", "acknowledged", "nonce", "pid", "executable"}
    if not isinstance(summary, dict) or set(summary) != fields:
        raise ValueError("The native AppleEvent control receipt is incomplete")
    for key, expected in {
        "schema_version": 1,
        "contract": contract,
        "phase": phase,
        "acknowledged": True,
    }.items():
        if type(summary[key]) is not type(expected) or summary[key] != expected:
            raise ValueError(f"Native AppleEvent control acknowledgement differs: {key}")
    if (
        type(summary["pid"]) is not int
        or summary["pid"] <= 0
        or not isinstance(summary["nonce"], str)
        or re.fullmatch(r"[0-9a-f]{32}", summary["nonce"]) is None
        or not isinstance(summary["executable"], str)
        or not summary["executable"].startswith("/")
    ):
        raise ValueError("Native AppleEvent control identity is invalid")
    if isinstance(feature, dict):
        for key in ("nonce", "pid", "executable"):
            if type(feature.get(key)) is not type(summary[key]) or feature.get(key) != summary[key]:
                raise ValueError(f"Native AppleEvent control and feature owners differ: {key}")


def validate_constructor_receipt(raw, nonce, pid, direct_text):
    """Require measured descriptor bytes and Unicode without admitting delivery."""
    if (
        not isinstance(raw, str)
        or len(raw) > SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT
        or not raw.startswith("{")
        or not raw.endswith("}\n")
        or "\n" in raw[:-1]
    ):
        raise ValueError("The native constructor receipt is not one bounded JSON line")
    result = json.loads(raw, object_pairs_hook=unique_object)
    expected = {
        "schema_version": 1,
        "contract": CONSTRUCTOR_CONTRACT,
        "phase": "constructor",
        "constructed": True,
        "nonce": nonce,
        "pid": pid,
        "address_type": 0x6B706964,
        "event_class": 0x486D5370,
        "event_id": 0x45584543,
        "direct_type": 0x75747874,
        "direct_text": direct_text,
    }
    if not isinstance(result, dict) or set(result) != set(expected) | {"address_bytes_base64"}:
        raise ValueError("The native constructor receipt has incomplete descriptor fields")
    for key, value in expected.items():
        if type(result[key]) is not type(value) or result[key] != value:
            raise ValueError(f"The native constructor descriptor differs: {key}")
    encoded = result["address_bytes_base64"]
    if not isinstance(encoded, str) or len(encoded) != 8:
        raise ValueError("The native constructor address bytes are not a pid_t")
    try:
        address = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise ValueError("The native constructor address bytes are invalid") from error
    if (
        len(address) != 4
        or base64.b64encode(address).decode("ascii") != encoded
        or int.from_bytes(address, sys.byteorder, signed=True) != pid
    ):
        raise ValueError("The native constructor address bytes differ from the exact owned PID")
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
        self.diagnostic_receipts = []
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

    def execute(self, source, phase="observation", _target_pid=None):
        """Require the owned reply; PID addressing is exclusive to its diagnostic."""
        if phase not in SCRIPTING_PHASES:
            raise ValueError("The native scripting phase is unknown")
        if self.scripting_commands:
            raise RuntimeError("The prior native scripting command has not settled")
        script = (
            "on run argv\n"
            f"tell application {json.dumps(str(self.app))}\n"
            "return execute lua code (item 1 of argv)\nend tell\nend run"
        )
        arguments = ["/usr/bin/osascript", "-e", script, source]
        if phase in ("pid_control", "constructor"):
            if self.runtime_owner is None:
                raise RuntimeError("The PID control has no bound native runtime")
            pid, processes = self.runtime_owner
            if (
                type(_target_pid) is not int
                or _target_pid != pid
                or processes(self.executable) != [pid]
            ):
                raise RuntimeError("The PID control target differs from its exact live owner")
            # The sender remains osascript. Only the address changes: a raw kernel
            # PID bypasses application-path resolution while HmSp/EXEC still
            # reaches the pinned NSScriptCommand and its enabled preference.
            script = (
                self.constructor_script() if phase == "constructor" else self.pid_control_script()
            )
            arguments = ["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(pid), source]
            if phase == "constructor":
                arguments.append(self.nonce)
        elif _target_pid is not None:
            raise ValueError("A PID address is reserved for its distinct diagnostic")
        command = subprocess.Popen(
            arguments,
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
            self.retain_diagnostics(diagnostics, phase)
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
        if phase == "constructor":
            if command.returncode != 0:
                raise RuntimeError(
                    "The native descriptor constructor refused its bounded receipt "
                    f"(exit {command.returncode}): {stderr.strip()[:1000]}"
                )
            return validate_constructor_receipt(stdout, self.nonce, pid, source)
        acknowledged = (
            stdout == self.nonce + "\n"
            if phase in ("control", "pid_control")
            else stdout.strip() == self.nonce
        )
        if command.returncode != 0 or not acknowledged:
            raise RuntimeError(
                "The packaged native timer scripting command did not acknowledge its nonce "
                f"(exit {command.returncode}): {stderr.strip()[:1000]}"
            )

        return self.nonce

    def control(self, pid, processes):
        """Test the same live AppleEvent handler with an exact owned nonce line."""
        self.bind_runtime(pid, processes)
        acknowledgement = self.execute("return " + json.dumps(self.nonce), phase="control")
        if type(acknowledgement) is not str or acknowledgement != self.nonce:
            raise RuntimeError("The native AppleEvent control owner did not acknowledge its nonce")
        if processes(self.executable) != [pid]:
            raise RuntimeError(
                "The native AppleEvent control process changed before receipt admission"
            )
        return {
            "schema_version": 1,
            "contract": CONTROL_CONTRACT,
            "phase": "control",
            "acknowledged": True,
            "nonce": self.nonce,
            "pid": pid,
            "executable": str(self.executable),
        }

    @staticmethod
    def pid_event_constructor():
        """Construct the one native command shared by smoke and actual sending."""
        return """ObjC.import('Foundation');
function constructOwnedEvent(pid, source) {
    if (!Number.isInteger(pid) || pid <= 0) throw new Error('PID control target refused');
    var target = $.NSAppleEventDescriptor.descriptorWithProcessIdentifier(pid);
    if (target.isNil() || Number(target.descriptorType) !== 0x6b706964)
        throw new Error('Native kernel-PID address refused');
    var event = $.NSAppleEventDescriptor.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(
        0x486d5370, 0x45584543, target, -1, 0);
    event.setParamDescriptorForKeyword($.NSAppleEventDescriptor.descriptorWithString(source), 0x2d2d2d2d);
    return event;
}
"""

    @staticmethod
    def pid_control_script():
        """Send the pinned direct-text command to a kernel PID from osascript."""
        return (
            NativeDelayedTimerProbe.pid_event_constructor()
            + """
function run(argv) {
    if (argv.length !== 2) throw new Error('PID control arguments refused');
    var event = constructOwnedEvent(Number(argv[0]), argv[1]);
    var error = Ref();
    var reply = event.sendEventWithOptionsTimeoutError(3, __SCRIPTING_TIMEOUT_SECONDS__, error);
    if (!reply || reply.isNil()) {
        var nativeError = error[0];
        var status = nativeError && !nativeError.isNil() ? Number(nativeError.code) : 'unavailable';
        throw new Error('Native PID AppleEvent send refused (status ' + status + ')');
    }
    var errorNumber = reply.paramDescriptorForKeyword(0x6572726e);
    if (!errorNumber.isNil() && Number(errorNumber.int32Value) !== 0)
        throw new Error('Native PID AppleEvent handler refused (status ' + Number(errorNumber.int32Value) + ')');
    var result = reply.paramDescriptorForKeyword(0x2d2d2d2d);
    if (result.isNil()) throw new Error('Native PID AppleEvent result missing');
    return ObjC.unwrap(result.stringValue);
}
""".replace("__SCRIPTING_TIMEOUT_SECONDS__", json.dumps(SCRIPTING_TIMEOUT_SECONDS))
        )

    @staticmethod
    def constructor_script():
        """Inspect native construction only; this script never sends or launches."""
        return (
            NativeDelayedTimerProbe.pid_event_constructor()
            + """
function run(argv) {
    if (argv.length !== 3) throw new Error('Constructor arguments refused');
    var pid = Number(argv[0]);
    var event = constructOwnedEvent(pid, argv[1]);
    var address = event.attributeDescriptorForKeyword(0x61646472);
    var direct = event.paramDescriptorForKeyword(0x2d2d2d2d);
    if (address.isNil() || direct.isNil()) throw new Error('Native descriptor inspection refused');
    return JSON.stringify({schema_version: 1, contract: 'hs.applescript.constructor',
        phase: 'constructor', constructed: true, nonce: argv[2], pid: pid,
        address_type: Number(address.descriptorType),
        address_bytes_base64: ObjC.unwrap(address.data.base64EncodedStringWithOptions(0)),
        event_class: Number(event.eventClass), event_id: Number(event.eventID),
        direct_type: Number(direct.descriptorType), direct_text: ObjC.unwrap(direct.stringValue)});
}
"""
        )

    def constructor_control(self, pid, processes):
        """Measure the actual bridge in native scenarios without sending an event."""
        self.bind_runtime(pid, processes)
        direct_text = "return " + json.dumps(self.nonce + " — ù ★", ensure_ascii=False)
        receipt = self.execute(direct_text, phase="constructor", _target_pid=pid)
        if processes(self.executable) != [pid]:
            raise RuntimeError("The native constructor process changed before receipt admission")
        receipt = validate_constructor_receipt(
            json.dumps(receipt, ensure_ascii=False) + "\n", self.nonce, pid, direct_text
        )
        receipt["executable"] = str(self.executable)
        self.retain_diagnostics(
            ["Actual native kernel-PID, event and Unicode descriptor construction qualified"],
            phase="constructor",
        )
        return receipt

    def control_pid(self, pid, processes):
        """Compare exact-PID delivery without admitting the original feature gate."""
        self.bind_runtime(pid, processes)
        acknowledgement = self.execute(
            "return " + json.dumps(self.nonce), phase="pid_control", _target_pid=pid
        )
        if type(acknowledgement) is not str or acknowledgement != self.nonce:
            raise RuntimeError("The native PID control did not acknowledge its nonce")
        if processes(self.executable) != [pid]:
            raise RuntimeError("The native PID control process changed before receipt admission")
        receipt = {
            "schema_version": 1,
            "contract": PID_CONTROL_CONTRACT,
            "phase": "pid_control",
            "acknowledged": True,
            "nonce": self.nonce,
            "pid": pid,
            "executable": str(self.executable),
        }
        validate_pid_control_summary(receipt)
        self.retain_diagnostics(
            ["Exact owned kernel-PID control acknowledged its nonce"], phase="pid_control"
        )
        return receipt

    def pid_control_error_diagnostic(self, error):
        """Bound the alternate control error without publishing its script argv."""
        if isinstance(error, subprocess.TimeoutExpired) or isinstance(
            error.__cause__, subprocess.TimeoutExpired
        ):
            detail = (
                "TimeoutExpired: the owned PID scripting command exceeded its unchanged deadline"
            )
        else:
            detail = f"{type(error).__name__}: {error}"
        return self.bounded_diagnostic_text(detail)

    @staticmethod
    def bounded_diagnostic_text(text):
        """Apply the one shared source-redaction and receipt-size policy."""
        observations = NativeDelayedTimerProbe.sample_frame_text(text)
        lines = observations.splitlines()
        if (
            len(observations) > SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT
            or len(lines) > SCRIPT_DIAGNOSTIC_LINE_LIMIT
        ):
            marker = "\n[native diagnostic truncated]"
            observations = "\n".join(lines[: SCRIPT_DIAGNOSTIC_LINE_LIMIT - 1])
            observations = observations[: SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT - len(marker)] + marker
        return observations

    def retain_diagnostics(self, diagnostics, phase="observation"):
        """Retain bounded native observations independently of error annotations."""
        if not diagnostics:
            return
        if len(self.diagnostic_receipts) >= SCRIPT_DIAGNOSTIC_RECEIPT_LIMIT:
            self.diagnostic_receipts[-1]["additional_commands_omitted"] = True
            return
        # Path control, construction, PID control and feature lifecycle own native
        # sampling replies. Do not include the Lua source or the primary error;
        # either could contain unrelated user data. Redact native source paths.
        observations = self.bounded_diagnostic_text("\n".join(diagnostics))
        self.diagnostic_receipts.append(
            {
                "command": self.scripting_command_number,
                "phase": phase,
                "observations": observations,
            }
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

    @staticmethod
    def sample_frame_text(line):
        """Retain native symbols while omitting private source locations from logs."""
        safe = re.sub(r"\([^)]*/[^)]*\)", "(location redacted)", line)
        return re.sub(r"(?:https?://|/)[^\s)]+", "[path redacted]", safe)

    @staticmethod
    def observed_sample_contexts(sample_text, markers):
        """Keep native thread ownership and call ancestry instead of merging frames."""
        if "Call graph:" not in sample_text:
            return []
        stacks = sample_text.split("Call graph:", 1)[1].split("Binary Images:", 1)[0]
        threads = []
        current = None
        ancestors = []
        for line in stacks.splitlines():
            thread = re.match(r"^\s*(\d+\s+Thread_(?:\d+|0x[0-9a-fA-F]+))\b(.*)$", line)
            if thread:
                queue = re.search(
                    r"\b(DispatchQueue_\d+)(?::\s*([A-Za-z_][A-Za-z0-9_.-]*)(?=\s|$))?",
                    thread[2],
                )
                main = queue is not None and queue[2] == "com.apple.main-thread"
                label = thread[1]
                if queue:
                    label += " " + queue[1]
                    if queue[2]:
                        label += ": " + queue[2]
                current = {
                    "label": label,
                    "main": main,
                    "frames": [],
                    "selected": set(),
                    "critical": [],
                }
                threads.append(current)
                ancestors = []
                continue
            frame = re.match(r"^([ \t+!|:]*)(\d+\s+.+)$", line)
            if current is None or not frame:
                continue
            depth = len(frame[1].expandtabs())
            while ancestors and ancestors[-1][0] >= depth:
                ancestors.pop()
            index = len(current["frames"])
            # Source locations can contain private paths; retain symbols and native ancestry.
            safe = NativeDelayedTimerProbe.sample_frame_text(line)
            current["frames"].append(safe)
            ancestors.append((depth, index))
            critical = any(marker in safe for marker in markers)
            if critical:
                current["critical"].append(index)
            if critical or (
                current["main"] and any(marker in frame[2] for marker in ("CFRunLoop", "mach_msg"))
            ):
                current["selected"].update(ancestor[1] for ancestor in ancestors)
        selected = [thread for thread in threads if thread["selected"]]
        selected.sort(key=lambda thread: not thread["main"])
        contexts = []
        remaining = SCRIPT_SAMPLE_CONTEXT_CHARACTER_LIMIT
        for thread in selected[:SCRIPT_SAMPLE_CONTEXT_THREAD_LIMIT]:
            indices = sorted(thread["selected"])
            truncated = len(indices) > SCRIPT_SAMPLE_CONTEXT_FRAME_LIMIT
            if truncated:
                retained = set(thread["critical"][:SCRIPT_SAMPLE_FRAME_LIMIT])
                retained.update(indices[:2])
                for index in reversed(indices):
                    if len(retained) >= SCRIPT_SAMPLE_CONTEXT_FRAME_LIMIT:
                        break
                    retained.add(index)
                indices = sorted(retained)
            omitted = thread["selected"] - set(indices)
            heading = "observed native Hammerspoon server thread: " + thread["label"]
            context = heading
            previous = -1
            truncation_note = "\n[native sample context truncated]"
            for index in indices:
                gap = (
                    "\n[native ancestry omitted]"
                    if any(previous < item < index for item in omitted)
                    else ""
                )
                frame = gap + "\n" + thread["frames"][index]
                if len(context) + len(frame) + len(truncation_note) > remaining:
                    truncated = True
                    break
                context += frame
                previous = index
            if truncated:
                context += truncation_note
            if len(context) > remaining:
                break
            contexts.append(context)
            remaining -= len(context)
        if len(selected) > len(contexts) and contexts:
            note = "\n[additional native thread contexts omitted]"
            if len(note) <= remaining:
                contexts[-1] += note
        return contexts

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
        if "Call graph:" not in sample_text:
            diagnostics.append(
                "native Hammerspoon server stack context unavailable: no Call graph section"
            )
            return diagnostics
        markers = (
            "TCC",
            "AppleEvent",
            "AEWait",
            "NSAppleScript",
            "HSAppleScript",
            "NSAlert",
            "runModal",
            "lua_pcall",
            "dispatch_semaphore_wait",
        )
        contexts = self.observed_sample_contexts(sample_text, markers)
        if contexts:
            diagnostics.extend(contexts)
        else:
            stacks = sample_text.split("Call graph:", 1)[-1]
            critical_frames = self.observed_sample_frames(stacks, markers)
            context_frames = self.observed_sample_frames(stacks, ("CFRunLoop", "mach_msg"))
            frames = list(dict.fromkeys(critical_frames + context_frames))[
                :SCRIPT_SAMPLE_FRAME_LIMIT
            ]
            frames = [self.sample_frame_text(frame) for frame in frames]
            if frames:
                diagnostics.append(
                    "observed native Hammerspoon server frames (thread unattributed): "
                    + " | ".join(frames)
                )
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
                        ),
                        phase="cleanup",
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
