# tools/diagnostics/hs274_accessibility_picker.py
"""Select the exact owned app through the native Accessibility file picker."""
from pathlib import Path
import subprocess


SCRIPT = '''
on run argv
    set appPath to item 1 of argv
    tell application "System Events"
        tell process "System Settings"
            set frontmost to true
            repeat 40 times
                if exists window "Open" then
                    if exists button "Open" of window "Open" then exit repeat
                end if
                delay 0.1
            end repeat
            if not (exists button "Open" of window "Open") then
                log (get name of every window)
                error "Native application file picker is unavailable"
            end if
            if not (exists button "Cancel" of window "Open") then error "File picker identity is incomplete"
            keystroke "g" using {command down, shift down}
            repeat 30 times
                if exists sheet 1 of window "Open" then exit repeat
                delay 0.1
            end repeat
            set pathSheet to sheet 1 of window "Open"
            set pathNodes to entire contents of pathSheet
            if (count pathNodes) > 32 then error "Path entry exceeds observation limit"
            set pathFields to {}
            repeat with node in pathNodes
                if role of node is "AXTextField" and subrole of node is not "AXSecureTextField" then
                    set end of pathFields to contents of node
                end if
            end repeat
            if (count pathFields) is not 1 then error "No unique file picker path field"
            set value of item 1 of pathFields to appPath
            if value of item 1 of pathFields is not appPath then error "Owned app path was not accepted"
            key code 36
            repeat 30 times
                if not (exists sheet 1 of window "Open") then exit repeat
                delay 0.1
            end repeat
            if exists sheet 1 of window "Open" then error "File picker path entry did not retire"
            if not enabled of button "Open" of window "Open" then error "Owned app cannot be selected"
            perform action "AXPress" of button "Open" of window "Open"
            repeat 30 times
                if not (exists window "Open") then return "application_selected"
                delay 0.1
            end repeat
            error "Application file picker did not retire"
        end tell
    end tell
end run
'''


def select_application(app, report):
    """Pass a validated native bundle path as data, never interpolated script."""
    app = Path(app).resolve(strict=True)
    if app.name != "Hammerspoon.app" or not (app / "Contents/MacOS/Hammerspoon").is_file():
        raise ValueError("Missing owned Hammerspoon application bundle")
    state = report.setdefault("hammerspoon_accessibility_picker", {})
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", SCRIPT, str(app)],
                                capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired as error:
        state.update(timed_out=True, stdout=error.stdout, stderr=error.stderr)
        for key in ("stdout", "stderr"):
            if isinstance(state[key], bytes):
                state[key] = state[key].decode("utf-8", errors="replace")
        raise
    state.update(exit=result.returncode, stdout=result.stdout, stderr=result.stderr)
    if result.returncode != 0 or result.stdout.strip() != "application_selected":
        raise RuntimeError("Owned application selection was not confirmed")
