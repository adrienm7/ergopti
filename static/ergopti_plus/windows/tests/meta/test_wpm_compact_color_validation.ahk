; tests/meta/test_wpm_compact_color_validation.ahk

; ==============================================================================
; MODULE: WPM Compact-Mode Color Validation Meta Test
; DESCRIPTION:
; Regression guard for MEDIUM-01: a malformed TOML color killed the widget.
;
; WPMWidget_CategoryBgColor returned the raw TOML color string unvalidated. A
; malformed value (typo, missing digit, stray char) flowed into Gui.BackColor /
; WinSetTransparent in the compact-mode tick, which throws. The compact-mode
; catch nulled the GUI handles but never rebuilt them, so the widget went dark
; permanently — one bad color in a user TOML disabled the WPM widget for good.
;
; The fix (1) validates the color against ^[0-9A-Fa-f]{6}$ and falls through to
; the fallback when it does not match, and (2) makes the compact-mode catch
; self-heal by calling WPMWidget_BuildCompact() to rebuild the nulled widget.
; This test asserts both halves are present so a regression fails CI.
;
; SCOPE: source introspection of ui/wpm_widget.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_WCCV_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertions ======================
; ==================================================
; ==================================================

_WCCV_ColorIsValidated() {
	Src := _WCCV_ReadSource("ui/wpm/init.ahk")
	Body := _DriverFuncBody("WPMWidget_CategoryBgColor")
	Assert(Body != "", "WPMWidget_CategoryBgColor( must exist in ui/wpm_widget.ahk")
	Assert(InStr(Body, "[0-9A-Fa-f]{6}") > 0,
		"WPMWidget_CategoryBgColor must validate the color against a 6-digit hex regex before returning it (MEDIUM-01)")
}

_WCCV_TickCatchSelfHeals() {
	Src := _WCCV_ReadSource("ui/wpm/init.ahk")
	Body := _DriverFuncBody("WPMWidget_Tick")
	Assert(Body != "", "WPMWidget_Tick( must exist in ui/wpm_widget.ahk")
	Assert(InStr(Body, "WPMWidget_BuildCompact") > 0,
		"WPMWidget_Tick compact-mode catch must rebuild the widget via WPMWidget_BuildCompact so a bad-color throw does not disable it permanently (MEDIUM-01)")
}

Test("meta wpm-compact-color: WPMWidget_CategoryBgColor validates hex (MEDIUM-01)", _WCCV_ColorIsValidated)
Test("meta wpm-compact-color: WPMWidget_Tick compact catch self-heals via BuildCompact (MEDIUM-01)", _WCCV_TickCatchSelfHeals)
