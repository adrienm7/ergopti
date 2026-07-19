; tests/meta/test_clipwait_binary.ahk

; ==============================================================================
; MODULE: ClipWait Binary Data Meta Test
; DESCRIPTION:
; Static source guard for the "getselection-clipwait-binary-freeze" audit
; finding in lib/hotstrings/hotstring_engine.ahk.
;
; ROOT CAUSE ENCODED:
; The asynchronous selection poll must accept binary clipboard formats. If it
; waited for text only, an image/native selection would remain pending until the
; deadline, instead of resolving promptly to an empty text result.
;
; The fix: ClipWait(0, 1) — a zero-timeout probe with mode 1 never blocks and
; resolves immediately for ANY clipboard format, after which A_Clipboard
; returns "" gracefully for non-text content.
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

_CWB_AsyncPollAcceptsBinaryWithoutWaiting() {
	Src := _CWB_ReadSource("lib/hotstrings/hotstring_engine.ahk")
	Body := _DriverFuncBody("_SelectionCapturePoll")

	Assert(Body != "", "_SelectionCapturePoll() must exist in hotstring_engine.ahk")

	Assert(RegExMatch(Body, "ClipWait\(0,\s*1\)") > 0,
		"_SelectionCapturePoll() must use ClipWait(0, 1): accept binary/image data without a blocking clipboard wait (getselection-clipwait-binary-freeze)")

	Assert(InStr(Body, "ClipWait(GET_SELECTION_TIMEOUT_SEC") = 0,
		"_SelectionCapturePoll() must not wait for the full selection deadline — image content must not freeze the input path")
}
Test("hotstring_engine: async selection poll accepts binary data without waiting (getselection-clipwait-binary-freeze)", _CWB_AsyncPollAcceptsBinaryWithoutWaiting)
