; modules/gestures/screenshots.ahk

; ==============================================================================
; MODULE: Gesture Screenshot Capture (AHK)
; DESCRIPTION:
; GdiPlus-based screenshot helpers invoked by gestures: resolve the screenshots
; directory, build timestamped paths, and capture a region, the active window or
; the full screen to a file or the clipboard. Extracted from modules/gestures.ahk
; so the screenshot capture logic lives on its own, away from the gesture catalog
; and the window-cycle tracker.
;
; FEATURES & RATIONALE:
; 1. Single home for capture - directory/path resolution and the region/window/
;    fullscreen capture paths sit together, so the screenshot behaviour is read
;    and changed in one place.
; 2. Clipboard-safe - the capture paths back up and restore the clipboard in a
;    finally block, so a gesture screenshot never clobbers the user's clipboard.
; ==============================================================================

#Requires AutoHotkey v2.0

; Async region-save tuning: the save-mode PNG write runs in a PowerShell child so the
; hook thread is never blocked; the clipboard (holding the snip) is restored only after
; that child exits, polled at this cadence with a safety cap.
global GESTURE_REGION_SAVE_POLL_MS := 100   ; async PNG-save child poll cadence (ms)
global GESTURE_REGION_SAVE_MAX_POLLS := 80  ; ~8 s safety cap before forcing the clipboard restore

; Returns the absolute path to the screenshots directory, creating it if missing.
; Mirrors Hammerspoon's convention: %USERPROFILE%\Pictures\screenshots\
GestureScreenshotsDir() {
    Dir := A_MyDocuments . "\..\Pictures\screenshots"
    ; Resolve "..\" — easier to read for the user
    Dir := EnvGet("USERPROFILE") . "\Pictures\screenshots"
    if !DirExist(Dir) {
        try DirCreate(Dir)
    }
    return Dir
}

; Returns a timestamped screenshot filename, e.g. screenshot_2026_05_06_21_15_42.png
GestureScreenshotPath() {
    return GestureScreenshotsDir() . "\screenshot_" . FormatTime(, "yyyy_MM_dd_HH'h'_mm'min'_ss's'") . ".png"
}

; Captures a region using PowerShell + System.Drawing and routes it to the
; requested destination. Coordinates are in screen pixels.
;   Mode = "save"      → write a PNG to Path (must be a valid file path).
;   Mode = "clipboard" → copy the bitmap to the Windows clipboard via
;                        System.Windows.Forms.Clipboard. PowerShell is
;                        launched with -STA because Clipboard.SetImage
;                        requires the calling thread to be in single-
;                        threaded apartment state.
; Returns True on success, False otherwise.
GestureCaptureRegion(X, Y, W, H, Mode, Path := "") {
    if (Mode == "save") {
        EscapedPath := StrReplace(Path, "'", "''")
        PSScript :=
            "Add-Type -AssemblyName System.Drawing;" .
            "$bmp = New-Object System.Drawing.Bitmap " . W . "," . H . ";" .
            "$g = [System.Drawing.Graphics]::FromImage($bmp);" .
            "$g.CopyFromScreen(" . X . "," . Y . ",0,0,(New-Object System.Drawing.Size " . W . "," . H . "));" .
            "$bmp.Save('" . EscapedPath . "', [System.Drawing.Imaging.ImageFormat]::Png);" .
            "$g.Dispose(); $bmp.Dispose();"
        PSArgs := '-NoProfile -WindowStyle Hidden -Command "' . PSScript . '"'
    } else {
        PSScript :=
            "Add-Type -AssemblyName System.Drawing;" .
            "Add-Type -AssemblyName System.Windows.Forms;" .
            "$bmp = New-Object System.Drawing.Bitmap " . W . "," . H . ";" .
            "$g = [System.Drawing.Graphics]::FromImage($bmp);" .
            "$g.CopyFromScreen(" . X . "," . Y . ",0,0,(New-Object System.Drawing.Size " . W . "," . H . "));" .
            "[System.Windows.Forms.Clipboard]::SetImage($bmp);" .
            "$g.Dispose(); $bmp.Dispose();"
        ; -STA is required for Clipboard interop
        PSArgs := '-NoProfile -Sta -WindowStyle Hidden -Command "' . PSScript . '"'
    }
    try {
        ; Run async (NOT RunWait): the keyboard hook thread must return immediately — a
        ; RunWait here froze every keystroke for the whole capture (~300-1500 ms cold) on
        ; each window/fullscreen screenshot gesture (gesture-capture-async-run). The
        ; PowerShell capture runs in its own process; fire-and-forget like the SC029 and
        ; GestureScreenshotInstant siblings, so the save-mode success TrayTip is optimistic.
        Run('powershell.exe ' . PSArgs, , "Hide")
        return True
    } catch as e {
        LoggerError("gestures", "Screenshot failed: {1}.", e.Message)
        return False
    }
}

; Captures the active window (client + non-client area).
;   Mode = "save"      → write a PNG to disk and TrayTip the path.
;   Mode = "clipboard" → copy the bitmap to the Windows clipboard.
GestureScreenshotWindow(Mode) {
    HWnd := WMExists("A")
    if (!HWnd) {
        LoggerWarn("gestures", "screenshot_window: no active window.")
        return
    }
    try {
        WinGetPos(&X, &Y, &W, &H, "ahk_id " . HWnd)
    } catch {
        LoggerWarn("gestures", "screenshot_window: WinGetPos failed.")
        return
    }
    if (Mode == "save") {
        Path := GestureScreenshotPath()
        LoggerStart("gestures", "Capturing window to '{1}'…", Path)
        if GestureCaptureRegion(X, Y, W, H, "save", Path) {
            LoggerSuccess("gestures", "Window screenshot saved: '{1}'.", Path)
            TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
        }
    } else {
        LoggerStart("gestures", "Capturing window to clipboard…")
        if GestureCaptureRegion(X, Y, W, H, "clipboard") {
            LoggerSuccess("gestures", "Window screenshot copied to clipboard.")
            TrayTip(t("notify.screenshot_copied"), t("notify.clipboard"), "Iconi Mute")
        }
    }
}

; Captures the full virtual screen (all monitors) to disk or clipboard.
GestureScreenshotFullscreen(Mode) {
    X := SysGet(76)  ; SM_XVIRTUALSCREEN
    Y := SysGet(77)  ; SM_YVIRTUALSCREEN
    W := SysGet(78)  ; SM_CXVIRTUALSCREEN
    H := SysGet(79)  ; SM_CYVIRTUALSCREEN
    if (Mode == "save") {
        Path := GestureScreenshotPath()
        LoggerStart("gestures", "Capturing fullscreen to '{1}'…", Path)
        if GestureCaptureRegion(X, Y, W, H, "save", Path) {
            LoggerSuccess("gestures", "Fullscreen screenshot saved: '{1}'.", Path)
            TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
        }
    } else {
        LoggerStart("gestures", "Capturing fullscreen to clipboard…")
        if GestureCaptureRegion(X, Y, W, H, "clipboard") {
            LoggerSuccess("gestures", "Fullscreen screenshot copied to clipboard.")
            TrayTip(t("notify.screenshot_copied"), t("notify.clipboard"), "Iconi Mute")
        }
    }
}

; Triggers Windows' built-in Snip & Sketch region selector via Win+Shift+S.
; Snip & Sketch always copies the result to the clipboard — for the "save"
; mode we additionally watch the clipboard for the resulting image and dump
; it to a timestamped PNG on disk.
GestureScreenshotRegion(Mode) {
    if (Mode == "clipboard") {
        ; Snip & Sketch already places the image on the clipboard — nothing
        ; further to do. Fire-and-forget so the user can keep typing.
        LoggerStart("gestures", "Region screenshot to clipboard — opening Snip & Sketch…")
        TextPressKey("s", ["Shift", "Win"])
        LoggerSuccess("gestures", "Snip & Sketch invoked (clipboard mode).")
        return
    }
    Path := GestureScreenshotPath()
    LoggerStart("gestures", "Region screenshot to disk — opening Snip & Sketch…")
    OldClip := ClipboardAll()
    A_Clipboard := ""
    SendEvent("#+s")
    ; Wait up to 30 s for the user to finish their selection (a deliberate user-wait).
    if !ClipWait(30, 2) {
        LoggerWarn("gestures", "Region screenshot: no image captured (timeout or cancel).")
        A_Clipboard := OldClip
        return
    }
    ; Save the clipboard PNG to disk via PowerShell. Run async (NOT RunWait) so the hook
    ; thread is not blocked on the PNG write. The snip image must stay on the clipboard
    ; until PowerShell has read it, so OldClip is restored only AFTER the child exits —
    ; deferred to a bounded poll, never inline here (gesture-capture-async-run).
    EscapedPath := StrReplace(Path, "'", "''")
    PSScript :=
        "Add-Type -AssemblyName System.Windows.Forms;" .
        "Add-Type -AssemblyName System.Drawing;" .
        "$img = [System.Windows.Forms.Clipboard]::GetImage();" .
        "if ($img) { $img.Save('" . EscapedPath . "', [System.Drawing.Imaging.ImageFormat]::Png) }"
    Pid := 0
    try {
        Run('powershell.exe -NoProfile -Sta -WindowStyle Hidden -Command "' . PSScript . '"', , "Hide", &Pid)
    } catch as e {
        LoggerError("gestures", "Region screenshot save failed: {1}.", e.Message)
        A_Clipboard := OldClip
        return
    }
    SetTimer(_GestureRegionSavePoll.Bind(Pid, Path, OldClip, GESTURE_REGION_SAVE_MAX_POLLS), -GESTURE_REGION_SAVE_POLL_MS)
}

; Polls the async region-save PowerShell child to completion, then restores the
; clipboard (the snip image has been read by then) and notifies the user. A poll-count
; safety cap still restores the clipboard if the child ever hangs.
_GestureRegionSavePoll(Pid, Path, OldClip, PollsLeft) {
    if (ProcessExist(Pid) and PollsLeft > 0) {
        SetTimer(_GestureRegionSavePoll.Bind(Pid, Path, OldClip, PollsLeft - 1), -GESTURE_REGION_SAVE_POLL_MS)
        return
    }
    A_Clipboard := OldClip
    if FileExist(Path) {
        LoggerSuccess("gestures", "Region screenshot saved: '{1}'.", Path)
        TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
    } else {
        LoggerWarn("gestures", "Region screenshot: clipboard image was not saved.")
    }
}
