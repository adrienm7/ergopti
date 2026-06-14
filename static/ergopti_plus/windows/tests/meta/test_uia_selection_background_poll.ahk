; tests/meta/test_uia_selection_background_poll.ahk

; ==============================================================================
; MODULE: UIA Selection Background Poll Meta Test
; DESCRIPTION:
; Static source guard for the uia-selection-blocks-keyboard-thread finding.
;
; UIA selection queries (COM round-trips) must not run on the synchronous
; keyboard hot-path (GetUIASelection called from _OnChar/WrapTextIfSelected).
; They must be moved to a background polling timer, with GetUIASelection()
; merely returning the cached value.
;
; The fix introduces _UIA_SelectionPollTick() and _UIA_SelectionCache.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_USBP_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_USBP_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	; Find the first closing brace at the start of a line (no indentation).
	if RegExMatch(Rest, "m)^\}", &Match)
		return SubStr(Rest, 1, Match.Pos)
	return Rest
}


; ===================================================
; ===================================================
; ======= 2/ Background poll assertion ==============
; ===================================================
; ===================================================

_USBP_SelectionIsPolledInBackground() {
	Src := _USBP_ReadSource("modules/layout.ahk")
	
	; 1. Verify background tick exists and does the heavy lifting.
	TickBody := _USBP_FuncBody(Src, "_UIA_SelectionPollTick() {")
	Assert(TickBody != "", "_UIA_SelectionPollTick must exist in modules/layout.ahk")
	Assert(InStr(TickBody, "UIA.GetFocusedElement()") > 0,
		"_UIA_SelectionPollTick must perform the UIA query (uia-selection-blocks-keyboard-thread)")
	Assert(InStr(TickBody, "_UIA_SelectionCache :=") > 0,
		"_UIA_SelectionPollTick must update the _UIA_SelectionCache")
	
	; 2. Verify GetUIASelection is now just a cache reader.
	GetterBody := _USBP_FuncBody(Src, "GetUIASelection() {")
	Assert(GetterBody != "", "GetUIASelection must exist in modules/layout.ahk")
	Assert(InStr(GetterBody, "return _UIA_SelectionCache") > 0,
		"GetUIASelection must return the cached value immediately (uia-selection-blocks-keyboard-thread)")
	Assert(InStr(GetterBody, "UIA.GetFocusedElement()") == 0,
		"GetUIASelection must NOT call UIA directly on the keyboard path (uia-selection-blocks-keyboard-thread)")

	; 3. Verify timer is armed.
	Assert(InStr(Src, "SetTimer(_UIA_SelectionPollTimer, 500)") > 0,
		"UIA selection poll timer must be armed with a periodic interval")
}
Test("layout: UIA selection is polled in background (uia-selection-blocks-keyboard-thread)", _USBP_SelectionIsPolledInBackground)
