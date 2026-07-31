; tests/meta/test_jsstr_cr_escaped.ahk

; ==============================================================================
; MODULE: JsStr Carriage-Return Escaping Guard
; DESCRIPTION:
; Every *_JsStr helper builds a JavaScript string literal that is then injected
; into a WebView. A carriage return inside that text must be ESCAPED to the
; two-character sequence backslash-r, never deleted: dropping it silently joins
; what should have been two lines, with nothing logged.
;
; WHY THIS SCANS RATHER THAN LISTS:
; The previous version named TWO helpers by hand. The driver has ELEVEN, and
; three of the nine it did not name were still deleting — including the changelog
; renderer, whose input is a GitHub release body written by a human on a machine
; whose line endings nobody controls, and the model-browser catalogue. A guard
; over a hand-written list covers whatever someone remembered; this one discovers
; its subjects, so the next helper is covered the day it lands.
;
; ESCAPING NOTE: AHK v2 treats the backtick as the string-escape character
; regardless of quote style, so producing a literal backtick at RUNTIME in
; this test's own string constants requires a DOUBLED backtick in source —
; that is what the two-backtick sequences below encode.
; ==============================================================================

#Requires AutoHotkey v2.0

; Names of every *_JsStr function DEFINED in the driver. Anchored on a
; definition line (name, parameter list, opening brace) so an indented call site
; is never mistaken for one.
_MetaJsStr_AllHelperNames() {
	Src := _DriverSourceNoComments()
	Names := Map()
	Pos := 1
	while (Found := RegExMatch(Src, "m)^[ \t]*(_\w*JsStr)\([^\r\n]*\)\s*\{", &M, Pos)) {
		Pos := Found + M.Len
		Names[M[1]] := true
	}
	Out := []
	for Name, _ in Names
		Out.Push(Name)
	return Out
}

_MetaJsStrEscapesCr(FuncName) {
	Body := _DriverFuncBody(FuncName)
	; OLD deleting pattern: StrReplace(s, "`r", "") — must be gone.
	Assert(!InStr(Body, '"``r", ""'),
		FuncName . " must not silently DELETE carriage returns: the character vanishes from the injected JS string and the user sees two lines joined, with nothing logged")
	; FIXED escaping pattern: StrReplace(s, "`r", "\r") — must be present.
	Assert(InStr(Body, '"``r", "\r"') > 0,
		FuncName . " must escape carriage returns to the two-character sequence backslash-r, like every sibling *JsStr helper")
}

_MetaJsStr_EveryHelperEscapesCr() {
	Names := _MetaJsStr_AllHelperNames()
	; Without a floor, a regex that stopped matching would report zero helpers and
	; pass in silence — the exact failure shape this file exists to prevent.
	Assert(Names.Length >= 8,
		"expected at least 8 *_JsStr helpers in the driver, found " . Names.Length . " — the discovery scan is broken, not the driver")
	for Name in Names
		_MetaJsStrEscapesCr(Name)
}
Test("every *_JsStr helper escapes CR instead of deleting it (jsstr-cr-deleted)",
	_MetaJsStr_EveryHelperEscapesCr)
