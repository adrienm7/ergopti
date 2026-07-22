; tests/meta/test_jsstr_cr_escaped.ahk

; ==============================================================================
; MODULE: JsStr Carriage-Return Escaping Guard
; DESCRIPTION:
; Regression guard for _HsEdWeb_JsStr (ui/personal_toml_editor_webview.ahk)
; and _OnbWeb_JsStr (ui/onboarding/webview.ahk) silently DELETING carriage
; returns instead of escaping them to "\r", unlike the correctly-escaping
; sibling *JsStr helpers (e.g. _PathsEdWeb_JsStr in ui/paths_editor/init.ahk).
; Dormant today (the app's own writer never produces raw \r bytes) but live
; for hand-edited TOML containing CRLF line endings.
;
; ESCAPING NOTE: AHK v2 treats the backtick as the string-escape character
; regardless of quote style, so producing a literal backtick at RUNTIME in
; this test's own string constants requires a DOUBLED backtick in source —
; that is what the two-backtick sequences below encode.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaJsStrEscapesCr(FuncName) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must be defined")
	; OLD deleting pattern: StrReplace(s, "`r", "") — must be gone.
	Assert(!InStr(Body, '"``r", ""'),
		FuncName . " must not silently DELETE carriage returns via StrReplace(s, backtick-r, empty-string)")
	; FIXED escaping pattern: StrReplace(s, "`r", "\r") — must be present.
	Assert(InStr(Body, '"``r", "\r"') > 0,
		FuncName . " must escape carriage returns to the two-character sequence backslash-r, matching sibling *JsStr helpers (e.g. _PathsEdWeb_JsStr)")
}

_MetaJsStrHsEdWeb() {
	_MetaJsStrEscapesCr("_HsEdWeb_JsStr")
}
Test("personal_toml_editor_webview: _HsEdWeb_JsStr escapes CR instead of deleting it", _MetaJsStrHsEdWeb)

_MetaJsStrOnbWeb() {
	_MetaJsStrEscapesCr("_OnbWeb_JsStr")
}
Test("onboarding webview: _OnbWeb_JsStr escapes CR instead of deleting it", _MetaJsStrOnbWeb)
