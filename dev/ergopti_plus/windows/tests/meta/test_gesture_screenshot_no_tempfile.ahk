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
; The fix passes capture code as a PowerShell -Command argument and gives every
; worker a unique bitmap stage. The stage is output, never executable source,
; and one generation owns its cleanup.
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
	ArgsBuilder := _DriverFuncBody("_GestureScreenshotPowerShellArgs")
	Assert(Capture != "" && ArgsBuilder != "",
		"GestureCaptureRegion and its PowerShell argument builder must exist")
	Assert(InStr(ArgsBuilder, 'Args.Push("-WindowStyle", "Hidden", "-Command", Script)') > 0,
		"the shared capture must pass PS code via -Command, never a temp .ps1 (gesture-screenshot-tempfile-race)")

	; ShellRunner owns process launch, termination, and completion. A raw Run here
	; would recreate the detached sibling fixed by AHK-13.
	Assert(InStr(Capture, "_GestureScreenshotCreateWorker") > 0,
		"the shared capture must register its process with the common worker owner")
	Assert(InStr(Capture, "Run(") = 0,
		"the shared capture must not launch an unowned PowerShell sibling")
	Assert(InStr(Capture, "RunWait") = 0,
		"the shared capture must never RunWait — that would block the keyboard hook thread")
}
Test("gestures: GestureScreenshotInstant inlines PowerShell via -Command (gesture-screenshot-tempfile-race)", _GSNF_InlineCommand)
