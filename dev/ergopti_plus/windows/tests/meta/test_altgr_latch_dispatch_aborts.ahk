; tests/meta/test_altgr_latch_dispatch_aborts.ahk

; ==============================================================================
; MODULE: AltGr Latch Dispatch Abort Meta Test
; DESCRIPTION:
; Regression guard for the non-physical AltGr abort path in
; _ScriptAltGrDispatch (infra/script_altgr_hotkeys.ahk).
;
; When the SC138 (AltGr/Kana) prefix flag is latched but the key is NOT
; physically held (e.g. following a rapid press/release that kept the prefix
; flag active), _ScriptAltGrIsPhysical returns false. Without an early-return
; in _ScriptAltGrDispatch, the function would fall through to
; RunScriptShortcutAction and fire a user script action with no physical AltGr
; chord — a spurious "ghost AltGr" action.
;
; The fix: _ScriptAltGrDispatch calls _ScriptAltGrIsPhysical first; on false it
; sends the native keystroke and returns WITHOUT calling RunScriptShortcutAction.
;
; This test asserts:
;   1. _ScriptAltGrDispatch calls _ScriptAltGrIsPhysical.
;   2. A guarded send / return block appears in the function body BEFORE
;      RunScriptShortcutAction (the abort-on-non-physical path).
;   3. The abort path sends the native key so the chord still produces the
;      expected character rather than silently dropping the keystroke.
;
; SCOPE: source introspection of infra/script_altgr_hotkeys.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_ALDA_ReadSource() {
	return _DriverDirConcat("infra")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_ALDA_DispatchCallsIsPhysical() {
	Src := _ALDA_ReadSource()
	Assert(Src != "", "infra/ source must be readable")

	Body := _DriverFuncBody("_ScriptAltGrDispatch")
	Assert(Body != "", "_ScriptAltGrDispatch must be defined in infra/script_altgr_hotkeys.ahk")

	Assert(InStr(Body, "_ScriptAltGrIsPhysical(SuffixSC)") > 0,
		"_ScriptAltGrDispatch must call _ScriptAltGrIsPhysical(SuffixSC) to verify the chord is a genuine physical AltGr press — a latched prefix flag without physical hold must not fire user script actions")
}

Test("script_altgr: _ScriptAltGrDispatch calls _ScriptAltGrIsPhysical (altgr-latch-dispatch-aborts)",
	_ALDA_DispatchCallsIsPhysical)


_ALDA_AbortPathSendsNativeAndReturns() {
	Body := _DriverFuncBody("_ScriptAltGrDispatch")
	Assert(Body != "", "_ScriptAltGrDispatch must be defined — prerequisite for this test")

	; On !_ScriptAltGrIsPhysical, the function must send NativeSend through the
	; common guarded injection primitive and return
	; before reaching RunScriptShortcutAction
	IsPhysicalPos   := InStr(Body, "_ScriptAltGrIsPhysical")
	SendNativePos   := InStr(Body, "SendFinalResult(NativeSend)")
	ActionPos       := InStr(Body, "RunScriptShortcutAction(Slot)")

	Assert(IsPhysicalPos > 0,
		"_ScriptAltGrIsPhysical must be present — prerequisite for the abort-path test")
	Assert(SendNativePos > 0,
		"_ScriptAltGrDispatch must call SendFinalResult(NativeSend) in the non-physical abort path to pass the keystroke natively without an unguarded SendInput")
	Assert(ActionPos > 0,
		"_ScriptAltGrDispatch must still call RunScriptShortcutAction(Slot) on the physical path — the abort only applies to non-physical presses")
	Assert(SendNativePos < ActionPos,
		"SendFinalResult(NativeSend) abort path must appear BEFORE RunScriptShortcutAction(Slot) in _ScriptAltGrDispatch — the abort must be able to fire without ever reaching the action call")
	Assert(InStr(Body, 'SendFinalResult("^!{" . CtrlAltSuffixKey . "}")') > 0,
		"the Ctrl+Alt fallback must also use the guarded common send primitive")
}

Test("script_altgr: non-physical abort path appears before RunScriptShortcutAction (altgr-latch-dispatch-aborts)",
	_ALDA_AbortPathSendsNativeAndReturns)


_ALDA_IsPhysicalChecksSC138State() {
	Body := _DriverFuncBody("_ScriptAltGrIsPhysical")
	Assert(Body != "", "_ScriptAltGrIsPhysical must be defined in infra/script_altgr_hotkeys.ahk")

	; Must check that SC138 (AltGr/Kana) is physically held
	Assert(InStr(Body, "SC138") > 0,
		"_ScriptAltGrIsPhysical must check SC138 physical key state to distinguish a real AltGr chord from a latched-prefix ghost")
	Assert(InStr(Body, "GetKeyState") > 0,
		"_ScriptAltGrIsPhysical must use GetKeyState to query the physical (not logical) SC138 state")
}

Test("script_altgr: _ScriptAltGrIsPhysical checks SC138 physical key state (altgr-latch-dispatch-aborts)",
        _ALDA_IsPhysicalChecksSC138State)


_ALDA_LayoutDispatchAbortsOnLatchedPrefix() {
        Body := _DriverFuncBody("AltGrShiftDispatch")
        Assert(Body != "", "AltGrShiftDispatch must be defined in modules/keymap/layout/layout_altgr.ahk")

        GuardPos := InStr(Body, '!GetKeyState("SC138", "P")')
        ReturnPos := InStr(Body, "return", false, GuardPos)
        EntryPos := InStr(Body, "Entry := Table[SC]")
        Assert(GuardPos > 0,
                "AltGrShiftDispatch must verify SC138 is physically held before dispatching a layer callback")
        Assert(ReturnPos > GuardPos and ReturnPos < EntryPos,
                "a latched SC138 prefix must return before selecting Entry/Table callback — logging alone still emits a ghost AltGr output")
}

Test("layout_altgr: non-physical SC138 latch aborts before layer output (altgr-latch-dispatch-aborts)",
        _ALDA_LayoutDispatchAbortsOnLatchedPrefix)
