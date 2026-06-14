; static/ergopti_plus/windows/tests/test_text_sender_modifiers.ahk

; ==============================================================================
; MODULE: TextPressKey Modifier-String Regression Tests
; DESCRIPTION:
; Locks the modifier handling of TextPressKey (adapters/text_sender.ahk).
;
; Regression guard for the "string modifiers silently dropped" bug: TextPressKey
; handled only the "Down"/"Up" strings and the Array form. Any space-delimited
; modifier STRING ("Shift", "Ctrl Shift", "Blind", "Ctrl") fell through with an
; empty prefix and the BARE key was emitted — so back-Tab became a forward Tab
; and Ctrl+BackSpace word-delete degraded to a single delete. Dozens of tap-hold
; / gesture call sites (rctrl.ahk, tab.ahk, capslock.ahk, lalt.ahk) pass exactly
; this form. The fix adds a string branch; these tests assert the emitted payload.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 1/ Capture helper ================
; ==========================================
; ==========================================

; Temporarily swaps _AHK_SendInput for a capturing lambda, calls TextPressKey,
; restores the original primitive and returns the captured payload string.
_TSM_Capture(Key, Modifiers) {
	global _AHK_SendInput
	Prev := _AHK_SendInput
	Box := { val: "" }
	_AHK_SendInput := (Keys) => (Box.val := Keys)
	TextPressKey(Key, Modifiers)
	_AHK_SendInput := Prev
	return Box.val
}




; ==========================================
; ==========================================
; ======= 2/ String-modifier branch ========
; ==========================================
; ==========================================

_TSM_ShiftString() {
	AssertEqual("+{Tab}", _TSM_Capture("Tab", "Shift"),
		"TextPressKey(Tab, 'Shift') must emit +{Tab}, not a bare {Tab}")
}
Test("TextPressKey: 'Shift' string modifier -> +{Tab}", _TSM_ShiftString)

_TSM_CtrlShiftString() {
	AssertEqual("^+{Tab}", _TSM_Capture("Tab", "Ctrl Shift"),
		"TextPressKey(Tab, 'Ctrl Shift') must emit ^+{Tab}")
}
Test("TextPressKey: 'Ctrl Shift' string modifier -> ^+{Tab}", _TSM_CtrlShiftString)

_TSM_CtrlString() {
	AssertEqual("^{Delete}", _TSM_Capture("Delete", "Ctrl"),
		"TextPressKey(Delete, 'Ctrl') must emit ^{Delete}")
}
Test("TextPressKey: 'Ctrl' string modifier -> ^{Delete}", _TSM_CtrlString)

_TSM_BlindString() {
	Val := _TSM_Capture("BackSpace", "Blind")
	Assert(InStr(Val, "Blind") > 0, "Blind must be preserved so the held modifier survives")
	AssertEqual("{Blind}{BackSpace}", Val, "TextPressKey(BackSpace, 'Blind') must emit {Blind}{BackSpace}")
}
Test("TextPressKey: 'Blind' string modifier -> {Blind}{BackSpace}", _TSM_BlindString)





; ==========================================
; ===========================================
; ======= 3/ Existing forms unchanged =======
; ===========================================
; ==========================================

_TSM_ArrayFormStillWorks() {
	AssertEqual("^+{Tab}", _TSM_Capture("Tab", ["Ctrl", "Shift"]),
		"Array modifier form must keep working")
}
Test("TextPressKey: array modifier form unchanged", _TSM_ArrayFormStillWorks)

_TSM_EmptyStringIsBareKey() {
	AssertEqual("{Tab}", _TSM_Capture("Tab", ""),
		"Empty modifier string must emit the bare key (the common correct-by-accident case)")
}
Test("TextPressKey: empty modifier string -> bare key", _TSM_EmptyStringIsBareKey)

_TSM_DownStillSustained() {
	AssertEqual("{LCtrl Down}", _TSM_Capture("LCtrl", "Down"),
		"Down must still emit a sustained key-down event")
}
Test("TextPressKey: 'Down' still emits a sustained press", _TSM_DownStillSustained)
