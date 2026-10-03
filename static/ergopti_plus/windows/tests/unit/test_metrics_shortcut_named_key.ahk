; static/ergopti_plus/windows/tests/unit/test_metrics_shortcut_named_key.ahk

; ==============================================================================
; MODULE: Ordinary Shortcut Named-Key Translation Test
; DESCRIPTION:
; Guards that the shared chord grammar and registrar preserve named-key identities.
;
; FEATURES & RATIONALE:
; 1. Regression for F03: the original code wrapped multi-character keys in
;    Send-syntax braces (e.g. "^!{f9}"), which is invalid as a Hotkey() name
;    and caused "Invalid hotkey" errors at runtime.
; 2. The fix removes the StrLen split entirely — both single-char and named
;    keys are returned as bare concatenation (mods . key), which is correct
;    Hotkey() name syntax for all key types.
; ==============================================================================





; ========================================================================
; ========================================================================
; ======= 1/ HotkeyRegistrarNativeSpec Named-Key Translation Tests =======
; ========================================================================
; ========================================================================

_MSNamed_NativeSpec(Chord) {
	Parsed := ChordParse(Chord)
	return Parsed["ok"] ? HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"]) : ""
}

_MSNamed_SingleCharKey() {
	; Single-char keys must still produce bare mods+key (unchanged behaviour)
	AssertEqual("^!m", _MSNamed_NativeSpec("ctrl+alt+m"), "single-char key")
}
Test("HotkeyRegistrarNativeSpec: single-char key produces bare mods+key", _MSNamed_SingleCharKey)

_MSNamed_FKeyNoBraces() {
	; F-keys must not be wrapped in braces — {f9} is Send syntax, not Hotkey() syntax
	AssertEqual("^!f9", _MSNamed_NativeSpec("ctrl+alt+f9"), "F-key must not be brace-wrapped")
}
Test("HotkeyRegistrarNativeSpec: F-key is not wrapped in Send-syntax braces", _MSNamed_FKeyNoBraces)

_MSNamed_SpaceNoBraces() {
	; "space" must return "^!space", not "^!{space}"
	AssertEqual("^!space", _MSNamed_NativeSpec("ctrl+alt+space"), "space must not be brace-wrapped")
}
Test("HotkeyRegistrarNativeSpec: space key is not wrapped in Send-syntax braces", _MSNamed_SpaceNoBraces)

_MSNamed_EnterNoBraces() {
	; "enter" must return "#enter", not "#{enter}"
	AssertEqual("#enter", _MSNamed_NativeSpec("win+enter"), "enter must not be brace-wrapped")
}
Test("HotkeyRegistrarNativeSpec: enter key is not wrapped in Send-syntax braces", _MSNamed_EnterNoBraces)

; Every configurable hotkey delegates to the shared chord grammar. It accepts
; documented human aliases but still rejects a typo instead of silently dropping
; that token and binding a different key.
_MSNamed_UnknownModifierRejected() {
	AssertEqual("^!m", _MSNamed_NativeSpec("control+alt+m"),
		"the shared chord grammar explicitly accepts the control alias")
	AssertEqual("", _MSNamed_NativeSpec("crtl+alt+m"),
		"a typo'd modifier must reject rather than bind a different hotkey")
	AssertEqual("^!m", _MSNamed_NativeSpec("ctrl+alt+m"),
		"valid input must still translate — guards against over-rejection")
}
Test("HotkeyRegistrarNativeSpec: an unrecognized modifier is rejected, not silently dropped",
	_MSNamed_UnknownModifierRejected)

_MSNamed_ModifierOrderIsCanonical() {
	AssertEqual("^!m", _MSNamed_NativeSpec("alt+ctrl+m"),
		"modifier permutations that name the same AHK chord must share one native identity")
	AssertEqual("^!+#f9", _MSNamed_NativeSpec("win+shift+alt+ctrl+f9"),
		"all modifier sets must use the fixed ctrl-alt-shift-win order")
}
Test("HotkeyRegistrarNativeSpec: modifier aliases have one canonical native identity",
	_MSNamed_ModifierOrderIsCanonical)

_MSNamed_DuplicateModifierRejected() {
	AssertEqual("^m", _MSNamed_NativeSpec("ctrl+ctrl+m"),
		"the shared chord corpus collapses duplicate canonical modifiers")
	AssertEqual("!m", _MSNamed_NativeSpec("alt+option+m"),
		"aliases of the same modifier collapse to one native prefix")
}
Test("HotkeyRegistrarNativeSpec: duplicate native modifiers follow the shared chord corpus",
	_MSNamed_DuplicateModifierRejected)
