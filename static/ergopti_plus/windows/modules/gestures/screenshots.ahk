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

; Region capture starts Snipping Tool on a gesture/hotkey thread.  Never wait for
; either the user's selection or PowerShell there: both can take seconds and would
; stall every keyboard hook in the process.  The epoch makes delayed timer callbacks
; harmless when the user starts a second capture before the first one completes.
global _GestureRegionCapture := false
global _GestureRegionCaptureEpoch := 0
global GESTURE_REGION_CAPTURE_POLL_MS := 100
global GESTURE_REGION_CAPTURE_TIMEOUT_MS := 30000
global GESTURE_REGION_CAPTURE_SAVE_TIMEOUT_MS := 5000

; Win32 clipboard formats accepted as a Snipping Tool image. ClipWait(..., 2)
; only proves that *some* producer wrote data: plain text from a user copy is
; not a completed screenshot and must never claim the capture transaction.
global GESTURE_CLIPBOARD_CF_BITMAP := 2
global GESTURE_CLIPBOARD_CF_DIB := 8
global GESTURE_CLIPBOARD_CF_DIBV5 := 17

GestureClipboardSequence() {
    try return DllCall("GetClipboardSequenceNumber", "UInt")
    return 0
}

GestureClipboardHasImage() {
    global GESTURE_CLIPBOARD_CF_BITMAP, GESTURE_CLIPBOARD_CF_DIB, GESTURE_CLIPBOARD_CF_DIBV5
    try return DllCall("IsClipboardFormatAvailable", "UInt", GESTURE_CLIPBOARD_CF_BITMAP)
        || DllCall("IsClipboardFormatAvailable", "UInt", GESTURE_CLIPBOARD_CF_DIB)
        || DllCall("IsClipboardFormatAvailable", "UInt", GESTURE_CLIPBOARD_CF_DIBV5)
    return false
}

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
    global _GestureRegionCapture, _GestureRegionCaptureEpoch
    if A_IsSuspended
        return
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

    ; A new request supersedes the previous pending selection.  Restore its
    ; snapshot before publishing the new transaction, otherwise a cancelled first
    ; selection can leave the user's clipboard blank until its 30-second timeout.
    if (_GestureRegionCapture is Map)
        GestureRegionCaptureFinish(_GestureRegionCapture["epoch"], "superseded")

    Epoch := ++_GestureRegionCaptureEpoch
    try {
        OldClip := ClipboardAll()
        A_Clipboard := ""
        SendEvent("#+s")
        _GestureRegionCapture := Map(
            "epoch", Epoch,
            "path", Path,
            "original_clipboard", OldClip,
			"clipboard_sequence", GestureClipboardSequence(),
            "selection_deadline", A_TickCount + GESTURE_REGION_CAPTURE_TIMEOUT_MS,
            "save_deadline", 0,
            "save_started", false)
        SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
    } catch as e {
        ; ClipboardAll() and SendEvent can both fail in constrained desktops.  Do
        ; not leave a partially cleared clipboard behind when they do.
        try A_Clipboard := OldClip
        LoggerError("gestures", "Region screenshot could not start: {1}.", e.Message)
    }
}

; Poll outside the hook thread.  ClipWait with a 1-ms bound is only a snapshot
; probe; the 100-ms timer is what waits for the interactive selection.
GestureRegionCapturePoll(Epoch) {
    global _GestureRegionCapture
    if !(_GestureRegionCapture is Map) || (_GestureRegionCapture["epoch"] != Epoch)
        return
    if A_IsSuspended {
        GestureRegionCaptureFinish(Epoch, "suspended")
        return
    }

    State := _GestureRegionCapture
    if !State["save_started"] {
        if (A_TickCount >= State["selection_deadline"]) {
            LoggerWarn("gestures", "Region screenshot: no image captured (timeout or cancel).")
            GestureRegionCaptureFinish(Epoch, "selection timeout")
            return
        }
        if !ClipWait(0.001, 2) || !GestureClipboardHasImage() {
            SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
            return
        }
		; We now own exactly the image sequence produced by Snipping Tool. A later
		; user copy increments the sequence and prevents cleanup from restoring an
		; obsolete snapshot over that newer clipboard content.
		State["clipboard_sequence"] := GestureClipboardSequence()

        EscapedPath := StrReplace(State["path"], "'", "''")
        PSScript :=
            "Add-Type -AssemblyName System.Windows.Forms;" .
            "Add-Type -AssemblyName System.Drawing;" .
            "$img = [System.Windows.Forms.Clipboard]::GetImage();" .
            "if ($img) { $img.Save('" . EscapedPath . "', [System.Drawing.Imaging.ImageFormat]::Png) }"
        try {
            Run('powershell.exe -NoProfile -Sta -WindowStyle Hidden -Command "' . PSScript . '"', , "Hide")
            State["save_started"] := true
            State["save_deadline"] := A_TickCount + GESTURE_REGION_CAPTURE_SAVE_TIMEOUT_MS
            _GestureRegionCapture := State
            SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
        } catch as e {
            LoggerError("gestures", "Region screenshot save could not start: {1}.", e.Message)
            GestureRegionCaptureFinish(Epoch, "save launch failure")
        }
        return
    }

    if FileExist(State["path"]) {
        LoggerSuccess("gestures", "Region screenshot saved: '{1}'.", State["path"])
        TrayTip(t("notify.screenshot_saved"), State["path"], "Iconi Mute")
        GestureRegionCaptureFinish(Epoch, "saved")
    } else if (A_TickCount >= State["save_deadline"]) {
        LoggerWarn("gestures", "Region screenshot: clipboard image was not saved.")
        GestureRegionCaptureFinish(Epoch, "save timeout")
    } else {
        SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
    }
}

; Only the current transaction may restore the clipboard.  An old timer must
; never overwrite a newer user clipboard change or capture request.
GestureRegionCaptureFinish(Epoch, Reason) {
    global _GestureRegionCapture
    if !(_GestureRegionCapture is Map) || (_GestureRegionCapture["epoch"] != Epoch)
        return
    State := _GestureRegionCapture
    _GestureRegionCapture := false
	OwnedSequence := State.Has("clipboard_sequence") ? State["clipboard_sequence"] : 0
	if (OwnedSequence != 0 && GestureClipboardSequence() = OwnedSequence) {
		try A_Clipboard := State["original_clipboard"]
		catch as e
			LoggerError("gestures", "Region screenshot clipboard restore failed ({1}): {2}.", Reason, e.Message)
	} else {
		try LoggerDebug("gestures", "Region screenshot leaves newer clipboard content untouched ({1}).", Reason)
	}
}
