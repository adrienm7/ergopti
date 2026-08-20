; static/ergopti_plus/windows/tests/unit/test_metrics_shortcut_named_key.ahk

; ==============================================================================
; MODULE: Metrics Shortcut Named-Key Translation Test
; DESCRIPTION:
; Guards that MS_ToAhkSyntax() produces valid Hotkey() names for all key types.
;
; FEATURES & RATIONALE:
; 1. Regression for F03: the original code wrapped multi-character keys in
;    Send-syntax braces (e.g. "^!{f9}"), which is invalid as a Hotkey() name
;    and caused "Invalid hotkey" errors at runtime.
; 2. The fix removes the StrLen split entirely — both single-char and named
;    keys are returned as bare concatenation (mods . key), which is correct
;    Hotkey() name syntax for all key types.
; ==============================================================================





; =============================================================
; =============================================================
; ======= 1/ MS_ToAhkSyntax Named-Key Translation Tests =======
; =============================================================
; =============================================================

_MSNamed_SingleCharKey() {
	; Single-char keys must still produce bare mods+key (unchanged behaviour)
	AssertEqual("^!m", MS_ToAhkSyntax("ctrl+alt+m"), "single-char key")
}
Test("MS_ToAhkSyntax: single-char key produces bare mods+key", _MSNamed_SingleCharKey)

_MSNamed_FKeyNoBraces() {
	; F-keys must not be wrapped in braces — {f9} is Send syntax, not Hotkey() syntax
	AssertEqual("^!f9", MS_ToAhkSyntax("ctrl+alt+f9"), "F-key must not be brace-wrapped")
}
Test("MS_ToAhkSyntax: F-key is not wrapped in Send-syntax braces", _MSNamed_FKeyNoBraces)

_MSNamed_SpaceNoBraces() {
	; "space" must return "^!space", not "^!{space}"
	AssertEqual("^!space", MS_ToAhkSyntax("ctrl+alt+space"), "space must not be brace-wrapped")
}
Test("MS_ToAhkSyntax: space key is not wrapped in Send-syntax braces", _MSNamed_SpaceNoBraces)

_MSNamed_EnterNoBraces() {
	; "enter" must return "#enter", not "#{enter}"
	AssertEqual("#enter", MS_ToAhkSyntax("win+enter"), "enter must not be brace-wrapped")
}
Test("MS_ToAhkSyntax: enter key is not wrapped in Send-syntax braces", _MSNamed_EnterNoBraces)

; Every configurable hotkey delegates to the shared chord grammar. It accepts
; documented human aliases but still rejects a typo instead of silently dropping
; that token and binding a different key.
_MSNamed_UnknownModifierRejected() {
	AssertEqual("^!m", MS_ToAhkSyntax("control+alt+m"),
		"the shared chord grammar explicitly accepts the control alias")
	AssertEqual("", MS_ToAhkSyntax("crtl+alt+m"),
		"a typo'd modifier must reject rather than bind a different hotkey")
	AssertEqual("^!m", MS_ToAhkSyntax("ctrl+alt+m"),
		"valid input must still translate — guards against over-rejection")
}
Test("MS_ToAhkSyntax: an unrecognized modifier is rejected, not silently dropped",
	_MSNamed_UnknownModifierRejected)

_MSNamed_ModifierOrderIsCanonical() {
	AssertEqual("^!m", MS_ToAhkSyntax("alt+ctrl+m"),
		"modifier permutations that name the same AHK chord must share one native identity")
	AssertEqual("^!+#f9", MS_ToAhkSyntax("win+shift+alt+ctrl+f9"),
		"all modifier sets must use the fixed ctrl-alt-shift-win order")
}
Test("MS_ToAhkSyntax: modifier aliases have one canonical native identity",
	_MSNamed_ModifierOrderIsCanonical)

_MSNamed_DuplicateModifierRejected() {
	AssertEqual("^m", MS_ToAhkSyntax("ctrl+ctrl+m"),
		"the shared chord corpus collapses duplicate canonical modifiers")
	AssertEqual("!m", MS_ToAhkSyntax("alt+option+m"),
		"aliases of the same modifier collapse to one native prefix")
}
Test("MS_ToAhkSyntax: duplicate native modifiers follow the shared chord corpus",
	_MSNamed_DuplicateModifierRejected)
