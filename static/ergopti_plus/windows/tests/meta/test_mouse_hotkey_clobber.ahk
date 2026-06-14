; tests/meta/test_mouse_hotkey_clobber.ahk

; ==============================================================================
; MODULE: Mouse Hotkey Clobber Meta Test
; DESCRIPTION:
; Static source guard for the mouse-hotkey-clobber finding.
;
; In AHK v2 a bare Hotkey("~LButton", fn) call replaces whatever handler was
; previously registered for that key. Because HookDispatcher.Start() registers
; ~LButton (and RButton/MButton/WheelUp/etc.) exactly once, any module that
; afterwards calls Hotkey("~LButton", myFn) silently removes the dispatcher's
; fan-out -- every OTHER subscriber to mouse_ldown stops receiving events.
;
; Two modules were guilty:
; - lib/hotstrings/hotstring_prefix_watcher.ahk: _InstallMouseClickResetHooks()
;   called Hotkey("~LButton", _OnMouseClickReset) directly.
; - modules/llm/llm_bridge.ahk: _LLM_PointerWatch_Start() called
;   Hotkey(key, _LLM_PointerWatch_ActivityFn, "On") for ~LButton through
;   ~WheelRight.
;
; The fix routes all dispatcher-owned keys through HookDispatcher.Register() /
; HookDispatcher.Unregister() and keeps only ~XButton1 / ~XButton2 (which the
; dispatcher does not own) as direct Hotkey() calls.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_MHCB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_MHCB_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ===================================================
; ===================================================
; ======= 2/ PrefixWatcher mouse hooks ==============
; ===================================================
; ===================================================

_MHCB_PrefixWatcherUsesDispatcher() {
	Src := _MHCB_ReadSource("lib/hotstrings/hotstring_prefix_watcher.ahk")
	Body := _MHCB_FuncBodyStripped(Src, "_InstallMouseClickResetHooks()")
	Assert(Body != "", "_InstallMouseClickResetHooks must exist in hotstring_prefix_watcher.ahk")
	Assert(InStr(Body, "HookDispatcher.Register") > 0,
		"_InstallMouseClickResetHooks must call HookDispatcher.Register — a bare Hotkey() would clobber the dispatcher's ~LButton/~RButton/~MButton handlers (mouse-hotkey-clobber)")
}
Test("prefix_watcher: _InstallMouseClickResetHooks uses HookDispatcher.Register (mouse-hotkey-clobber)", _MHCB_PrefixWatcherUsesDispatcher)

_MHCB_PrefixWatcherNoDirectLButton() {
	Src := _MHCB_ReadSource("lib/hotstrings/hotstring_prefix_watcher.ahk")
	Body := _MHCB_FuncBodyStripped(Src, "_InstallMouseClickResetHooks()")
	Assert(Body != "", "_InstallMouseClickResetHooks must exist in hotstring_prefix_watcher.ahk")
	DQ := Chr(34)
	HotkeyLButton := "Hotkey(" . DQ . "~LButton" . DQ
	Assert(InStr(Body, HotkeyLButton) = 0,
		"_InstallMouseClickResetHooks must not call Hotkey(" . DQ . "~LButton" . DQ . ") directly — use HookDispatcher.Register(EVT_MS_LDOWN, …) (mouse-hotkey-clobber)")
}
Test("prefix_watcher: _InstallMouseClickResetHooks does not call Hotkey(~LButton) directly (mouse-hotkey-clobber)", _MHCB_PrefixWatcherNoDirectLButton)




; ===================================================
; ===================================================
; ======= 3/ LLM bridge pointer watcher ============
; ===================================================
; ===================================================

_MHCB_LLMStartUsesDispatcher() {
	Src := _MHCB_ReadSource("modules/llm/llm_bridge.ahk")
	Body := _MHCB_FuncBodyStripped(Src, "_LLM_PointerWatch_Start()")
	Assert(Body != "", "_LLM_PointerWatch_Start must exist in modules/llm/llm_bridge.ahk")
	Assert(InStr(Body, "HookDispatcher.Register") > 0,
		"_LLM_PointerWatch_Start must call HookDispatcher.Register for dispatcher-owned mouse keys (mouse-hotkey-clobber)")
}
Test("llm_bridge: _LLM_PointerWatch_Start uses HookDispatcher.Register (mouse-hotkey-clobber)", _MHCB_LLMStartUsesDispatcher)

_MHCB_LLMStartNoDirectLButton() {
	Src := _MHCB_ReadSource("modules/llm/llm_bridge.ahk")
	Body := _MHCB_FuncBodyStripped(Src, "_LLM_PointerWatch_Start()")
	Assert(Body != "", "_LLM_PointerWatch_Start must exist in modules/llm/llm_bridge.ahk")
	DQ := Chr(34)
	HotkeyLButton := "Hotkey(" . DQ . "~LButton" . DQ
	Assert(InStr(Body, HotkeyLButton) = 0,
		"_LLM_PointerWatch_Start must not call Hotkey(" . DQ . "~LButton" . DQ . ") directly — use HookDispatcher.Register(EVT_MS_LDOWN, …) (mouse-hotkey-clobber)")
}
Test("llm_bridge: _LLM_PointerWatch_Start does not call Hotkey(~LButton) directly (mouse-hotkey-clobber)", _MHCB_LLMStartNoDirectLButton)

_MHCB_LLMStopUsesUnregister() {
	Src := _MHCB_ReadSource("modules/llm/llm_bridge.ahk")
	Body := _MHCB_FuncBodyStripped(Src, "_LLM_PointerWatch_Stop()")
	Assert(Body != "", "_LLM_PointerWatch_Stop must exist in modules/llm/llm_bridge.ahk")
	Assert(InStr(Body, "HookDispatcher.Unregister") > 0,
		"_LLM_PointerWatch_Stop must call HookDispatcher.Unregister to undo the dispatcher-registered subscriptions (mouse-hotkey-clobber)")
}
Test("llm_bridge: _LLM_PointerWatch_Stop uses HookDispatcher.Unregister (mouse-hotkey-clobber)", _MHCB_LLMStopUsesUnregister)
