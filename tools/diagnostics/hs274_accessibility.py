# tools/diagnostics/hs274_accessibility.py
"""Use the runner's ordinary settings UI to approve its owned Hammerspoon app."""
import subprocess


PREPARE_SCRIPT = '''
log "HS274 settings preparation started"
tell application "System Events"
    if not UI elements enabled then error "Runner UI automation is unavailable"
    if not (exists process "System Settings") then return "no_sheet"
    tell process "System Settings"
        if not (exists window 1) then return "no_sheet"
        if not (exists sheet 1 of window 1) then return "no_sheet"
        log "HS274 reading existing settings sheet"
        set nodes to entire contents of sheet 1 of window 1
        if (count nodes) > 256 then error "Settings sheet exceeds observation limit"
        set providerVerified to false
        set panelVerified to false
        set doneButtons to {}
        repeat with node in nodes
            if role of node is "AXStaticText" then
                set labelText to value of attribute "AXValue" of node
                if labelText is "Driver Extensions" then set panelVerified to true
                if labelText is "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice" then set providerVerified to true
            else if role of node is "AXButton" and name of node is "Done" then
                set end of doneButtons to contents of node
            end if
        end repeat
        if not providerVerified or not panelVerified or (count doneButtons) is not 1 then error "Existing settings sheet is not the owned provider panel"
        if not enabled of item 1 of doneButtons then error "Owned provider panel cannot be dismissed yet"
        perform action "AXPress" of item 1 of doneButtons
        repeat 20 times
            if not (exists sheet 1 of window 1) then return "dismissed"
            delay 0.1
        end repeat
        error "Owned provider panel did not close"
    end tell
end tell
'''


SCRIPT = '''
log "HS274 accessibility UI started"
tell application "System Events"
    if not UI elements enabled then error "Runner UI automation is unavailable"
    log "HS274 UI automation is available"
    repeat 40 times
        if exists window 1 of process "System Settings" then exit repeat
        delay 0.1
    end repeat
    tell process "System Settings"
        set frontmost to true
        set candidates to {}
        set observations to ""
        repeat with scanIndex from 1 to 40
            log "HS274 reading main settings content"
            set mainContent to group 2 of splitter group 1 of group 1 of window 1
            set controls to entire contents of mainContent
            if (count controls) > 256 then error "Accessibility panel exceeds observation limit"
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
                if controlRole is "AXStaticText" then
                    set observations to observations & "label=" & (value of attribute "AXValue" of node as text) & linefeed
                end if
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
    state["stage"] = "prepare_settings"
    try:
        preparation = subprocess.run(["/usr/bin/osascript", "-e", PREPARE_SCRIPT],
                                     capture_output=True, text=True, timeout=10)
        report["hammerspoon_settings_preparation"] = {
            "exit": preparation.returncode, "stdout": preparation.stdout, "stderr": preparation.stderr}
        if preparation.returncode != 0 or preparation.stdout.strip() not in ("no_sheet", "dismissed"):
            raise RuntimeError("Owned settings preparation was not confirmed")
        state["stage"] = "open_settings"
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
