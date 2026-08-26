; static/ergopti_plus/windows/tests/unit/test_clipboard_history_paste.ahk

; ==============================================================================
; MODULE: Clipboard-history paste modifier provenance regression
; DESCRIPTION:
; Windows clipboard history can synthesize the Ctrl+V edge used to insert a
; selected item. The Ergopti physical V key is SC02F, so the control-layer
; compatibility route must not trust a logical Ctrl edge that Windows can
; release while AutoHotkey re-emits the shortcut.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Recorder fixture =======
; ===================================
; ===================================

global _CHP_Sent := []

_CHP_Record(Payload) {
	global _CHP_Sent
	_CHP_Sent.Push(Payload)
	return true
}

_CHP_ProbePhysical() {
	return true
}

_CHP_ProbeSynthetic() {
	return false
}





; =====================================
; =====================================
; ======= 2/ Behavioural tests ========
; =====================================
; =====================================

_CHP_TestPhysicalCtrlKeepsShortcut() {
	global _CHP_Sent
	_CHP_Sent := []
	Assert(ClipboardHistoryPaste(_CHP_ProbePhysical, _CHP_Record))
	AssertEqual(1, _CHP_Sent.Length,
		"physical Ctrl paste must publish exactly one sender transaction")
	AssertEqual("^v", _CHP_Sent[1],
		"physical Ctrl paste must keep the ordinary shortcut sequence")
}

_CHP_TestSyntheticCtrlOwnsCompleteTransaction() {
	global _CHP_Sent
	_CHP_Sent := []
	Assert(ClipboardHistoryPaste(_CHP_ProbeSynthetic, _CHP_Record))
	AssertEqual(1, _CHP_Sent.Length,
		"clipboard-history paste must publish exactly one sender transaction")
	AssertEqual("{Ctrl up}{Ctrl down}v{Ctrl up}", _CHP_Sent[1],
		"logical-only Ctrl must be replaced by a complete owned Ctrl transaction")
}

Test("clipboard-history paste: physical Ctrl keeps the ordinary shortcut",
	_CHP_TestPhysicalCtrlKeepsShortcut)
Test("clipboard-history paste: synthetic Ctrl owns a complete modifier transaction",
	_CHP_TestSyntheticCtrlOwnsCompleteTransaction)
