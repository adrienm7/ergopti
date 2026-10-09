; static/ergopti_plus/windows/tests/meta/test_clipboard_history_paste_wiring.ahk

; ==============================================================================
; MODULE: Clipboard-history LCtrl wiring regression
; DESCRIPTION:
; The behavioural test proves the common owner's pass-through mode. This source
; guard proves the active LCtrl identity hotkey selects that mode, which is the
; wiring that previously released Windows' injected Ctrl before its delayed V.
; ==============================================================================

#Requires AutoHotkey v2.0

_ClipboardHistoryPasteLCtrlUsesNativePassthrough() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")
	Gate := '#HotIf _LCtrlHoldModKey() == "LCtrl"'
	GatePos := InStr(Src, Gate)
	Assert(GatePos > 0,
		"identity LCtrl must have a dedicated native pass-through gate")
	Variant := SubStr(Src, GatePos, 700)
	Assert(InStr(Variant, "~*$SC01D:: _LCtrlHandleHold(true)") > 0,
		"the LCtrl identity variant must preserve Windows' Ctrl edge and tell the common owner not to reinject it")
	Body := _DriverFuncBody("_LCtrlHandleHold")
	Assert(Body != "", "_LCtrlHandleHold must exist in the driver source")
	Assert(InStr(Body, "PhysicalModifierPassthrough") > 0,
		"the shared LCtrl handler must forward its native-pass-through verdict")
}

Test("clipboard-history paste: LCtrl wiring preserves the Windows modifier edge (clipboard-history-lctrl-passthrough)",
	_ClipboardHistoryPasteLCtrlUsesNativePassthrough)
