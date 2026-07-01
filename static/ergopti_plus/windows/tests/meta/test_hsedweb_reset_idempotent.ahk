; tests/meta/test_hsedweb_reset_idempotent.ahk

; ==============================================================================
; MODULE: HsEdWeb Reset Idempotency Meta Test
; DESCRIPTION:
; Regression guard for a real production crash from live logs
; (ErgoptiPlus_2026-06-25.log): "Uncaught error: Invalid memory read/write. |
; vendor/WebView2.ahk (676) : [ComCall] ... remove_WebMessageReceived |
; ui/personal_toml_editor_webview.ahk (430) : [_HsEdWeb_Reset]
; _HsEdWeb_MsgSub := unset".
;
; ROOT CAUSE: _HsEdWeb_Close() is reachable from TWO independent event sources
; for the SAME teardown — the frontend's "close" JS message (_HsEdWeb_OnWebMessage)
; and the native Gui "Close" event (_HsEdWeb_OnClose), the latter of which can
; fire as a side effect of the Gui.Destroy() the former already triggered. Both
; paths called the (pre-fix) _HsEdWeb_Reset() unconditionally, so the second call
; ran `_HsEdWeb_MsgSub := unset` again. That statement's implicit __Delete calls
; remove_WebMessageReceived via a raw ComCall against the CoreWebView2 pointer
; captured when the subscription was created — a pointer already invalidated by
; the FIRST Reset()'s Controller.Close(). The result is a genuine SEH access
; violation, not an AHK exception, so the enclosing `try` (the pre-fix comment
; called it "belt-and-suspenders") cannot catch it and the whole process dies.
;
; THE FIX: a persistent _HsEdWeb_ResetDone guard flag makes _HsEdWeb_Reset() a
; true no-op on any call after the first, so the dangerous ComCall is never
; reached twice for the same controller. The flag is re-armed (set back to
; false) only when _HsEdWeb_TryOpen wires up a brand-new controller/webview
; pair, so the NEXT editor session's close still tears its own state down.
;
; SCOPE: source introspection of ui/personal_toml_editor_webview.ahk (the crash
; is a hard access violation and cannot be exercised behaviourally in the
; headless test harness, which has no live WebView2 runtime).
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_HSEDRI_ResetBody() {
	return _DriverFuncBody("_HsEdWeb_Reset")
}

_HSEDRI_TryOpenBody() {
	return _DriverFuncBody("_HsEdWeb_TryOpen")
}




; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_HSEDRI_GlobalFlagDeclared() {
	Src := _DriverDirConcat("ui")
	Assert(Src != "", "ui/ source must be readable")

	Assert(InStr(Src, "_HsEdWeb_ResetDone") > 0,
		"_HsEdWeb_ResetDone must be declared as a global guard flag in personal_toml_editor_webview.ahk — without it, _HsEdWeb_Reset() cannot detect a second invocation against an already torn-down controller (hsedweb-reset-idempotent)")
}

Test("hsedweb_reset: _HsEdWeb_ResetDone global guard flag is declared (hsedweb-reset-idempotent)",
	_HSEDRI_GlobalFlagDeclared)


_HSEDRI_ResetChecksFlagAndReturnsEarly() {
	Body := _HSEDRI_ResetBody()
	Assert(Body != "", "_HsEdWeb_Reset must be defined in personal_toml_editor_webview.ahk")

	Assert(InStr(Body, "_HsEdWeb_ResetDone") > 0,
		"_HsEdWeb_Reset must reference _HsEdWeb_ResetDone — the guard that prevents a second unsubscribe pass against an already-invalid COM pointer (hsedweb-reset-idempotent)")
	Assert(InStr(Body, "if _HsEdWeb_ResetDone") > 0,
		"_HsEdWeb_Reset must check 'if _HsEdWeb_ResetDone' and return before touching _HsEdWeb_MsgSub/_HsEdWeb_NavSub again — that ComCall against a freed controller is the exact access violation from the live crash log (hsedweb-reset-idempotent)")

	IdxCheck := InStr(Body, "if _HsEdWeb_ResetDone")
	IdxReturn := InStr(Body, "return", , IdxCheck)
	IdxMsgUnset := InStr(Body, "_HsEdWeb_MsgSub := unset")
	Assert(IdxCheck > 0 and IdxReturn > 0 and IdxMsgUnset > 0 and IdxCheck < IdxReturn and IdxReturn < IdxMsgUnset,
		"_HsEdWeb_Reset must return EARLY (guard check, then return, BEFORE '_HsEdWeb_MsgSub := unset') when _HsEdWeb_ResetDone is already true — checking the flag after the unsubscribe line would not prevent the crash (hsedweb-reset-idempotent)")
}

Test("hsedweb_reset: _HsEdWeb_Reset checks the guard and returns before unsubscribing again (hsedweb-reset-idempotent)",
	_HSEDRI_ResetChecksFlagAndReturnsEarly)


_HSEDRI_ResetSetsFlagTrue() {
	Body := _HSEDRI_ResetBody()
	Assert(InStr(Body, "_HsEdWeb_ResetDone := true") > 0,
		"_HsEdWeb_Reset must set _HsEdWeb_ResetDone := true once it proceeds past the guard, so any LATER re-entrant call (from the sibling close path) short-circuits instead of reaching remove_WebMessageReceived a second time (hsedweb-reset-idempotent)")
}

Test("hsedweb_reset: _HsEdWeb_Reset sets _HsEdWeb_ResetDone := true after the guard (hsedweb-reset-idempotent)", _HSEDRI_ResetSetsFlagTrue)


_HSEDRI_TryOpenRearmsFlag() {
	Body := _HSEDRI_TryOpenBody()
	Assert(Body != "", "_HsEdWeb_TryOpen must be defined in personal_toml_editor_webview.ahk")

	Assert(InStr(Body, "_HsEdWeb_ResetDone := false") > 0,
		"_HsEdWeb_TryOpen must set _HsEdWeb_ResetDone := false when it wires up a fresh controller/webview pair — otherwise a flag left set by a PREVIOUS editor session's close would make the NEXT session's Reset() a permanent no-op and leak that session's WebView2 controller (hsedweb-reset-idempotent)")
}

Test("hsedweb_reset: _HsEdWeb_TryOpen re-arms _HsEdWeb_ResetDone for the new controller (hsedweb-reset-idempotent)",
	_HSEDRI_TryOpenRearmsFlag)


_HSEDRI_DoubleCloseReachesReset() {
	; Confirms the exposure this guard protects against still exists structurally:
	; both the JS bridge and the native Gui Close event route through the SAME
	; _HsEdWeb_Close() -> _HsEdWeb_Reset() call, so the guard is load-bearing
	; rather than protecting a path that can no longer be re-entered.
	Src := _DriverDirConcat("ui")
	Assert(InStr(Src, '_HsEdWeb_Close()') > 0,
		'_HsEdWeb_Close must still exist as the shared teardown entry point for both the JS "close" message and the native Gui Close event (hsedweb-reset-idempotent)')

	CloseBody := _DriverFuncBody("_HsEdWeb_Close")
	Assert(InStr(CloseBody, "_HsEdWeb_Reset()") > 0,
		"_HsEdWeb_Close must call _HsEdWeb_Reset() — both the JS-triggered and native-Close-triggered paths funnel through here, which is exactly why _HsEdWeb_Reset() itself must be idempotent (hsedweb-reset-idempotent)")
}

Test("hsedweb_reset: _HsEdWeb_Close (shared by both close paths) calls _HsEdWeb_Reset (hsedweb-reset-idempotent)",
	_HSEDRI_DoubleCloseReachesReset)
