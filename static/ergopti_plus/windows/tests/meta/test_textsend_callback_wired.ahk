; tests/meta/test_textsend_callback_wired.ahk

; ==============================================================================
; MODULE: TextSend Clipboard Callback Wiring Guard
; DESCRIPTION:
; Static source guard for the _TextSendClipboard callback-wiring fix in
; adapters/text_sender.ahk.
;
; ROOT CAUSE ENCODED:
; The original _TextSendClipboard helper never received the Callback argument —
; TextSend called SetTimer(() => _TextSendClipboard(Text, Saved), -1) without
; forwarding the Callback, then fired try Callback() immediately in the TextSend
; body on a different thread. Callers that depended on the callback being
; synchronised with the actual paste (e.g., to know the text reached the target
; app) would fire their callback before the Ctrl+V was even sent.
;
; The fix passes Callback into _TextSendClipboard and fires it AFTER the paste
; keystroke inside that helper. The deferred lambda in TextSend now reads:
;   SetTimer(() => _TextSendClipboard(Text, Saved, Callback), -1)
; and the immediate try Callback() call in the TextSend body is removed from the
; clipboard path.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTCW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TTCW_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; =============================================================
; =============================================================
; ======= 1/ Callback forwarded into _TextSendClipboard =======
; =============================================================
; =============================================================

_TTCW_CallbackForwarded() {
	Src := _TTCW_StripLineComments(_TTCW_ReadSource("adapters/text_sender.ahk"))
	Assert(Src != "", "adapters/text_sender.ahk must be readable")

	; The FIFO worker must bind each request callback into the completion bridge.
	Assert(InStr(Src, "_TextSenderClipboardCompleted.Bind(Request.Callback)") > 0,
		"the FIFO worker must bind the request callback into the clipboard completion bridge so it fires after paste")
}
Test("text_sender: Callback is forwarded into _TextSendClipboard (fires after paste, not before)", _TTCW_CallbackForwarded)





; ================================================================
; ================================================================
; ======= 2/ _TextSendClipboard fires callback after paste =======
; ================================================================
; ================================================================

_TTCW_CallbackAfterPaste() {
	Src := _TTCW_StripLineComments(_TTCW_ReadSource("adapters/text_sender.ahk"))

	Body := _DriverFuncBody("_TextSendClipboard")
	Assert(Body != "", "_TextSendClipboard must accept a Callback parameter")

	; The Callback must be invoked inside _TextSendClipboard (after Ctrl+V).
	; Routed through _TextSenderInvokeCallback (bare-try-anti-pattern /
	; F52b fix) instead of a raw "Callback()" call — that helper is still the
	; thing that ultimately calls Callback().
	Assert(InStr(Body, "_TextSenderInvokeCallback(Callback)") > 0,
		"_TextSendClipboard must call _TextSenderInvokeCallback(Callback) after the paste keystroke")
}
Test("text_sender: _TextSendClipboard invokes Callback after Ctrl+V (not before)", _TTCW_CallbackAfterPaste)
