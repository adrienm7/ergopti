; tests/meta/test_tooltip_teardown_on_keyboard_thread.ahk

; ==============================================================================
; MODULE: LLM Bridge OnChar Deferred Teardown Meta Test
; DESCRIPTION:
; Static source guard for the tooltip-teardown-on-keyboard-thread finding.
;
; LLM_Bridge_OnChar runs inline on the PrefixWatcher InputHook thread. When a
; keystroke dismisses a shown prediction, the old code called
; LLM_Tooltip_Hide(true) synchronously -- tearing down a multi-window layered
; overlay (DeferWindowPos batch + Gui Destroy) on the very thread that must
; return promptly for the next physical key. Under DWM contention this can
; exceed Windows' LowLevelHooksTimeout and drop the in-flight or next key.
;
; The fix defers the teardown off the hook via SetTimer(..., -1), so the GDI/DWM
; work runs on a fresh thread after the hook returns. This test scans the
; LLM_Bridge_OnChar body and asserts the dismiss branch schedules a deferred
; hide rather than calling LLM_Tooltip_Hide synchronously in-line.
;
; Meta-static because modules/llm/llm_bridge.ahk registers top-level state and
; is not part of the headless run_all include graph.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_TtkbReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TtkbFuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Deferred-teardown assertion ===========
; ==================================================
; ==================================================

_TtkbOnCharDefersHide() {
	Src := _TtkbReadSource("modules/llm/llm_bridge.ahk")
	Seg := _TtkbFuncBody(Src, "LLM_Bridge_OnChar(ch) {")
	Assert(Seg != "", "LLM_Bridge_OnChar(ch) declaration must exist in llm_bridge.ahk")
	; The dismiss branch must hand the teardown to a fresh timer thread, not run
	; it inline on the InputHook thread.
	Assert(InStr(Seg, "SetTimer((*) => LLM_Tooltip_Hide(true), -1)") > 0,
		"LLM_Bridge_OnChar must defer the dismiss teardown via SetTimer(..., -1) so DWM/GDI window destruction does not run on the InputHook thread and risk a dropped keystroke")
}
Test("LLM: LLM_Bridge_OnChar defers tooltip teardown off the hook thread (tooltip-teardown-on-keyboard-thread)", _TtkbOnCharDefersHide)
