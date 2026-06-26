; tests/meta/test_screenshot_async_run.ahk

; ==============================================================================
; MODULE: Screenshot Async Run Meta-Test
; DESCRIPTION:
; Structural regression for the screenshot hotkey fix in modules/shortcuts/win.ahk.
;
; Before the fix the SC029 hotkey called RunWait() to invoke the PowerShell
; screen capture script. RunWait blocks the calling AHK thread until the child
; process exits. Because the hotkey fires on the keyboard hook thread, this
; blocked ALL keyboard processing (input drops, modifier key hangs) for the
; entire duration of the PowerShell process — typically 300-800 ms.
;
; The fix replaces RunWait with Run (async) so the hook thread returns
; immediately. The TrayTip notification fires optimistically before the file
; appears on disk; the race is acceptable because the notification is cosmetic.
;
; This test inspects shortcuts/win.ahk source and asserts:
;   1. RunWait is NOT used in the screenshot block.
;   2. A Run( call IS present in the screenshot block.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================================
; ==========================================================
; ======= 1/ Source-inspection helpers =====================
; ==========================================================
; ==========================================================

; Move-resilient: scan the shortcuts module dir via the framework helper instead
; of a pinned win.ahk path. SC029:: is unique within modules/shortcuts (only the
; screenshot hotkey lives here; layout.ahk's SC029:: is in modules/, out of scope),
; so the first-match extraction below still targets the screenshot block. The
; ~600-char window stays inside win.ahk (the block sits well before EOF), so it
; never spills into a neighbouring file's content.
_SAR_FindScreenshotBlock(src) {
	pos := InStr(src, "SC029::")
	if (!pos)
		return ""
	; Capture the block up to the closing #HotIf — roughly 500 chars.
	return SubStr(src, pos, 600)
}




; ==========================================================
; ==========================================================
; ======= 2/ Assertions ====================================
; ==========================================================
; ==========================================================

_SAR_NoRunWait() {
	block := _SAR_FindScreenshotBlock(_DriverDirConcat("modules/shortcuts"))
	Assert(block != "",
		"shortcuts/win.ahk: SC029 screenshot hotkey block must be present")
	Assert(InStr(block, "RunWait") = 0,
		"shortcuts/win.ahk: SC029 must not use RunWait — it blocks the keyboard hook thread during screen capture")
}
Test("Screenshot hotkey: RunWait not used in SC029 block (screenshot-async-run)", _SAR_NoRunWait)


_SAR_AsyncRunPresent() {
	block := _SAR_FindScreenshotBlock(_DriverDirConcat("modules/shortcuts"))
	; Run( with an opening paren distinguishes the Run function from RunWait.
	Assert(InStr(block, "Run(") > 0,
		"shortcuts/win.ahk: SC029 must call Run() (async) instead of RunWait for the PowerShell capture process")
}
Test("Screenshot hotkey: async Run() used in SC029 block (screenshot-async-run)", _SAR_AsyncRunPresent)


; F-H07: the gesture screenshot capture paths (GestureCaptureRegion for window/
; fullscreen, GestureScreenshotRegion's post-ClipWait PNG save) used RunWait, blocking
; the keyboard hook thread for the whole PowerShell capture on every screenshot gesture.
; They were missed by the SC029 fix above; both must now use async Run.
_SAR_GestureCaptureNoRunWait() {
	Body := _DriverFuncBody("GestureCaptureRegion")
	Assert(Body != "", "GestureCaptureRegion(X,Y,W,H,Mode,Path) must exist")
	Assert(InStr(Body, "RunWait") = 0,
		"GestureCaptureRegion must not use RunWait — it blocks the keyboard hook thread on every window/fullscreen screenshot gesture (gesture-capture-async-run)")
	Assert(InStr(Body, "Run(") > 0,
		"GestureCaptureRegion must launch the capture via async Run()")
}
Test("Gesture screenshot: GestureCaptureRegion uses async Run, not RunWait (gesture-capture-async-run)", _SAR_GestureCaptureNoRunWait)

_SAR_GestureRegionNoRunWait() {
	Body := _DriverFuncBody("GestureScreenshotRegion")
	Assert(Body != "", "GestureScreenshotRegion(Mode) must exist")
	Assert(InStr(Body, "RunWait") = 0,
		"GestureScreenshotRegion must not use RunWait for the post-snip PNG save — defer it via async Run + a bounded clipboard-restore poll (gesture-capture-async-run)")
	Assert(InStr(Body, "Run(") > 0,
		"GestureScreenshotRegion save path must launch PowerShell via async Run()")
}
Test("Gesture screenshot: GestureScreenshotRegion save uses async Run, not RunWait (gesture-capture-async-run)", _SAR_GestureRegionNoRunWait)
