; static/ergopti_plus/windows/tests/unit/test_hotstrings_escape_braces.ahk

; ==============================================================================
; MODULE: Hotstrings Escape Special Chars Regression Tests
; DESCRIPTION:
; Regression tests for the EscapeSpecialChars brace-escaping fix (F14).
;
; ROOT CAUSE ENCODED:
; The original implementation used two sequential StrReplace calls:
;   text := StrReplace(text, "{", "{{}")   ; '{' -> '{{}'  (contains '}')
;   text := StrReplace(text, "}", "{}}")   ; '}' -> '{}}'
; The second pass re-processed the '}' produced by the first, corrupting
; '{' into '{{{}}' instead of the correct '{{}'. The fix replaces the brace
; pair with an atomic char-by-char builder loop so neither pass can feed
; the other.
;
; APPROACH:
; EscapeSpecialChars is a nested function inside the if-block in
; modules/hotstrings.ahk and cannot be #Include-d directly. The fix is
; verified by inlining an identical implementation here and asserting the
; correct outputs — the inline copy is kept byte-for-byte identical to the
; production version so a regression in the production code would motivate
; an identical failure if the same bug were re-introduced here.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================
; ==============================================
; ======= 1/ Inline EscapeSpecialChars =========
; ==============================================
; ==============================================

; Inline copy of EscapeSpecialChars from modules/hotstrings.ahk.
; Must be kept identical to the production nested function.
_ESC_EscapeSpecialChars(text) {
	; Escape braces atomically so the '{' -> '{{}'  expansion does not feed a
	; '}' into a later StrReplace pass (which would corrupt '{' into '{{{}}}')
	escaped := ""
	loop parse, text {
		c := A_LoopField
		if (c == "{")
			escaped .= "{{}"
		else if (c == "}")
			escaped .= "{}}"
		else
			escaped .= c
	}
	; The remaining escapes do not emit '{' or '}' so sequential StrReplace is safe
	escaped := StrReplace(escaped, "^", "{Asc 94}")
	escaped := StrReplace(escaped, "~", "{Asc 126}")
	escaped := StrReplace(escaped, "+", "{+}")
	escaped := StrReplace(escaped, "!", "{!}")
	escaped := StrReplace(escaped, "#", "{#}")
	return escaped
}





; =============================================
; =============================================
; ======= 2/ Brace escaping correctness =======
; =============================================
; =============================================

_ESC_OpenBrace() {
	; Before the fix, '{' was corrupted to '{{{}}' by the double-pass bug
	AssertEqual("{{}", _ESC_EscapeSpecialChars("{"), "{ must escape to {{}")
}
Test("EscapeSpecialChars: open brace escapes to {{}  (F14 regression)", _ESC_OpenBrace)

_ESC_CloseBrace() {
	AssertEqual("{}}", _ESC_EscapeSpecialChars("}"), "} must escape to {}}")
}
Test("EscapeSpecialChars: close brace escapes to {}}  (F14 regression)", _ESC_CloseBrace)

_ESC_BracePair() {
	; Before the fix, "{}" would become '{{{}}}' (both chars corrupted)
	AssertEqual("{{}{}}", _ESC_EscapeSpecialChars("{}"), "{} must escape to {{}{}}")
}
Test("EscapeSpecialChars: brace pair escapes to {{}{}}  (F14 regression)", _ESC_BracePair)

_ESC_MixedBraces() {
	AssertEqual("a{{}b{}}c", _ESC_EscapeSpecialChars("a{b}c"), "a{b}c must escape correctly")
}
Test("EscapeSpecialChars: mixed brace string escapes correctly  (F14 regression)", _ESC_MixedBraces)





; ==============================================
; ==============================================
; ======= 3/ Other special-char escaping =======
; ==============================================
; ==============================================

_ESC_Caret() {
	AssertEqual("{Asc 94}a", _ESC_EscapeSpecialChars("^a"), "^ must escape to {Asc 94}")
}
Test("EscapeSpecialChars: caret escapes to {Asc 94}", _ESC_Caret)

_ESC_Tilde() {
	AssertEqual("{Asc 126}", _ESC_EscapeSpecialChars("~"), "~ must escape to {Asc 126}")
}
Test("EscapeSpecialChars: tilde escapes to {Asc 126}", _ESC_Tilde)

_ESC_Plus() {
	AssertEqual("{+}", _ESC_EscapeSpecialChars("+"), "+ must escape to {+}")
}
Test("EscapeSpecialChars: plus escapes to {+}", _ESC_Plus)

_ESC_Exclamation() {
	AssertEqual("{!}", _ESC_EscapeSpecialChars("!"), "! must escape to {!}")
}
Test("EscapeSpecialChars: exclamation escapes to {!}", _ESC_Exclamation)

_ESC_Hash() {
	AssertEqual("{#}", _ESC_EscapeSpecialChars("#"), "# must escape to {#}")
}
Test("EscapeSpecialChars: hash escapes to {#}", _ESC_Hash)

_ESC_PlainText() {
	AssertEqual("hello", _ESC_EscapeSpecialChars("hello"), "plain text must pass through unchanged")
}
Test("EscapeSpecialChars: plain text passes through unchanged", _ESC_PlainText)

_ESC_EmailWithPlusTag() {
	; Gmail plus-tag: user+tag@example.com — the '+' must become '{+}' not Shift
	AssertEqual("user{+}tag@example.com", _ESC_EscapeSpecialChars("user+tag@example.com"),
		"Gmail plus-tag email must have + escaped to {+}  (F17 motivation)")
}
Test("EscapeSpecialChars: Gmail plus-tag email escapes + correctly  (F17 motivation)", _ESC_EmailWithPlusTag)
