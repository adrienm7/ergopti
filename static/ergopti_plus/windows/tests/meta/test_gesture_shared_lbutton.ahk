; tests/meta/test_gesture_shared_lbutton.ahk

; ==============================================================================
; MODULE: Gesture Shared LButton Meta Test
; DESCRIPTION:
; Static source guard for the gesture-release-disables-shared-lbutton finding.
;
; In AHK v2, each unique KeyName can have at most one function registered per
; HotIf context. Calling Hotkey("~LButton", GestureReleaseRightClick, "On")
; inside GestureToggleRightClick REPLACES the HookDispatcher._hk_ldown handler
; that was registered at startup. When GestureReleaseRightClick later calls
; Hotkey("~LButton", GestureReleaseRightClick, "Off"), it disables the ONLY
; remaining ~LButton handler, leaving mouse-down dispatch permanently dead.
;
; The fix replaces the bare Hotkey() calls with HookDispatcher.Register() and
; HookDispatcher.Unregister(), which add and remove entries from the shared
; subscriber list without touching the underlying Hotkey() registration.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Source scan helper ======================
; =====================================================
; =====================================================

_GSLB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts everything from FuncDef to the next non-indented closing brace.
; Strips all comment lines first so comment text does not pollute the search.
_GSLB_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	; Find the first closing brace at the start of a line (no indentation).
	; This correctly skips nested braces inside if/loop blocks.
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	; Remove lines that start with optional whitespace then a semicolon
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; =====================================================
; =====================================================
; ======= 2/ Right-click assertions ==================
; =====================================================
; =====================================================

_GSLB_ToggleRightUsesRegister() {
	Src := _GSLB_ReadSource("modules/gestures.ahk")
	Body := _GSLB_FuncBodyStripped(Src, "GestureToggleRightClick() {")
	Assert(Body != "", "GestureToggleRightClick must exist in gestures.ahk")
	Assert(!InStr(Body, "Hotkey("),
		"GestureToggleRightClick must NOT call Hotkey() directly — use HookDispatcher.Register instead")
	Assert(InStr(Body, "HookDispatcher.Register") > 0,
		"GestureToggleRightClick must subscribe via HookDispatcher.Register")
}
Test("gestures: GestureToggleRightClick uses HookDispatcher.Register instead of bare Hotkey(~LButton) (gesture-release-disables-shared-lbutton)", _GSLB_ToggleRightUsesRegister)

_GSLB_ReleaseRightUsesUnregister() {
	Src := _GSLB_ReadSource("modules/gestures.ahk")
	Body := _GSLB_FuncBodyStripped(Src, "GestureReleaseRightClick(*) {")
	Assert(Body != "", "GestureReleaseRightClick must exist in gestures.ahk")
	Assert(!InStr(Body, "Hotkey("),
		"GestureReleaseRightClick must NOT call Hotkey() directly — use HookDispatcher.Unregister instead")
	Assert(InStr(Body, "HookDispatcher.Unregister") > 0,
		"GestureReleaseRightClick must unsubscribe via HookDispatcher.Unregister")
}
Test("gestures: GestureReleaseRightClick uses HookDispatcher.Unregister instead of bare Hotkey(~LButton,Off) (gesture-release-disables-shared-lbutton)", _GSLB_ReleaseRightUsesUnregister)




; =====================================================
; =====================================================
; ======= 3/ Left-click assertions ===================
; =====================================================
; =====================================================

_GSLB_ToggleLeftUsesRegister() {
	Src := _GSLB_ReadSource("modules/gestures.ahk")
	Body := _GSLB_FuncBodyStripped(Src, "GestureToggleLeftClick() {")
	Assert(Body != "", "GestureToggleLeftClick must exist in gestures.ahk")
	Assert(!InStr(Body, "Hotkey("),
		"GestureToggleLeftClick must NOT call Hotkey() directly — use HookDispatcher.Register instead")
	Assert(InStr(Body, "HookDispatcher.Register") > 0,
		"GestureToggleLeftClick must subscribe via HookDispatcher.Register")
}
Test("gestures: GestureToggleLeftClick uses HookDispatcher.Register instead of bare Hotkey(~RButton) (gesture-release-disables-shared-lbutton)", _GSLB_ToggleLeftUsesRegister)

_GSLB_ReleaseLeftUsesUnregister() {
	Src := _GSLB_ReadSource("modules/gestures.ahk")
	Body := _GSLB_FuncBodyStripped(Src, "GestureReleaseLeftClick(*) {")
	Assert(Body != "", "GestureReleaseLeftClick must exist in gestures.ahk")
	Assert(!InStr(Body, "Hotkey("),
		"GestureReleaseLeftClick must NOT call Hotkey() directly — use HookDispatcher.Unregister instead")
	Assert(InStr(Body, "HookDispatcher.Unregister") > 0,
		"GestureReleaseLeftClick must unsubscribe via HookDispatcher.Unregister")
}
Test("gestures: GestureReleaseLeftClick uses HookDispatcher.Unregister instead of bare Hotkey(~RButton,Off) (gesture-release-disables-shared-lbutton)", _GSLB_ReleaseLeftUsesUnregister)
