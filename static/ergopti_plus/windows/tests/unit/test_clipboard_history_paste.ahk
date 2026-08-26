; static/ergopti_plus/windows/tests/unit/test_clipboard_history_paste.ahk

; ==============================================================================
; MODULE: Clipboard-history LCtrl ownership regression
; DESCRIPTION:
; Windows clipboard history emits LCtrl and its later V as separate injected
; edges after Enter or a click. An identity LCtrl tap-hold must keep the native
; edge instead of replacing it with a synthetic Ctrl that is released first.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Recorder fixture =======
; ===================================
; ===================================

global _CHP_Events := []
global _CHP_Ticks := []

_CHP_Reset() {
	global _CHP_Events, _CHP_Ticks
	_CHP_Events := []
	_CHP_Ticks := [1000, 1010]
}

_CHP_Record(Label) {
	global _CHP_Events
	_CHP_Events.Push(Label)
	return true
}

_CHP_Wait(KeyName, TimeoutSec) {
	return _CHP_Record("wait:" . KeyName)
}

_CHP_KeyIsDown(KeyName) {
	_CHP_Record("down-state:" . KeyName)
	return false
}

_CHP_Tick() {
	global _CHP_Ticks
	return _CHP_Ticks.RemoveAt(1)
}

_CHP_Down(KeyName) {
	return _CHP_Record("synthetic-down:" . KeyName)
}

_CHP_Up(KeyName) {
	return _CHP_Record("synthetic-up:" . KeyName)
}

_CHP_Cancel(KeyId, GuardMs) {
	_CHP_Record("cancel:" . KeyId)
	return ""
}

_CHP_JoinedEvents() {
	global _CHP_Events
	Joined := ""
	for _, Event in _CHP_Events
		Joined .= (Joined == "" ? "" : "|") . Event
	return Joined
}





; =====================================
; =====================================
; ======= 2/ Behavioural tests ========
; =====================================
; =====================================

_CHP_NativeLCtrlKeepsWindowsEdge() {
	_CHP_Reset()
	Result := TapHoldOwnImmediateModifier("left_ctrl", "SC01D", "LCtrl", 0.2,
		_CHP_Wait, _CHP_KeyIsDown, _CHP_Tick, _CHP_Down, _CHP_Up, _CHP_Cancel, true)
	Assert(Result["released"], "the native LCtrl release must settle")
	AssertEqual("wait:SC01D|cancel:left_ctrl", _CHP_JoinedEvents(),
		"native LCtrl must remain pass-through until Windows delivers the later V; a synthetic Down/Up pair releases Ctrl too early")
}

_CHP_RemappedLCtrlStillOwnsSyntheticModifier() {
	_CHP_Reset()
	Result := TapHoldOwnImmediateModifier("left_ctrl", "SC01D", "LShift", 0.2,
		_CHP_Wait, _CHP_KeyIsDown, _CHP_Tick, _CHP_Down, _CHP_Up, _CHP_Cancel, false)
	Assert(Result["released"], "the remapped LCtrl release must settle")
	AssertEqual("synthetic-down:LShift|wait:SC01D|synthetic-up:LShift|cancel:left_ctrl",
		_CHP_JoinedEvents(),
		"a non-native LCtrl hold must retain its paired synthetic modifier owner")
}

Test("clipboard-history paste: native LCtrl keeps the Windows modifier edge (clipboard-history-lctrl-passthrough)",
	_CHP_NativeLCtrlKeepsWindowsEdge)
Test("clipboard-history paste: remapped LCtrl retains synthetic ownership (clipboard-history-lctrl-passthrough)",
	_CHP_RemappedLCtrlStillOwnsSyntheticModifier)
