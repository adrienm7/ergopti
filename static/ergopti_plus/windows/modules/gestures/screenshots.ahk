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
global _GestureDirectCaptures := Map()
global _GestureDirectCaptureEpoch := 0
global GESTURE_REGION_CAPTURE_POLL_MS := 100
global GESTURE_REGION_CAPTURE_TIMEOUT_MS := 30000
global GESTURE_REGION_CAPTURE_SAVE_TIMEOUT_MS := 5000
global GESTURE_DIRECT_CAPTURE_TIMEOUT_MS := 5000

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
; Starts a capture worker and reports completion through OnComplete(Ok, Reason).
; A successful Run only proves that PowerShell started; callers must never report
; a saved/copied screenshot before the worker exits and its intended postcondition
; (file exists / new image clipboard sequence) is observed.
GestureCaptureRegion(X, Y, W, H, Mode, Path := "", OnComplete := "") {
	global _GestureDirectCaptures, _GestureDirectCaptureEpoch, GESTURE_DIRECT_CAPTURE_TIMEOUT_MS
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
    ClipboardSequence := (Mode == "clipboard") ? CB_GetSequenceNumber() : 0
    try {
        ; Run async (NOT RunWait): the keyboard hook thread must return immediately.
        Run('powershell.exe ' . PSArgs, , "Hide", &Pid)
        if !Pid
            throw Error("PowerShell did not return a process id")
		Epoch := ++_GestureDirectCaptureEpoch
		_GestureDirectCaptures[Epoch] := Map(
			"pid", Pid,
			"mode", Mode,
			"path", Path,
			"clipboard_sequence", ClipboardSequence,
			"deadline", A_TickCount + GESTURE_DIRECT_CAPTURE_TIMEOUT_MS,
			"callback", OnComplete)
		SetTimer(GestureDirectCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
		return true
    } catch as e {
        LoggerError("gestures", "Screenshot failed: {1}.", e.Message)
		if IsObject(OnComplete) {
			try OnComplete.Call(false, e.Message)
			catch as CallbackError
				LoggerError("gestures", "Screenshot launch-failure callback failed: {1}.", CallbackError.Message)
		}
        return False
    }
}

GestureDirectCapturePoll(Epoch) {
	global _GestureDirectCaptures
	if !_GestureDirectCaptures.Has(Epoch)
		return
	State := _GestureDirectCaptures[Epoch]
	if A_IsSuspended {
		GestureDirectCaptureFinish(Epoch, false, "driver suspended")
		return
	}
	if (ProcessExist(State["pid"]) and A_TickCount < State["deadline"]) {
		SetTimer(GestureDirectCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
		return
	}
	if (State["mode"] == "save")
		Ok := FileExist(State["path"]) != ""
	else
		Ok := (CB_GetSequenceNumber() != State["clipboard_sequence"] and CB_HasImage())
	GestureDirectCaptureFinish(Epoch, Ok, Ok ? "" : "worker exited without the requested screenshot output")
}

GestureDirectCaptureFinish(Epoch, Ok, Reason := "") {
	global _GestureDirectCaptures
	if !_GestureDirectCaptures.Has(Epoch)
		return
	State := _GestureDirectCaptures[Epoch]
	_GestureDirectCaptures.Delete(Epoch)
	Callback := State["callback"]
	if IsObject(Callback) {
		try Callback.Call(Ok, Reason)
		catch as e
			LoggerError("gestures", "Screenshot completion callback failed: {1}.", e.Message)
	}
}

GestureScreenshotComplete(Kind, Mode, Path, Ok, Reason := "") {
	if !Ok {
		LoggerError("gestures", "{1} screenshot failed: {2}.", Kind, Reason)
		return
	}
	if (Mode == "save") {
		LoggerSuccess("gestures", "{1} screenshot saved: '{2}'.", Kind, Path)
		TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
	} else {
		LoggerSuccess("gestures", "{1} screenshot copied to clipboard.", Kind)
		TrayTip(t("notify.screenshot_copied"), t("notify.clipboard"), "Iconi Mute")
	}
}

; Captures the active window (client + non-client area).
;   Mode = "save"      → write a PNG to disk and TrayTip the path.
;   Mode = "clipboard" → copy the bitmap to the Windows clipboard.
GestureScreenshotWindow(Mode) {
    ; WMExists is an EXISTENCE PREDICATE — it returns true/false, never a handle.
    ; Assigning it here made every capture build the spec "ahk_id 1", so WinGetPos
    ; threw, the catch below logged "WinGetPos failed" and returned: the window
    ; screenshot gesture could never once produce an image. WMGetFocused is the
    ; adapter that actually yields the active window's handle.
    HWnd := WMGetFocused()["hwnd"]
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
		GestureCaptureRegion(X, Y, W, H, "save", Path, GestureScreenshotComplete.Bind("Window", "save", Path))
    } else {
        LoggerStart("gestures", "Capturing window to clipboard…")
		GestureCaptureRegion(X, Y, W, H, "clipboard", "", GestureScreenshotComplete.Bind("Window", "clipboard", ""))
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
		GestureCaptureRegion(X, Y, W, H, "save", Path, GestureScreenshotComplete.Bind("Fullscreen", "save", Path))
    } else {
        LoggerStart("gestures", "Capturing fullscreen to clipboard…")
		GestureCaptureRegion(X, Y, W, H, "clipboard", "", GestureScreenshotComplete.Bind("Fullscreen", "clipboard", ""))
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
			"clipboard_sequence", CB_GetSequenceNumber(),
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
		if !ClipWait(0.001, 2) || !CB_HasImage() {
            SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
            return
        }
		; We now own exactly the image sequence produced by Snipping Tool. A later
		; user copy increments the sequence and prevents cleanup from restoring an
		; obsolete snapshot over that newer clipboard content.
		State["clipboard_sequence"] := CB_GetSequenceNumber()

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
	if (OwnedSequence != 0 && CB_GetSequenceNumber() = OwnedSequence) {
		try A_Clipboard := State["original_clipboard"]
		catch as e
			LoggerError("gestures", "Region screenshot clipboard restore failed ({1}): {2}.", Reason, e.Message)
	} else {
		try LoggerDebug("gestures", "Region screenshot leaves newer clipboard content untouched ({1}).", Reason)
	}
}
