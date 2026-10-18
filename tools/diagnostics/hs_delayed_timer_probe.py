# tools/diagnostics/hs_delayed_timer_probe.py
"""Judge real packaged timer receipts and own the native scripting preference.

The startup-file bootstrap (hs_native_bootstrap_probe.py) runs the native timer
fixture; this module holds the receipt judge, the installed runtime identity and
the bounded diagnostic policy that every native qualification shares.
"""

import json
import math
from pathlib import Path
import plistlib
import re
import subprocess

CONTRACT = json.loads(Path(__file__).with_name("hs_delayed_timer_contract.json").read_text())
APPLE_SCRIPT_KEY = "HSAppleScriptEnabledKey"
SCRIPTING_TIMEOUT_SECONDS = 10
SCRIPT_CLEANUP_TIMEOUT_SECONDS = 2
SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT = 8192
SCRIPT_DIAGNOSTIC_LINE_LIMIT = 128
CHECK_COUNT = (
    len(CONTRACT["boolean_observations"])
    + len(CONTRACT["remaining_limits"])
    + len(CONTRACT["deliveries"])
)


def executable_path(app):
    """Return the exact installed native executable the launcher owns."""
    return app / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"


# The installed runtime every native qualification must observe.
INSTALLED_EXECUTABLE = str(executable_path(Path("/Applications/ErgoptiPlus.app")))


def bounded_diagnostic_text(text):
    """Omit private source locations and bound the size of one native diagnostic."""
    safe = re.sub(r"\([^)]*/[^)]*\)", "(location redacted)", text)
    observations = re.sub(r"(?:https?://|/)[^\s)]+", "[path redacted]", safe)
    lines = observations.splitlines()
    if (
        len(observations) > SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT
        or len(lines) > SCRIPT_DIAGNOSTIC_LINE_LIMIT
    ):
        marker = "\n[native diagnostic truncated]"
        observations = "\n".join(lines[: SCRIPT_DIAGNOSTIC_LINE_LIMIT - 1])
        observations = observations[: SCRIPT_DIAGNOSTIC_CHARACTER_LIMIT - len(marker)] + marker
    return observations


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
    if summary["executable"] != INSTALLED_EXECUTABLE:
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
