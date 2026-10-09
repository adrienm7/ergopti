; tests/meta/test_gesture_screenshot_instant_completion.ahk

; ==============================================================================
; MODULE: Instant screenshot reports success only from the observed postcondition
; DESCRIPTION:
; GestureScreenshotInstant was the legacy pre-transaction capture path: it launched
; PowerShell fire-and-forget and TrayTip'd "screenshot saved at <path>" on the very
; next line — before the bitmap existed, or ever would. It also spliced the save path
; into a PowerShell single-quoted string with no ' -> '' escaping, so a USERPROFILE
; containing an apostrophe produced a syntax error, the hidden worker died, and the
; toast still claimed success. The hardened GestureCaptureRegion path already does the
; escaping, deadline polling, suspend fail-close and success-only-after-postcondition
; reporting, so the instant capture must route through it. (F23, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_GSIC_InstantRoutesThroughHardenedCapture() {
	Body := _DriverFuncBody("GestureScreenshotInstant")
	Assert(Body != "", "GestureScreenshotInstant must exist in modules/gestures/actions.ahk")

	Assert(InStr(Body, "GestureCaptureRegion(") > 0,
		"GestureScreenshotInstant must route through the hardened GestureCaptureRegion path")
	Assert(InStr(Body, "GestureScreenshotComplete") > 0,
		"success must be reported from the completion callback, never inline after the launch")

	; The inline fire-and-forget PowerShell capture must be gone entirely.
	Assert(InStr(Body, "CopyFromScreen") = 0,
		"the inline PowerShell capture block must be deleted — it duplicated the hardened path without escaping or polling")
	Assert(InStr(Body, "notify.screenshot_saved_path") = 0,
		"GestureScreenshotInstant must not announce a saved screenshot inline; only the completion callback may report success")
}
Test("gestures: instant screenshot reports success only from the observed postcondition",
	_GSIC_InstantRoutesThroughHardenedCapture)
