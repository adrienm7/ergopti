; tests/meta/platform/remap/layers/test_layout_deadkey_endkey.ahk

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
; The scalar reader distinguishes named controls from literal EndKey text.
; Only a named control is re-sent through the key-send port. This test is a companion to
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

	; Every scalar now ends with EndKey too. Replay only the canonical
	; reader's explicit named-control result, never a literal scalar unit.
	Read := InStr(Body, 'Capture := _SIHO_ReadScalar(ih, NamedKeys)', true)
	Guard := InStr(Body, 'if Capture.Kind == "control"', true)
	SendPos := InStr(Body, 'Send("{" . Capture.Name . "}")', true)
	Assert(Read > 0 && Guard > Read && SendPos > Guard,
		"DeadKey must replay only its decoded named control after successful settlement")
	Assert(InStr(Body, 'Send("{" . ih.EndKey . "}")', true) == 0,
		"raw literal EndKey scalars must not be interpreted as a second control-key send")
}
Test("layout: DeadKey re-sends ih.EndKey after InputHook so EndKeys are not swallowed (deadkey-endkey-consumed)", _LDEK_DeadKeyResendEndKey)
