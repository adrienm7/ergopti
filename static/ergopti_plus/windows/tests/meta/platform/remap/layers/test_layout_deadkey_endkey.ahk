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

_LDEK_ReadSource(FileName) {
	return _DriverFileSource(FileName)
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
	Raw := _LDEK_ReadSource("layout.ahk")
	Src := _LDEK_StripComments(Raw)
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey(Mapping) must exist in modules/keymap/layout.ahk")

	; Every scalar now ends with EndKey too. Replay only the canonical
	; reader's explicit named-control result, never a literal scalar unit.
	Read := InStr(Body, 'Capture := _SIHO_ReadScalar(ih, NamedKeys)', true)
	Guard := InStr(Body, 'if Capture.Kind == "control"', true)
	SendPos := InStr(Body, 'SendNewResult(CapturedPrefix . "{" . Capture.Name . "}", False, False)', true)
	Assert(Read > 0 && Guard > Read && SendPos > Guard,
		"DeadKey must replay only its decoded named control after successful settlement")
	Assert(InStr(Body, 'Send("{" . ih.EndKey . "}")', true) == 0,
		"raw literal EndKey scalars must not be interpreted as a second control-key send")
}
Test("layout: DeadKey re-sends ih.EndKey after InputHook so EndKeys are not swallowed (deadkey-endkey-consumed)", _LDEK_DeadKeyResendEndKey)

; OSW-001 on the legacy DeadKey path: the control used to be replayed bare, so
; Ctrl+Backspace after a dead key erased one character and Shift+Enter lost its
; Shift. The prefix is built from the hook's captured EndMods, the state of the
; completing chord, never from the live modifier state at replay time.
_LDEK_DeadKeyReplaysControlModifiers() {
	Body := _LDEK_StripComments(_DriverFuncBody("DeadKey"))
	Assert(Body != "", "DeadKey(Mapping) must exist in modules/keymap/layout.ahk")
	Guard := InStr(Body, 'if Capture.Kind == "control"', true)
	Prefix := InStr(Body, "InStr(ih.EndMods, Symbol)", true)
	Replay := InStr(Body, 'SendNewResult(CapturedPrefix . "{" . Capture.Name . "}"', true)
	Assert(Guard > 0 && Prefix > Guard && Replay > Prefix,
		"DeadKey must replay a named control with the modifiers captured in ih.EndMods (OSW-001)")
	for Symbol in ["^", "!", "+", "#"]
		Assert(InStr(Body, '"' . Symbol . '"', true, Guard) > 0,
			"DeadKey must replay the " . Symbol . " modifier of the completing chord (OSW-001)")
	Assert(InStr(Body, 'Send("{" . Capture.Name . "}")', true) == 0,
		"DeadKey must not replay a named control without its modifiers (OSW-001)")
	Assert(!RegExMatch(Body, 'GetKeyState\("(Ctrl|Shift|Alt|LWin)"'),
		"DeadKey must not rebuild the chord from the live modifier state at replay time (OSW-001)")
}
Test("layout: DeadKey replays a named control with its captured modifiers (OSW-001)", _LDEK_DeadKeyReplaysControlModifiers)
