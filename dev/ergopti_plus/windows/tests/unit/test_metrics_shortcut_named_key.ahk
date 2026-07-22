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

; An unrecognised modifier token used to be skipped, which still produced a
; syntactically valid Hotkey() name — so Hotkey() succeeded, the binding was
; persisted, and a typo silently bound a DIFFERENT key than the one displayed.
; The docstring already promised "" on malformed input; the code did not honour
; it. These cases pin the contract in both directions.
_MSNamed_UnknownModifierRejected() {
	AssertEqual("", MS_ToAhkSyntax("control+alt+m"),
		"an unknown modifier token must reject the whole string, not degrade ^!m to !m")
	AssertEqual("", MS_ToAhkSyntax("crtl+alt+m"),
		"a typo'd modifier must reject rather than bind a different hotkey")
	AssertEqual("^!m", MS_ToAhkSyntax("ctrl+alt+m"),
		"valid input must still translate — guards against over-rejection")
}
Test("MS_ToAhkSyntax: an unrecognized modifier is rejected, not silently dropped",
	_MSNamed_UnknownModifierRejected)
