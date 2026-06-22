; tests/meta/test_layout_deadkey_endkey.ahk

; ==============================================================================
; MODULE: DeadKey EndKey Re-Send Guard Meta Test
; DESCRIPTION:
; Static source guard for the "deadkey-endkey-consumed" audit finding in
; modules/keymap/layout.ahk.
;
; ROOT CAUSE ENCODED:
; AHK InputHook with EndKeys (Enter, BackSpace, Delete) but without the "V"
; (passthrough) option silently CONSUMES those keys — the hook intercepts them
; to end the sequence but never forwards them to the application. After a dead-
; key sequence, pressing Enter would complete the sequence but the newline/delete
; would disappear: the character was produced but the structural editing action
; (newline, delete, erase) was swallowed.
;
; The fix checks ih.EndReason = "EndKey" after the hook returns and re-sends the
; consumed key via Send("{" . ih.EndKey . "}"). This test is a companion to
; test_deadkey_suspend_guard.ahk, which covers the A_IsSuspended guard; this
; file specifically pins the EndKey re-send.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ DeadKey re-sends consumed EndKey ========
; ===================================================
; ===================================================

_LDEK_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_LDEK_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_LDEK_DeadKeyResendEndKey() {
	Raw := _LDEK_ReadSource("modules/keymap/layout.ahk")
	Src := _LDEK_StripComments(Raw)
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey(Mapping) must exist in modules/keymap/layout.ahk")

	; Must check EndReason so the re-send only fires when an EndKey terminated the hook
	Assert(InStr(Body, "ih.EndReason") > 0 and InStr(Body, Chr(34) . "EndKey" . Chr(34)) > 0,
		"DeadKey must check ih.EndReason = " . Chr(34) . "EndKey" . Chr(34) . " before re-sending (deadkey-endkey-consumed)")

	; Must re-send the consumed EndKey via Send("{" endkey "}")
	Assert(InStr(Body, "Send(" . Chr(34) . "{" . Chr(34) . " . ih.EndKey . " . Chr(34) . "}" . Chr(34) . ")") > 0
		or RegExMatch(Body, "Send\(\{.*ih\.EndKey") > 0
		or InStr(Body, "ih.EndKey") > 0,
		"DeadKey must re-send ih.EndKey so Enter/BackSpace/Delete are not silently swallowed after a dead-key sequence (deadkey-endkey-consumed)")
}
Test("layout: DeadKey re-sends ih.EndKey after InputHook so EndKeys are not swallowed (deadkey-endkey-consumed)", _LDEK_DeadKeyResendEndKey)
