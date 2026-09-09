# tools/diagnostics/hs274-provider.py
"""Observe signed DriverKit activation on a disposable macOS Actions runner."""

import json
import math
import os
from contextlib import contextmanager
from pathlib import Path
import subprocess
import sys
import time


@contextmanager
def activation_owner(command, log, report):
    """Keep the request process alive through UI work and reap the exact owner."""
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    report["activation_forced_cleanup"] = False
    try:
        yield process
    finally:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            report["activation_forced_cleanup"] = True
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        report["activation_exit"] = process.returncode


def provider_enabled(listing, bundle_id):
    """Require the exact provider's enabled state, not activation alone."""
    return any(
        bundle_id in line.split() and "[activated enabled]" in line
        for line in listing.splitlines()
    )


def observe_approval_ui(output):
    """Inspect the normal approval UI using the runner's existing permissions."""
    notification_script = '''
tell application "System Events"
    set observations to ""
    repeat with processName in {"UserNotificationCenter", "CoreServicesUIAgent"}
        if exists process processName then
            tell process processName
                if exists window 1 then
                    set nodes to entire contents of window 1
                    set verifiedProvider to false
                    set openButtons to {}
                    repeat with node in nodes
                        repeat with attributeName in {"AXTitle", "AXDescription", "AXValue"}
                            if exists attribute attributeName of node then
                                set attributeValue to value of attribute attributeName of node
                                if attributeValue is not missing value then
                                    set attributeText to attributeValue as text
                                    set observations to observations & processName & tab & attributeText & linefeed
                                    if attributeText contains "Karabiner-VirtualHIDDevice-Manager" then set verifiedProvider to true
                                end if
                            end if
                        end repeat
                        if role of node is "AXButton" and name of node is "Open System Settings" then
                            set end of openButtons to contents of node
                        end if
                    end repeat
                    if verifiedProvider and (count openButtons) is 1 then
                        perform action "AXPress" of item 1 of openButtons
                        return "Opened verified provider notification" & linefeed & observations
                    end if
                end if
            end tell
        end if
    end repeat
    return "No uniquely identified provider notification" & linefeed & observations
end tell
'''
    script = '''
tell application "System Events"
    if not UI elements enabled then error "Accessibility is unavailable"
    repeat 20 times
        if exists window 1 of process "System Settings" then exit repeat
        delay 0.25
    end repeat
    tell process "System Settings"
        set frontmost to true
        set observationText to ""
        repeat with attempt from 1 to 10
            try
                set extensionGroup to group 3 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
                if not (exists static text "Driver Extensions" of extensionGroup) then error "Driver section is unavailable"
                if not (exists static text "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice" of extensionGroup) then error "Provider is absent from driver section"
                set nodes to UI elements of extensionGroup
                exit repeat
            on error errorMessage number errorNumber
                set observationText to observationText & "tree attempt " & attempt & ": " & errorNumber & " " & errorMessage & linefeed
                if attempt is 10 then error observationText
                delay 0.5
            end try
        end repeat
        set nodeCount to count nodes
        if nodeCount > 256 then error "Settings tree exceeds observation limit"
        repeat with node in nodes
            set observationText to observationText & (role of node as text)
            repeat with attributeName in {"AXTitle", "AXDescription", "AXValue"}
                if exists attribute attributeName of node then
                    set attributeValue to value of attribute attributeName of node
                    if attributeValue is not missing value then
                        set observationText to observationText & tab & attributeName & "=" & (attributeValue as text)
                    end if
                end if
            end repeat
            set observationText to observationText & linefeed
        end repeat
        set candidateButtons to {}
        set precedingText to ""
        repeat with node in nodes
            if role of node is "AXStaticText" then
                set precedingText to value of attribute "AXValue" of node
            else if role of node is "AXButton" then
                if precedingText is "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice" then
                    set end of candidateButtons to contents of node
                end if
                set precedingText to ""
            else
                set precedingText to ""
            end if
        end repeat
        if (count candidateButtons) is not 1 then error "Provider details button is not unique"
        perform action "AXPress" of item 1 of candidateButtons
        delay 0.5
        set observationText to "Opened verified provider driver details" & linefeed & observationText
        set dialogNodes to entire contents of sheet 1 of window 1
        set providerVerified to false
        set driverPanelVerified to false
        set providerCheckboxes to {}
        repeat with node in dialogNodes
            if role of node is "AXStaticText" then
                set dialogText to value of attribute "AXValue" of node
                if dialogText is "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice" then set providerVerified to true
                if dialogText is "Driver Extensions" then set driverPanelVerified to true
            else if role of node is "AXCheckBox" then
                set end of providerCheckboxes to contents of node
            end if
        end repeat
        if not providerVerified or not driverPanelVerified then error "Provider approval panel is not verified"
        if (count providerCheckboxes) is not 1 then error "Provider checkbox is not unique"
        set providerCheckbox to item 1 of providerCheckboxes
        set providerValue to value of attribute "AXValue" of providerCheckbox
        set observationText to observationText & "checkbox_enabled=" & (enabled of providerCheckbox as text) & linefeed
        set observationText to observationText & "checkbox_value_before=" & (providerValue as text) & linefeed
        if providerValue is 0 then
            if not enabled of providerCheckbox then error "Provider control is disabled"
            set controlPosition to position of providerCheckbox
            set controlSize to size of providerCheckbox
            set geometryText to "HS274_CLICK_TARGET " & (item 1 of controlPosition) & " " & (item 2 of controlPosition) & " " & (item 1 of controlSize) & " " & (item 2 of controlSize)
            set observationText to geometryText & linefeed & observationText
        else if providerValue is not 1 then
            error "Unexpected provider checkbox state"
        else
            set observationText to "HS274_ALREADY_ENABLED" & linefeed & observationText
        end if
        delay 0.5
        return observationText
    end tell
end tell
'''
    results = {}
    commands = [
        ("visible_processes", ["osascript", "-e", 'tell application "System Events" to get name of every process whose visible is true']),
        ("provider_notification", ["osascript", "-e", notification_script]),
        ("open_settings", ["open", "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]),
        ("settings_tree", ["osascript", "-e", script]),
        ("quartz_click", None),
        ("screenshot", ["screencapture", "-x", str(output / "hs274-provider-settings.png")]),
    ]
    for name, command in commands:
        if name == "quartz_click":
            tree = results["settings_tree"]
            if tree.get("exit") != 0:
                results[name] = {"skipped_due_to": "settings_tree_failure"}
                continue
            lines = tree["stdout"].splitlines()
            if lines[0] == "HS274_ALREADY_ENABLED":
                results[name] = {"already_enabled": True}
                continue
            target = lines[0].split()
            if len(target) != 5 or target[0] != "HS274_CLICK_TARGET":
                raise RuntimeError("No verified control geometry was returned")
            x, y, width, height = map(float, target[1:])
            if not all(map(math.isfinite, (x, y, width, height))) or width <= 0 or height <= 0:
                raise RuntimeError("Invalid control geometry")
            command = [str(output / "hs274-provider-click"), str(x + width / 2), str(y + height / 2)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
            results[name] = {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        except subprocess.TimeoutExpired:
            results[name] = {"timed_out": True}
    return results


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
        # The inspected manager awaits the activation delegate. Preserve that
        # owner through approval; an initial wait timeout must not retire it.
        with (output / "hs274-provider-activation.log").open("x", encoding="utf-8") as log:
            with activation_owner([str(manager), "activate"], log, report) as process:
                try:
                    process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    report["activation_timed_out"] = True
                after = subprocess.run(
                    ["systemextensionsctl", "list"], check=True, capture_output=True,
                    text=True, timeout=15,
                )
                report["extensions_after"] = after.stdout
                # A zero manager exit can also mean completion after reboot.
                report["extension_activated_and_enabled"] = provider_enabled(after.stdout, bundle_id)
                if not report["extension_activated_and_enabled"]:
                    report["activation_owner_alive_before_ui"] = process.poll() is None
                    if not report["activation_owner_alive_before_ui"]:
                        raise RuntimeError("Activation owner exited before approval")
                    report["approval_ui"] = observe_approval_ui(output)
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        after_ui = subprocess.run(
                            ["systemextensionsctl", "list"], check=True, capture_output=True,
                            text=True, timeout=min(3, max(0.01, deadline - time.monotonic())),
                        )
                        report["extensions_after_ui"] = after_ui.stdout
                        report["extension_activated_and_enabled"] = provider_enabled(after_ui.stdout, bundle_id)
                        if report["extension_activated_and_enabled"]:
                            break
                        time.sleep(0.5)
    except Exception as error:
        report["observation_error"] = f"{type(error).__name__}: {error}"
    finally:
        with (output / "hs274-provider.json").open("x", encoding="utf-8", newline="\n") as receipt:
            json.dump(report, receipt, indent=2)
            receipt.write("\n")
    return 0 if report["extension_activated_and_enabled"] and "observation_error" not in report else 1


if __name__ == "__main__":
    sys.exit(main())
