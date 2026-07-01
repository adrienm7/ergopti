; tests/meta/test_webview_reset_idempotent_siblings.ahk

; ==============================================================================
; MODULE: WebView2 Reset Idempotency — Sibling Files Meta Test
; DESCRIPTION:
; Companion to test_hsedweb_reset_idempotent.ahk (the confirmed production
; crash site). The identical double-teardown exposure — a second Reset() pass
; calling remove_WebMessageReceived via ComCall against a CoreWebView2 pointer
; already invalidated by an earlier Controller.Close() — was independently
; verified and fixed in 6 sibling WebView2 hosts (F7). This asserts the same
; ResetDone-guard shape is present in every one of them, so a future edit to
; any single sibling cannot silently regress back to the crashing pattern.
;
; SCOPE: source introspection only — the crash is a hard SEH access violation
; and cannot be exercised behaviourally in the headless test harness, which
; has no live WebView2 runtime.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Sibling registry =========================
; ====================================================
; ====================================================

; One entry per sibling file: {flag, reset_fn, rearm_fn, unsub_line}.
; unsub_line is the first subscription-teardown statement inside reset_fn that
; the guard must precede — the exact ComCall the live crash's second pass hit.
_WVRIS_Siblings() {
	return [
		Map("flag", "_ActPickWeb_ResetDone", "reset_fn", "_ActPickWeb_Reset", "rearm_fn", "_ActPickWeb_TryOpen", "unsub_line", "_ActPickWeb_MsgSub := unset"),
		Map("flag", "_HCWWeb_ResetDone",     "reset_fn", "_HCWWeb_Reset",     "rearm_fn", "_HCWWeb_TryOpen",     "unsub_line", "_HCWWeb_MsgSub := unset"),
		Map("flag", "_OnbWeb_ResetDone",     "reset_fn", "_OnbWeb_Reset",     "rearm_fn", "_Onboarding_TryWeb",  "unsub_line", "_OnbWeb_MsgSub := unset"),
		Map("flag", "_PathsEdWeb_ResetDone", "reset_fn", "_PathsEdWeb_Reset", "rearm_fn", "_PathsEdWeb_TryOpen", "unsub_line", "_PathsEdWeb_MsgSub := unset"),
		Map("flag", "_PiEdWeb_ResetDone",    "reset_fn", "_PiEdWeb_Reset",    "rearm_fn", "_PiEdWeb_TryOpen",    "unsub_line", "_PiEdWeb_MsgSub := unset"),
		Map("flag", "_PromptEdWeb_ResetDone", "reset_fn", "_PromptEdWeb_Reset", "rearm_fn", "_PromptEdWeb_TryOpen", "unsub_line", "_PromptEdWeb_MsgSub := unset"),
	]
}




; ===================================================
; ===================================================
; ======= 2/ Test registration ========================
; ===================================================
; ===================================================

for _Entry in _WVRIS_Siblings() {
	(_Sib => Test(
		"webview reset idempotent: " . _Sib["reset_fn"] . " checks " . _Sib["flag"] . " and returns before unsubscribing again (webview-reset-idempotent-siblings)",
		() => _WVRIS_ResetChecksFlagAndReturnsEarly(_Sib)
	))(_Entry)
}

_WVRIS_ResetChecksFlagAndReturnsEarly(Sib) {
	Body := _DriverFuncBody(Sib["reset_fn"])
	Assert(Body != "", Sib["reset_fn"] . " must be defined")

	Assert(InStr(Body, Sib["flag"]) > 0,
		Sib["reset_fn"] . " must reference " . Sib["flag"] . " — the guard that prevents a second unsubscribe pass against an already-invalid COM pointer (webview-reset-idempotent-siblings)")
	Assert(InStr(Body, "if " . Sib["flag"]) > 0,
		Sib["reset_fn"] . " must check 'if " . Sib["flag"] . "' and return before touching the subscription globals again (webview-reset-idempotent-siblings)")

	IdxCheck  := InStr(Body, "if " . Sib["flag"])
	IdxReturn := InStr(Body, "return", , IdxCheck)
	IdxUnsub  := InStr(Body, Sib["unsub_line"])
	Assert(IdxCheck > 0 and IdxReturn > 0 and IdxUnsub > 0 and IdxCheck < IdxReturn and IdxReturn < IdxUnsub,
		Sib["reset_fn"] . " must return EARLY (guard check, then return, BEFORE '" . Sib["unsub_line"] . "') when " . Sib["flag"] . " is already true (webview-reset-idempotent-siblings)")
}

for _Entry2 in _WVRIS_Siblings() {
	(_Sib => Test(
		"webview reset idempotent: " . _Sib["reset_fn"] . " sets " . _Sib["flag"] . " := true after the guard (webview-reset-idempotent-siblings)",
		() => _WVRIS_ResetSetsFlagTrue(_Sib)
	))(_Entry2)
}

_WVRIS_ResetSetsFlagTrue(Sib) {
	Body := _DriverFuncBody(Sib["reset_fn"])
	Assert(InStr(Body, Sib["flag"] . " := true") > 0,
		Sib["reset_fn"] . " must set " . Sib["flag"] . " := true once it proceeds past the guard, so a later re-entrant call short-circuits instead of reaching the unsubscribe ComCall a second time (webview-reset-idempotent-siblings)")
}

for _Entry3 in _WVRIS_Siblings() {
	(_Sib => Test(
		"webview reset idempotent: " . _Sib["rearm_fn"] . " re-arms " . _Sib["flag"] . " for the new controller (webview-reset-idempotent-siblings)",
		() => _WVRIS_RearmFnResetsFlag(_Sib)
	))(_Entry3)
}

_WVRIS_RearmFnResetsFlag(Sib) {
	Body := _DriverFuncBody(Sib["rearm_fn"])
	Assert(Body != "", Sib["rearm_fn"] . " must be defined")
	Assert(InStr(Body, Sib["flag"] . " := false") > 0,
		Sib["rearm_fn"] . " must set " . Sib["flag"] . " := false when wiring up a fresh controller/webview pair — otherwise a flag left set by a PREVIOUS session's close would make the NEXT session's reset a permanent no-op and leak that session's WebView2 controller (webview-reset-idempotent-siblings)")
}
