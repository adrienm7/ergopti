; tests/meta/test_screenshot_region_clipwait_clobber.ahk

; ==============================================================================
; MODULE: Screenshot Region Clipwait Clobber Meta Test
; DESCRIPTION:
; Static source guard for the "screenshot-region-clipwait-clobber" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSC_Check() {
	; Move-resilient: extract GestureScreenshotRegion()'s body by name via the
	; framework helper instead of a pinned modules/gestures.ahk read. Scoping to the
	; function (rather than the whole file) keeps the clipboard backup/restore
	; assertions tied to the region-screenshot path they actually guard.
	Src := _DriverFuncBody("GestureScreenshotRegion")
	Assert(Src != "", "GestureScreenshotRegion must exist in modules/gestures.ahk")
	Assert(InStr(Src, "OldClip := ClipboardAll()") > 0, "gestures.ahk must backup clipboard")
	Assert(InStr(Src, "finally {") > 0, "gestures.ahk must use finally block to restore clipboard")
	Assert(InStr(Src, "A_Clipboard := OldClip") > 0, "gestures.ahk must restore clipboard")
}

Test("Gestures: screenshot region preserves clipboard", _TSC_Check)
