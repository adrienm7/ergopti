; tests/meta/test_gesture_screenshot_no_tempfile.ahk

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
; The fix inlines the capture code as a PowerShell -Command argument, eliminating
; the shared temporary file entirely. Each Run() call is fully self-contained.
;
; This test verifies:
;   1. GestureScreenshotInstant does NOT reference "hs_screenshot.ps1".
;   2. GestureScreenshotInstant does NOT call FileAppend to write the PS code.
;   3. GestureScreenshotInstant uses -Command to inline the PS code.
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
; ======= 2/ Inline -Command pattern is used ============
; ======================================================
; ======================================================

_GSNF_InlineCommand() {
	Body := _DriverFuncBody("GestureScreenshotInstant")
	Assert(Body != "", "GestureScreenshotInstant must exist in modules/gestures.ahk")

	Assert(InStr(Body, "-Command") > 0,
		"GestureScreenshotInstant must inline PS code via -Command (gesture-screenshot-tempfile-race)")

	; Run (not RunWait) so successive calls do not block each other
	Assert(InStr(Body, "Run(") > 0,
		"GestureScreenshotInstant must use Run (not RunWait) to dispatch PS non-blocking")
}
Test("gestures: GestureScreenshotInstant inlines PowerShell via -Command (gesture-screenshot-tempfile-race)", _GSNF_InlineCommand)
