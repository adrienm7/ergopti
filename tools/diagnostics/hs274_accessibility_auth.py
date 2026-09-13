# tools/diagnostics/hs274_accessibility_auth.py
"""Authenticate only the observed Accessibility settings sheet on disposable CI."""
import os
from pathlib import Path
import subprocess

from hs274_accounts import approval_account


SCRIPT = '''
set approvalName to system attribute "HS274_APPROVAL_USER"
set approvalPassword to system attribute "HS274_APPROVAL_PASSWORD"
if approvalName is "" or approvalPassword is "" then error "Missing temporary approval credentials"
tell application "System Events"
    tell process "System Settings"
        if name of window 1 is not "Accessibility" then error "Accessibility page changed before authentication"
        set authNodes to entire contents of sheet 1 of window 1
        if (count authNodes) > 32 then error "Authentication sheet exceeds observation limit"
        set promptVerified to false
        set userFields to {}
        set passwordFields to {}
        set confirmButtons to {}
        repeat with node in authNodes
            if role of node is "AXStaticText" then
                set promptText to value of attribute "AXValue" of node
                if promptText is "Privacy & Security is trying to modify your system settings." then set promptVerified to true
            else if role of node is "AXTextField" then
                if subrole of node is "AXSecureTextField" then
                    set end of passwordFields to contents of node
                else
                    set end of userFields to contents of node
                end if
            else if role of node is "AXButton" and name of node is "Modify Settings" then
                set end of confirmButtons to contents of node
            end if
        end repeat
        if not promptVerified then error "Accessibility authentication prompt is not verified"
        if (count userFields) is not 1 or (count passwordFields) is not 1 or (count confirmButtons) is not 1 then error "Authentication controls are not unique"
        if not enabled of item 1 of confirmButtons then error "Authentication confirmation is disabled"
        set value of item 1 of userFields to approvalName
        set value of item 1 of passwordFields to approvalPassword
        perform action "AXPress" of item 1 of confirmButtons
        repeat 30 times
            if not (exists sheet 1 of window "Accessibility") then return "authentication_submitted"
            delay 0.1
        end repeat
        error "Authentication sheet did not retire"
    end tell
end tell
'''


def authenticate_accessibility(report):
    """Retain redacted native evidence and always remove the temporary account."""
    state = report.setdefault("hammerspoon_accessibility_authentication", {})
    output = Path(os.environ["RUNNER_TEMP"])
    with approval_account(output, state) as (name, password):
        environment = dict(os.environ, HS274_APPROVAL_USER=name, HS274_APPROVAL_PASSWORD=password)
        try:
            result = subprocess.run(["/usr/bin/osascript", "-e", SCRIPT], capture_output=True,
                                    text=True, timeout=10, env=environment)
        except subprocess.TimeoutExpired:
            state["timed_out"] = True
            raise RuntimeError("Accessibility authentication timed out") from None
        state.update(exit=result.returncode, stdout=result.stdout.replace(password, "<redacted>"),
                     stderr=result.stderr.replace(password, "<redacted>"))
        if result.returncode != 0 or result.stdout.strip() != "authentication_submitted":
            raise RuntimeError("Accessibility authentication was not confirmed")
