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
                log "HS274 sheet label: " & (labelText as text)
                if labelText is "Driver Extensions" then set panelVerified to true
                if labelText is "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice" then set providerVerified to true
            else if role of node is "AXButton" then
                -- Native macOS exposes no label for this sheet's sole Done button.
                -- Exact sheet identity and role uniqueness scope the action.
                set end of doneButtons to contents of node
            end if
        end repeat
        if not providerVerified or not panelVerified or (count doneButtons) is not 1 then error "Existing settings sheet is not the owned provider panel: provider=" & providerVerified & ", heading=" & panelVerified & ", Done=" & (count doneButtons)
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
        if exists window 1 of process "System Settings" then
            set pageName to name of window 1 of process "System Settings"
            if pageName is "Accessibility" then exit repeat
        end if
        delay 0.1
    end repeat
    tell process "System Settings"
        if name of window 1 is not "Accessibility" then error "Accessibility navigation did not settle: " & (name of window 1)
        set frontmost to true
        set candidates to {}
        set observations to ""
        log "HS274 reading main settings content"
        set mainContent to group 2 of splitter group 1 of group 1 of window 1
        set controls to entire contents of mainContent
        if (count controls) > 256 then error "Accessibility panel exceeds observation limit"
        repeat with node in controls
            if role of node is "AXRow" then
                set rowNodes to entire contents of node
                if (count rowNodes) > 16 then error "Accessibility row exceeds observation limit"
                set ownedRow to false
                set rowCheckboxes to {}
                repeat with rowNode in rowNodes
                    if role of rowNode is "AXStaticText" then
                        set rowLabel to value of attribute "AXValue" of rowNode as text
                        set observations to observations & "application=" & rowLabel & linefeed
                        if rowLabel is "Hammerspoon" then set ownedRow to true
                    else if role of rowNode is "AXCheckBox" then
                        set end of rowCheckboxes to contents of rowNode
                    end if
                end repeat
                if ownedRow then
                    if (count rowCheckboxes) is not 1 then error "Owned accessibility row has no unique checkbox"
                    set end of candidates to item 1 of rowCheckboxes
                end if
            else if role of node is "AXButton" then
                log (get properties of node)
                log (get name of every attribute of node)
            end if
        end repeat
        log observations
        if (count candidates) is 0 then return "missing_application"
        if (count candidates) is not 1 then error "No unique Hammerspoon checkbox"
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


ADD_SCRIPT = '''
tell application "System Events"
    tell process "System Settings"
        if name of window 1 is not "Accessibility" then error "Accessibility page changed before addition"
        if exists sheet 1 of window 1 then error "Unexpected sheet before application addition"
        set controls to entire contents of group 2 of splitter group 1 of group 1 of window 1
        if (count controls) > 256 then error "Accessibility panel exceeds observation limit"
        set actionButtons to {}
        repeat with node in controls
            if role of node is "AXButton" then set end of actionButtons to contents of node
            if role of node is "AXCheckBox" and focused of node is true then error "A permission row is focused before addition"
        end repeat
        if (count actionButtons) is not 2 then error "Unexpected accessibility action controls"
        if not enabled of item 1 of actionButtons or enabled of item 2 of actionButtons then error "Add/remove control state changed"
        perform action "AXPress" of item 1 of actionButtons
        repeat 30 times
            if exists sheet 1 of window 1 then exit repeat
            delay 0.1
        end repeat
        if not (exists sheet 1 of window 1) then error "Application addition did not open a sheet"
        set nodes to entire contents of sheet 1 of window 1
        if (count nodes) > 256 then error "Application addition sheet exceeds observation limit"
        repeat with node in nodes
            log (role of node as text)
            if role of node is "AXStaticText" then log (value of attribute "AXValue" of node)
            if role of node is "AXButton" then log (get properties of node)
        end repeat
        return "addition_sheet_observed"
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
        if result.returncode == 0 and result.stdout.strip() == "missing_application":
            report["hammerspoon_accessibility_listing"] = {
                "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
            state["stage"] = "add_application"
            result = subprocess.run(["/usr/bin/osascript", "-e", ADD_SCRIPT], capture_output=True, text=True, timeout=10)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        state.update(exit=getattr(error, "returncode", None), timed_out=isinstance(error, subprocess.TimeoutExpired))
        for name in ("stdout", "stderr"):
            value = getattr(error, name, None)
            state[name] = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        raise
    state.update(exit=result.returncode, stdout=result.stdout, stderr=result.stderr)
    if result.returncode != 0 or result.stdout.strip() != "enabled":
        raise RuntimeError("Normal Hammerspoon accessibility approval was not confirmed")
