; tests/meta/modules/gestures/test_gesture_screenshot_no_tempfile.ahk

; ==============================================================================
; MODULE: Gesture Screenshot No Temp-File Meta Test
; DESCRIPTION:
; Static source guard for the "gesture-screenshot-tempfile-race" audit finding
; in modules/gestures.ahk.
;
; ROOT CAUSE ENCODED:
; GestureScreenshotInstant wrote the PowerShell capture script to a fixed
; temporary path (A_Temp . "\hs_screenshot.ps1") on every call. If the gesture
; was triggered twice in rapid succession (< 200 ms), the second call would
; overwrite the shared file while the first powershell.exe process was still
; reading it — producing a crash or a corrupted/blank screenshot for the first
; capture. There was also no cleanup path for the temp file.
;
; The fix captures in process (GDI and GDI+) and gives every worker a unique
; bitmap stage. The stage is output, never executable source, and one
; generation owns its cleanup.
;
; This test verifies:
;   1. GestureScreenshotInstant does NOT reference "hs_screenshot.ps1".
;   2. GestureScreenshotInstant does NOT call FileAppend to write the PS code.
;   3. The shared capture runs in process and never launches a script host.
; ==============================================================================

#Requires AutoHotkey v2.0




; =============================================================
; =============================================================
; ======= 1/ No temp .ps1 file written by GestureScreenshot ===
; =============================================================
; =============================================================

_GSNF_NoTempFile() {
	Body := _DriverFuncBody("GestureScreenshotInstant")
	Assert(Body != "", "GestureScreenshotInstant must exist in modules/gestures.ahk")

	Assert(!InStr(Body, "hs_screenshot.ps1"),
		"GestureScreenshotInstant must NOT write to a fixed .ps1 temp file (gesture-screenshot-tempfile-race)")

	Assert(!RegExMatch(Body, "FileAppend\([^)]*\.ps1[^)]*\)"),
		"GestureScreenshotInstant must NOT FileAppend any .ps1 script content (gesture-screenshot-tempfile-race)")

	Assert(!InStr(Body, "TmpScript"),
		"GestureScreenshotInstant must NOT use a TmpScript variable (gesture-screenshot-tempfile-race)")
}
Test("gestures: GestureScreenshotInstant does not write a shared temp .ps1 file (gesture-screenshot-tempfile-race)", _GSNF_NoTempFile)




; ======================================================
; ======================================================
; ======= 2/ The capture runs in process =================
; ======================================================
; ======================================================

_GSNF_InlineCommand() {
	; The instant capture no longer inlines PowerShell itself: it delegates to the
	; hardened shared path GestureCaptureRegion (F23), which additionally escapes the
	; save path and reports success only from the observed postcondition. The
	; no-temp-file invariant therefore now lives in that shared implementation — assert
	; it there, so it holds for EVERY capture path, not just the instant one.
	Body := _DriverFuncBody("GestureScreenshotInstant")
	Assert(Body != "", "GestureScreenshotInstant must exist in modules/gestures/actions.ahk")
	Assert(InStr(Body, "GestureCaptureRegion(") > 0,
		"GestureScreenshotInstant must delegate to the shared hardened capture path")

	Capture := _DriverFuncBody("GestureCaptureRegion")
	NativeCapture := _DriverFuncBody("_GestureScreenshotCaptureScreen")
	Assert(Capture != "" && NativeCapture != "",
		"GestureCaptureRegion and its in-process screen capture must exist")
	Assert(InStr(Capture, "_GestureScreenshotCaptureScreen.Bind(") > 0
		&& InStr(Capture, ".ps1") = 0 && InStr(NativeCapture, ".ps1") = 0,
		"the shared capture must run in process, never through a temp .ps1 (gesture-screenshot-tempfile-race)")

	; The worker registry owns start, termination, and completion. A raw Run here
	; would recreate the detached sibling fixed by AHK-13.
	Assert(InStr(Capture, "_GestureScreenshotCreateWorker") > 0,
		"the shared capture must register its worker with the common owner")
	Assert(InStr(Capture, "Run(") = 0,
		"the shared capture must not launch an unowned sibling process")
	Assert(InStr(Capture, "RunWait") = 0,
		"the shared capture must never RunWait — that would block the keyboard hook thread")
}
Test("gestures: the shared screenshot capture runs in process (gesture-screenshot-tempfile-race)", _GSNF_InlineCommand)
