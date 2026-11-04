; tests/meta/infra/toml/test_jsstr_cr_escaped.ahk

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
; The source scan only names the subjects: each helper is then called, so a helper
; that escapes through any route passes and one that deletes fails.
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
	Literal := %FuncName%("first" . Chr(13) . "second")
	Assert(InStr(Literal, Chr(13)) == 0,
		FuncName . " must not leave a raw carriage return in the injected JS string")
	Assert(InStr(Literal, "first" . Chr(92) . "rsecond") > 0,
		FuncName . " must escape a carriage return to backslash-r, not delete it: the user would see two lines joined, with nothing logged. Got " . Literal)
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
Test("every *_JsStr helper shares or implements lossless CR escaping (jsstr-cr-deleted)",
	_MetaJsStr_EveryHelperEscapesCr)
