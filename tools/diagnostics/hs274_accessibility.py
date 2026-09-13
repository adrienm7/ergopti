# tools/diagnostics/hs274_accessibility.py
"""Use the runner's ordinary settings UI to approve its owned Hammerspoon app."""
import subprocess


SCRIPT = '''
tell application "System Events"
    if not UI elements enabled then error "Runner UI automation is unavailable"
    repeat 40 times
        if exists window 1 of process "System Settings" then exit repeat
        delay 0.1
    end repeat
    tell process "System Settings"
        set candidates to {}
        set observations to ""
        repeat with scanIndex from 1 to 40
            set controls to entire contents of window 1
            set candidates to {}
            set observations to ""
            repeat with node in controls
                set controlRole to role of node as text
                set controlName to ""
                set controlDescription to ""
                if exists attribute "AXTitle" of node then
                    set candidateName to value of attribute "AXTitle" of node
                    if candidateName is not missing value then set controlName to candidateName as text
                end if
                if exists attribute "AXDescription" of node then
                    set candidateDescription to value of attribute "AXDescription" of node
                    if candidateDescription is not missing value then set controlDescription to candidateDescription as text
                end if
                set observations to observations & controlRole & tab & controlName & tab & controlDescription & linefeed
                if controlRole is "AXCheckBox" and (controlName is "Hammerspoon" or controlDescription is "Hammerspoon") then
                    set end of candidates to contents of node
                end if
            end repeat
            if scanIndex is 1 then log observations
            if (count candidates) > 0 then exit repeat
            delay 0.1
        end repeat
        if (count candidates) is not 1 then return "No unique Hammerspoon checkbox" & linefeed & observations
        set approvalControl to item 1 of candidates
        if (value of approvalControl as integer) is 0 then perform action "AXPress" of approvalControl
        repeat 30 times
            if (value of approvalControl as integer) is 1 then return "enabled"
            delay 0.1
        end repeat
        return "Hammerspoon checkbox did not become enabled" & linefeed & observations
    end tell
end tell
'''


def approve_accessibility(report):
    """Retain the actual UI response; native Hammerspoon separately verifies trust."""
    state = report.setdefault("hammerspoon_accessibility", {})
    state["stage"] = "open_settings"
    try:
        subprocess.run(["/usr/bin/open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"],
                       check=True, capture_output=True, text=True, timeout=5)
        state["stage"] = "approval"
        result = subprocess.run(["/usr/bin/osascript", "-e", SCRIPT], capture_output=True, text=True, timeout=15)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        state.update(exit=getattr(error, "returncode", None), timed_out=isinstance(error, subprocess.TimeoutExpired))
        for name in ("stdout", "stderr"):
            value = getattr(error, name, None)
            state[name] = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        raise
    state.update(exit=result.returncode, stdout=result.stdout, stderr=result.stderr)
    if result.returncode != 0 or result.stdout.strip() != "enabled":
        raise RuntimeError("Normal Hammerspoon accessibility approval was not confirmed")
