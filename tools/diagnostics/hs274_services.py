# tools/diagnostics/hs274_services.py
"""Fence installed remapper peers during a disposable development experiment."""

import os
import re
import subprocess
import sys


def command(arguments):
    """Retain native failure output instead of treating a failed query as absence."""
    return subprocess.run(arguments, capture_output=True, text=True, timeout=5, check=False)


def require_success(arguments):
    """Return a successful native query or raise with its diagnostic."""
    result = command(arguments)
    if result.returncode != 0:
        raise RuntimeError(f"{arguments}: {result.returncode}: {result.stdout} {result.stderr}")
    return result.stdout


def service_targets():
    """Use the actual pinned plist labels, including the core agent revision."""
    return (
        f"gui/{os.getuid()}/org.pqrs.service.agent.Karabiner-Core-Service-rev2",
        f"gui/{os.getuid()}/org.pqrs.service.agent.Karabiner-Console-User-Server",
        "system/org.pqrs.service.daemon.Karabiner-Core-Service",
    )


def verify_disabled(report):
    """Require the explicit launchd override after upstream registration attempts."""
    states = {}
    for target in service_targets():
        domain, label = target.rsplit("/", 1)
        output = require_success(["sudo", "-n", "launchctl", "print-disabled", domain])
        states[target] = bool(re.search(r'"' + re.escape(label) + r'"\s*=>\s*true', output))
    report.setdefault("service_fence_checks", []).append(states)
    if not all(states.values()):
        raise RuntimeError("Installed remapper service fence was not retained")


def disable_installed_peers(report):
    """Disable only the three installed peers on the disposable Actions machine."""
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Service isolation requires disposable macOS Actions")
    if not os.environ.get("HS274_DEVELOPMENT_ROOT"):
        raise RuntimeError("Service isolation requires explicit development mode")
    for target in service_targets():
        require_success(["sudo", "-n", "launchctl", "disable", target])
        state = command(["sudo", "-n", "launchctl", "print", target])
        if state.returncode == 0:
            require_success(["sudo", "-n", "launchctl", "bootout", target])
        elif "Could not find service" not in state.stderr:
            raise RuntimeError(f"Cannot establish service absence: {target}: {state.stderr}")
    # Re-enabling here would allow stock peers to race cleanup of the shared IPC
    # paths. These three overrides last only until this owned runner is disposed.
    report["service_fence_retained_until_runner_disposal"] = True
    verify_disabled(report)


def check_runtime_processes(runtime, report, phase, active):
    """Require exact executable identities; process creation alone proves nothing."""
    output = require_success(["ps", "-axo", "pid=,comm="])
    rows = []
    expected = {str(runtime["core"]), str(runtime["console"])}
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            raise RuntimeError("Malformed native process inventory")
        pid, executable = fields
        if executable.endswith(("/Karabiner-Core-Service", "/Karabiner-Console-User-Server")):
            rows.append({"pid": int(pid), "executable": executable})
    report.setdefault("runtime_process_inventory", {})[phase] = rows
    if any(row["executable"] not in expected for row in rows):
        raise RuntimeError("An installed or unexpected remapper peer is running")
    if active:
        counts = {path: sum(row["executable"] == path for row in rows) for path in expected}
        if counts != {str(runtime["core"]): 2, str(runtime["console"]): 1}:
            raise RuntimeError(f"Development runtime cohort is incomplete or duplicated: {counts}")
    elif rows:
        raise RuntimeError("Remapper peers outlived the owned process scope")
