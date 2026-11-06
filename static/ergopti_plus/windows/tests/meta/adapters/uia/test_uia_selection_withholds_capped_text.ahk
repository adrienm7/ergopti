; tests/meta/adapters/uia/test_uia_selection_withholds_capped_text.ahk

; ==============================================================================
; MODULE: UIA Selection Worker Withholds a Capped Read Meta Test
; DESCRIPTION:
; Regression guard for the Windows wrap-symbols parity audit finding WSW-002. It
; is read from source because a COM TextRange cannot be produced without a desktop.
;
; The worker reads the selection with GetText(MaxTextChars), which stops at the cap
; without saying so. The wrap output replaces the WHOLE selection, so a capture
; that filled the cap was pasted back as if it were complete and dropped the tail.
; A read that reaches the cap is now withheld (status "empty"), so the caller takes
; its complete-selection route instead of wrapping a prefix.
; ==============================================================================

#Requires AutoHotkey v2.0

_UCW_CappedReadIsWithheld() {
	Body := _StripFullLineComments(_DriverFuncBody("UIASW_WorkerHandleRequest"))
	Assert(Body != "", "UIASW_WorkerHandleRequest must exist in the UIA worker adapter")
	ReadPos := InStr(Body, "GetText(MaxTextChars)")
	CapPos := InStr(Body, "StrLen(Body) >= MaxTextChars")
	OkPos := InStr(Body, "Status := " . Chr(34) . "ok" . Chr(34), , ReadPos)
	Assert(ReadPos > 0, "the selection read must stay bounded by MaxTextChars")
	Assert(CapPos > ReadPos,
		"a read that reaches MaxTextChars must be detected right after the read")
	Assert(OkPos > CapPos,
		"the capped read must be withheld BEFORE any status can mark the selection ok")
}
Test("uia-selection: a read that reaches the cap is not reported as the whole selection", _UCW_CappedReadIsWithheld)
