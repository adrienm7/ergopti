; tests/meta/test_dispatcher_start_guarded.ahk

; ==============================================================================
; MODULE: HookDispatcher Start-Guard Meta Test
; DESCRIPTION:
; Static source guard for the finding dispatcher-start-unguarded-hotkeys-leak-ih.
;
; HookDispatcher.Start() used to set _started := true only AFTER registering all
; ten mouse Hotkeys, and each Hotkey() was unguarded. On a hardened machine where
; one wheel/button registration is rejected, Start() threw mid-way leaving a live
; InputHook with _started == false. A later Start() retry then created a SECOND
; InputHook racing the first for the key stream - exactly the multi-hook
; contention this module exists to prevent.
;
; The fix (a) reuses the existing InputHook when _ih is already an InputHook,
; (b) sets _started := true immediately after the InputHook is live (before the
; optional mouse hotkeys), and (c) routes every mouse Hotkey() through the
; _SafeHotkey() helper, which try/catches and logs a WARNING instead of throwing.
;
; Meta-static because Start() creates a real InputHook and registers real OS
; Hotkeys, which is unsafe to invoke in the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_DSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the function body from its declaration to the first flush-left closing
; brace at one-tab indentation (class methods close with a tab + "}"). Returns ""
; when the declaration is absent.
_DSG_MethodBody(Src, MethodDef) {
	Idx := InStr(Src, MethodDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	; Class methods are indented one tab; their closing brace is "`n`t}".
	End := InStr(Rest, "`n`t}")
	if End
		return SubStr(Rest, 1, End + 2)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Start atomicity assertions ============
; ==================================================
; ==================================================

_DSG_StartReusesLiveInputHook() {
	Src := _DSG_ReadSource("lib/hook_dispatcher.ahk")
	Seg := _DSG_MethodBody(Src, "static Start() {")
	Assert(Seg != "", "HookDispatcher.Start() must exist in hook_dispatcher.ahk")
	Assert(InStr(Seg, "_ih is InputHook") > 0,
		"Start() must reuse a live InputHook (guard on _ih is InputHook) so a retry after a partial Start failure does not create a SECOND InputHook racing the first")
}
Test("HookDispatcher: Start() reuses a live InputHook (dispatcher-start-unguarded-hotkeys-leak-ih)", _DSG_StartReusesLiveInputHook)

_DSG_StartSetsStartedBeforeMouseHotkeys() {
	Src := _DSG_ReadSource("lib/hook_dispatcher.ahk")
	Seg := _DSG_MethodBody(Src, "static Start() {")
	StartedIdx := InStr(Seg, "_started := true")
	HotkeyIdx := InStr(Seg, "_SafeHotkey(")
	Assert(StartedIdx > 0, "Start() must set _started := true")
	Assert(HotkeyIdx > 0, "Start() must register mouse hotkeys via _SafeHotkey()")
	Assert(StartedIdx < HotkeyIdx,
		"Start() must set _started := true BEFORE the mouse hotkey block - a per-hotkey failure must not leave a live InputHook with _started false")
}
Test("HookDispatcher: Start() sets _started before mouse hotkeys (dispatcher-start-unguarded-hotkeys-leak-ih)", _DSG_StartSetsStartedBeforeMouseHotkeys)

_DSG_SafeHotkeyGuardsRegistration() {
	Src := _DSG_ReadSource("lib/hook_dispatcher.ahk")
	Seg := _DSG_MethodBody(Src, "static _SafeHotkey(key_name, callback_fn) {")
	Assert(Seg != "", "HookDispatcher._SafeHotkey() helper must exist")
	Assert(InStr(Seg, "try") > 0 && InStr(Seg, "catch") > 0,
		"_SafeHotkey() must wrap Hotkey() in try/catch so one rejected mouse event cannot abort the whole Start sequence")
	Assert(InStr(Seg, "LoggerWarn") > 0,
		"_SafeHotkey() must log a WARNING on a rejected hotkey rather than failing silently")
}
Test("HookDispatcher: _SafeHotkey guards each Hotkey registration (dispatcher-start-unguarded-hotkeys-leak-ih)", _DSG_SafeHotkeyGuardsRegistration)
