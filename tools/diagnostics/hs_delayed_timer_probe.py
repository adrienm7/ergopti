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
        script = (
            "on run argv\n"
            f"tell application {json.dumps(str(self.app))}\n"
            "return execute lua code (item 1 of argv)\nend tell\nend run"
        )
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script, source], capture_output=True, text=True, timeout=10
        )
        if result.returncode or result.stdout.strip() != self.nonce:
            raise RuntimeError(
                "The packaged native timer scripting command did not acknowledge its nonce "
                f"(exit {result.returncode}): {result.stderr.strip()[:1000]}"
            )

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
        self.preference.restore()
