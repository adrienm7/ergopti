; static/ergopti_plus/windows/tests/unit/test_text_sender_modifiers.ahk

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

; A single modifier in array form is the form used by the tap actions
; (copy/paste/cut/etc.).  It must use AHK's shortcut prefix syntax too:
; `{Ctrl c}` is not Ctrl+C, while `^{c}` is.
_TSM_SingleModifierArraysKeepShortcutPrefixes() {
	AssertEqual("^{c}", _TSM_Capture("c", ["Ctrl"]),
		"copy tap output must remain Ctrl+C")
	AssertEqual("^{v}", _TSM_Capture("v", ["Ctrl"]),
		"paste tap output must remain Ctrl+V")
	AssertEqual("!{Tab}", _TSM_Capture("Tab", ["Alt"]),
		"single Alt modifier must remain Alt+Tab")
	AssertEqual("+{Tab}", _TSM_Capture("Tab", ["Shift"]),
		"single Shift modifier must remain Shift+Tab")
	AssertEqual("#{a}", _TSM_Capture("a", ["Win"]),
		"single Win modifier must remain Win+A")
}
Test("TextPressKey: single modifier arrays emit valid shortcut prefixes", _TSM_SingleModifierArraysKeepShortcutPrefixes)

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




; ==========================================
; ==========================================
; ======= 4/ Empty-Key guard (F17) =========
; ==========================================
; ==========================================

; Regression for the "unrecognized hold_modifier -> empty ModKey -> unguarded
; SendInput('{ Down}')" bug: a typo'd hold_modifier resolved to "" and was fed
; straight into TextPressKey. TextPressKey must now refuse to send anything
; for an empty Key instead of emitting a blank-key SendInput call.
_TSM_EmptyKeyDownIsRefused() {
	AssertEqual("", _TSM_Capture("", "Down"),
		"TextPressKey('', 'Down') must refuse to send — sending '{ Down}' would silently arm nothing while still consuming the keystroke")
}
Test("TextPressKey: empty Key with 'Down' is refused, not sent as '{ Down}'", _TSM_EmptyKeyDownIsRefused)

_TSM_EmptyKeyUpIsRefused() {
	AssertEqual("", _TSM_Capture("", "Up"),
		"TextPressKey('', 'Up') must refuse to send for the same reason as the Down case")
}
Test("TextPressKey: empty Key with 'Up' is refused, not sent as '{ Up}'", _TSM_EmptyKeyUpIsRefused)

; F16 (audit 2026-07-20): TextPressKey warned "modifier array is empty after
; normalization" whenever Mods came out empty — but an empty INPUT array is the
; shortcuts cluster's documented "no modifiers" convention (TextPressKey(Key, [])),
; so every CapsWord Space/Enter and every backspace/delete/enter/escape/tab action
; spammed the errors log (18x Enter + 2x Tab in one day's real logs). The warn must
; fire only when a NON-empty array had all its tokens fail normalization. Behavioural
; capture cannot see the (unstubbable) LoggerWarn, so assert the source guard.
_TSM_EmptyInputArrayDoesNotWarn() {
	Body := _DriverFuncBody("TextPressKey")
	Assert(Body != "", "TextPressKey must exist in adapters/text_sender.ahk")
	GuardPos := InStr(Body, "if (Modifiers.Length > 0)")
	WarnPos := InStr(Body, "is empty after normalization")
	Assert(WarnPos > 0, "TextPressKey must keep the empty-after-normalization diagnostic for genuinely invalid input")
	Assert(GuardPos > 0 && GuardPos < WarnPos,
		"the empty-after-normalization warning must be gated on Modifiers.Length > 0 so an empty input array (the no-modifiers convention) never logs a WARNING")
	; The bare key must still be emitted for the empty-input case.
	AssertEqual("{Enter}", _TSM_Capture("Enter", []),
		"TextPressKey(Enter, []) must still send a bare {Enter}")
}
Test("TextPressKey: empty input array sends bare key without a WARNING (no errors-log storm)",
	_TSM_EmptyInputArrayDoesNotWarn)
