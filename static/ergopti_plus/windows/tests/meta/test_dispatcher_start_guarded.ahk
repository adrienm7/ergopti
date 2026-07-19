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

; Returns the function body from its declaration to the first flush-left closing
; brace at one-tab indentation (class methods close with a tab + "}"). Returns ""
; when the declaration is absent. Kept (rather than _DriverFuncBody) because the
; targets are ``static`` class methods, which the framework helper's column-0
; name anchor does not match — the source comes from _DriverDirConcat("lib").
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
	Src := _DriverDirConcat("lib")
	Seg := _DSG_MethodBody(Src, "static Start() {")
	Assert(Seg != "", "HookDispatcher.Start() must exist in hook_dispatcher.ahk")
	Assert(InStr(Seg, "_ih is InputHook") > 0,
		"Start() must reuse a live InputHook (guard on _ih is InputHook) so a retry after a partial Start failure does not create a SECOND InputHook racing the first")
}
Test("HookDispatcher: Start() reuses a live InputHook (dispatcher-start-unguarded-hotkeys-leak-ih)", _DSG_StartReusesLiveInputHook)

_DSG_StartSetsStartedBeforeMouseHotkeys() {
	Src := _DriverDirConcat("lib")
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
	Src := _DriverDirConcat("lib")
	Seg := _DSG_MethodBody(Src, "static _SafeHotkey(key_name, callback_fn) {")
	Assert(Seg != "", "HookDispatcher._SafeHotkey() helper must exist")
	Assert(InStr(Seg, "try") > 0 && InStr(Seg, "catch") > 0,
		"_SafeHotkey() must wrap Hotkey() in try/catch so one rejected mouse event cannot abort the whole Start sequence")
	Assert(InStr(Seg, "LoggerWarn") > 0,
		"_SafeHotkey() must log a WARNING on a rejected hotkey rather than failing silently")
}
Test("HookDispatcher: _SafeHotkey guards each Hotkey registration (dispatcher-start-unguarded-hotkeys-leak-ih)", _DSG_SafeHotkeyGuardsRegistration)

_DSG_MouseHotkeysMatchWithHeldModifiers() {
	Src := _DriverDirConcat("lib")
	StartSeg := _DSG_MethodBody(Src, "static Start() {")
	StopSeg := _DSG_MethodBody(Src, "static Stop() {")
	DQ := Chr(34)
	MouseSpecs := [
		"LButton", "LButton Up", "RButton", "RButton Up", "MButton", "MButton Up",
		"XButton1", "XButton1 Up", "XButton2", "XButton2 Up",
		"WheelUp", "WheelDown", "WheelRight", "WheelLeft"
	]

	Assert(StartSeg != "", "HookDispatcher.Start() must exist in hook_dispatcher.ahk")
	Assert(StopSeg != "", "HookDispatcher.Stop() must exist in hook_dispatcher.ahk")
	for MouseSpec in MouseSpecs {
		WildcardSpec := "~*" . MouseSpec
		Assert(InStr(StartSeg, "_SafeHotkey(" . DQ . WildcardSpec . DQ) > 0,
			"Start() must register " . WildcardSpec . " so mouse activity is observed while a modifier is held (ctrl-wheel-delayed-cancel)")
		Assert(InStr(StopSeg, "Hotkey(" . DQ . WildcardSpec . DQ) > 0,
			"Stop() must disable the same wildcard mouse hotkey registered by Start(): " . WildcardSpec)
	}
}
Test("HookDispatcher: mouse hotkeys use wildcard variants while modifiers are held (ctrl-wheel-delayed-cancel)", _DSG_MouseHotkeysMatchWithHeldModifiers)

_DSG_IhInitializedToFalse() {
	Src := _DriverDirConcat("lib")
	; `unset` static properties raise PropertyError when read via `is` —
	; `false` lets the reuse guard evaluate without throwing on first boot
	Assert(InStr(Src, "static _ih := false") > 0,
		"HookDispatcher must declare ``static _ih := false`` — without the initializer, ``HookDispatcher._ih is InputHook`` raises PropertyError before any InputHook exists (hook-dispatcher-ih-property-error 2026-06-16)")
}
Test("HookDispatcher: static _ih is initialized to false, not left unset (hook-dispatcher-ih-property-error)", _DSG_IhInitializedToFalse)

_DSG_InputHookConstructionGuarded() {
	Src := _DriverDirConcat("lib")
	Seg := _DSG_MethodBody(Src, "static Start() {")
	Assert(Seg != "", "HookDispatcher.Start() must exist in hook_dispatcher.ahk")

	ElseIdx := InStr(Seg, "} else {")
	Assert(ElseIdx > 0, "Start() must branch on whether _ih is already a live InputHook")

	TryIdx := InStr(Seg, "try {", , ElseIdx)
	ConstructIdx := InStr(Seg, "ih := InputHook(", , ElseIdx)
	Assert(TryIdx > 0 && ConstructIdx > 0 && TryIdx < ConstructIdx,
		"HookDispatcher.Start()'s InputHook construction must open with `try {` BEFORE `ih := InputHook(...)`, symmetric with the existing _SafeHotkey() pattern used for mouse hotkeys (dispatcher-start-inputhook-unguarded)")

	StartCallIdx := InStr(Seg, "ih.Start()", , ConstructIdx)
	Assert(StartCallIdx > 0, "Start() must call ih.Start() to arm the InputHook")

	CatchIdx := InStr(Seg, "catch", , StartCallIdx)
	Assert(CatchIdx > 0,
		"HookDispatcher.Start()'s try-block must have a matching catch AFTER ih.Start() so a throw anywhere across construction/configuration/.Start() is caught (dispatcher-start-inputhook-unguarded)")

	CatchBody := SubStr(Seg, CatchIdx, InStr(Seg, "}", , CatchIdx) - CatchIdx)
	Assert(InStr(CatchBody, "LoggerError") > 0,
		"HookDispatcher.Start() must log at ERROR when InputHook construction fails, so a dead dispatcher is diagnosable instead of only surfacing via the global error handler (dispatcher-start-inputhook-unguarded)")
}
Test("HookDispatcher: Start()'s InputHook construction is guarded by try/catch with LoggerError on failure (dispatcher-start-inputhook-unguarded)", _DSG_InputHookConstructionGuarded)

_DSG_PartialStartupCleanupUsesOwnedResources() {
	Src := _DriverDirConcat("lib")
	StopSeg := _DSG_MethodBody(Src, "static Stop() {")
	StartSeg := _DSG_MethodBody(Src, "static Start() {")
	Assert(InStr(StopSeg, "!(HookDispatcher._ih is InputHook)") > 0,
		"Stop must inspect the owned InputHook even if _started was never published")
	Assert(InStr(StartSeg, "WheelMessageCallback :=") > 0,
		"wheel-message registration must retain a local callback until both registrations succeed")
	Assert(InStr(StartSeg, "OnMessage(HookDispatcherConst.WM_MOUSEWHEEL, WheelMessageCallback, 0)") > 0,
		"a partial WM_MOUSEWHEEL registration must be rolled back before ownership is cleared")
}
Test("HookDispatcher: partial startup resources are rolled back by ownership", _DSG_PartialStartupCleanupUsesOwnedResources)

_DSG_BootDoesNotPublishReadyWithoutHook() {
	DispatcherStart := _DSG_MethodBody(_DriverDirConcat("lib"), "static Start() {")
	Main := _DriverDirConcat("")
	Assert(InStr(DispatcherStart, "return false") > 0 && InStr(DispatcherStart, "return true") > 0,
		"HookDispatcher.Start must return an explicit success state so boot can enforce its readiness contract")
	StartPos := InStr(Main, "if !HookDispatcher.Start()")
	ReadyPos := InStr(Main, 'LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")')
	AbortPos := InStr(Main, "ExitApp(1)", , StartPos)
	Assert(StartPos > 0 && AbortPos > StartPos && AbortPos < ReadyPos,
		"ErgoptiPlus must abort before readiness when HookDispatcher.Start fails; a half-boot cannot own keyboard features")
}
Test("HookDispatcher: boot aborts instead of publishing ready after hook startup failure", _DSG_BootDoesNotPublishReadyWithoutHook)
