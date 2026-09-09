# tools/diagnostics/hs274-provider.py
"""Observe signed DriverKit activation on a disposable macOS Actions runner."""

import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    """Retain native state even when activation waits for approval or fails."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("This observation requires a disposable macOS Actions runner")
    output = Path(os.environ["RUNNER_TEMP"])
    manager = Path("/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager")
    bundle_id = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
    report = {
        "hs274_fixed": False,
        "physical_keyboard_validated": False,
        "input_reports_sent": 0,
        "activation_timeout_seconds": 45,
        "activation_timed_out": False,
        "activation_exit": None,
        "extension_activated_and_enabled": False,
    }
    try:
        before = subprocess.run(
            ["systemextensionsctl", "list"], check=True, capture_output=True,
            text=True, timeout=15,
        )
        report["extensions_before"] = before.stdout
        # The inspected manager waits for an OS delegate, without spawning
        # child processes. run() kills and reaps that exact process on timeout.
        with (output / "hs274-provider-activation.log").open("x", encoding="utf-8") as log:
            try:
                result = subprocess.run(
                    [str(manager), "activate"], stdout=log,
                    stderr=subprocess.STDOUT, timeout=45, check=False,
                )
                report["activation_exit"] = result.returncode
            except subprocess.TimeoutExpired:
                report["activation_timed_out"] = True
        after = subprocess.run(
            ["systemextensionsctl", "list"], check=True, capture_output=True,
            text=True, timeout=15,
        )
        report["extensions_after"] = after.stdout
        # A zero manager exit can mean "will complete after reboot". Only the
        # exact provider's activated/enabled state establishes this capability.
        report["extension_activated_and_enabled"] = any(
            bundle_id in line.split() and "[activated enabled]" in line
            for line in after.stdout.splitlines()
        )
    except Exception as error:
        report["observation_error"] = f"{type(error).__name__}: {error}"
    finally:
        with (output / "hs274-provider.json").open("x", encoding="utf-8", newline="\n") as receipt:
            json.dump(report, receipt, indent=2)
            receipt.write("\n")
    return 0 if report["extension_activated_and_enabled"] else 1


if __name__ == "__main__":
    sys.exit(main())
