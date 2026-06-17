; tests/meta/test_clipwait_binary.ahk

; ==============================================================================
; MODULE: ClipWait Binary Data Meta Test
; DESCRIPTION:
; Static source guard for the "getselection-clipwait-binary-freeze" audit
; finding in lib/hotstrings/hotstring_engine.ahk.
;
; ROOT CAUSE ENCODED:
; GetSelection() called ClipWait(GET_SELECTION_TIMEOUT_SEC) without the second
; argument. By default AHK ClipWait only resolves when the clipboard contains
; TEXT. If the user had an image or native object selected, ClipWait would block
; for the full timeout (500ms) before returning 0, freezing the keylogger and
; UI for half a second on every GetSelection() call involving non-text content.
;
; The fix: ClipWait(GET_SELECTION_TIMEOUT_SEC, 1) — the second arg 1 makes
; ClipWait succeed immediately for ANY clipboard format, after which
; A_Clipboard returns "" gracefully for non-text content.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ GetSelection ClipWait accepts binary data =======
; ============================================================
; ============================================================

_CWB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_CWB_FuncBody(Src, FuncDecl) {
	Idx := InStr(Src, FuncDecl)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	return End ? SubStr(Rest, 1, End + 1) : Rest
}

_CWB_ClipWaitAcceptsBinary() {
	Src := _CWB_ReadSource("lib/hotstrings/hotstring_engine.ahk")
	Body := _CWB_FuncBody(Src, "GetSelection()")

	Assert(Body != "", "GetSelection() must exist in hotstring_engine.ahk")

	; The second arg (1) must be present to accept all clipboard formats
	Assert(RegExMatch(Body, "ClipWait\([^,]+,\s*1\)") > 0,
		"GetSelection() must call ClipWait(timeout, 1) to accept binary/image content without freezing (getselection-clipwait-binary-freeze)")

	; The single-arg form must be gone
	Assert(!RegExMatch(Body, "ClipWait\(GET_SELECTION_TIMEOUT_SEC\)"),
		"GetSelection() must NOT call ClipWait with only one argument — image content causes a 500ms freeze (getselection-clipwait-binary-freeze)")
}
Test("hotstring_engine: GetSelection ClipWait uses mode 1 for binary data (getselection-clipwait-binary-freeze)", _CWB_ClipWaitAcceptsBinary)
