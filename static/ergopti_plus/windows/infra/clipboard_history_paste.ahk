; infra/clipboard_history_paste.ahk

; ==============================================================================
; MODULE: Clipboard History Paste
; DESCRIPTION:
; Owns the modifier provenance boundary for the Ergopti Ctrl+SC02F paste route.
; Windows clipboard history can contribute a logical Ctrl edge that is not
; physically held and may be released while AutoHotkey re-emits the shortcut.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Sequence policy =======
; ==================================
; ==================================

ClipboardHistoryPasteSequence(PhysicalCtrlDown) {
	if PhysicalCtrlDown
		return "^v"
	return "{Ctrl up}{Ctrl down}v{Ctrl up}"
}





; ===========================
; ===========================
; ======= 2/ Dispatch =======
; ===========================
; ===========================

ClipboardHistoryPaste(PhysicalCtrlProbe := 0, SendFn := 0) {
	PhysicalCtrlDown := HasMethod(PhysicalCtrlProbe, "Call")
		? !!PhysicalCtrlProbe.Call()
		: GetKeyState("Ctrl", "P")
	Sequence := ClipboardHistoryPasteSequence(PhysicalCtrlDown)
	if HasMethod(SendFn, "Call")
		return SendFn.Call(Sequence)
	return SendFinalResult(Sequence)
}
