# tools/diagnostics/hs274-provider.py
"""Observe signed DriverKit activation on a disposable macOS Actions runner."""

import json
import os
from pathlib import Path
import subprocess
import sys


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
        ("screenshot", ["screencapture", "-x", str(output / "hs274-provider-settings.png")]),
    ]
    for name, command in commands:
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
        if not report["extension_activated_and_enabled"]:
            report["approval_ui"] = observe_approval_ui(output)
    except Exception as error:
        report["observation_error"] = f"{type(error).__name__}: {error}"
    finally:
        with (output / "hs274-provider.json").open("x", encoding="utf-8", newline="\n") as receipt:
            json.dump(report, receipt, indent=2)
            receipt.write("\n")
    return 0 if report["extension_activated_and_enabled"] else 1


if __name__ == "__main__":
    sys.exit(main())
