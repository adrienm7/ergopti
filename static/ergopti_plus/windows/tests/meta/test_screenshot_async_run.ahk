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

_SAR_ReadSource() {
	return FileRead(A_ScriptDir . "\..\modules\shortcuts\win.ahk", "UTF-8")
}


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
	block := _SAR_FindScreenshotBlock(_SAR_ReadSource())
	Assert(block != "",
		"shortcuts/win.ahk: SC029 screenshot hotkey block must be present")
	Assert(InStr(block, "RunWait") = 0,
		"shortcuts/win.ahk: SC029 must not use RunWait — it blocks the keyboard hook thread during screen capture")
}
Test("Screenshot hotkey: RunWait not used in SC029 block (screenshot-async-run)", _SAR_NoRunWait)


_SAR_AsyncRunPresent() {
	block := _SAR_FindScreenshotBlock(_SAR_ReadSource())
	; Run( with an opening paren distinguishes the Run function from RunWait.
	Assert(InStr(block, "Run(") > 0,
		"shortcuts/win.ahk: SC029 must call Run() (async) instead of RunWait for the PowerShell capture process")
}
Test("Screenshot hotkey: async Run() used in SC029 block (screenshot-async-run)", _SAR_AsyncRunPresent)
