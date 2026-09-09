# tools/diagnostics/hs274-core.py
"""Inspect the signed remapper's own permission receipts on disposable macOS."""

import json
import os
from pathlib import Path
import subprocess
import sys


def permissions_granted(value):
    """Require both explicit native grants, without truthy coercion."""
    return isinstance(value, dict) and all(
        value.get(key) is True
        for key in ("iohid_listen_event_allowed", "accessibility_process_trusted")
    )


def main():
    """Compare direct and Launch Services invocation without changing access."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() == 0:
        raise RuntimeError("Core permission observation requires the disposable Actions console user")
    output = Path(os.environ["RUNNER_TEMP"])
    app = Path("/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app")
    binary = app / "Contents/MacOS/Karabiner-Core-Service"
    report = {"hs274_fixed": False, "physical_keyboard_validated": False, "checks": {}}
    for mode in ("direct", "launch-services"):
        native_receipt = output / ("hs274-core-" + mode + ".json")
        if native_receipt.exists() or native_receipt.with_suffix(".json.tmp").exists():
            raise RuntimeError("Core permission receipt already exists")
        command = [str(binary), "permission-check", str(native_receipt)]
        if mode == "launch-services":
            command = ["open", "-W", "-n", str(app), "--args", "permission-check", str(native_receipt)]
        observation = {}
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
            observation.update(exit=result.returncode, stdout=result.stdout, stderr=result.stderr)
            if native_receipt.is_file():
                observation["native_permissions"] = json.loads(native_receipt.read_text(encoding="utf-8"))
            observation["permissions_granted"] = result.returncode == 0 and permissions_granted(
                observation.get("native_permissions")
            )
        except (OSError, subprocess.TimeoutExpired, ValueError) as error:
            observation["error"] = f"{type(error).__name__}: {error}"
            observation["permissions_granted"] = False
        report["checks"][mode] = observation
    with (output / "hs274-core-permissions.json").open("x", encoding="utf-8", newline="\n") as receipt:
        json.dump(report, receipt, indent=2)
        receipt.write("\n")
    return 0 if all(check["permissions_granted"] for check in report["checks"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
