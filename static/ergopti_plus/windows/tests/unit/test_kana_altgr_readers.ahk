; tests/unit/test_kana_altgr_readers.ahk

; ==============================================================================
; MODULE: Every AltGr reader follows the layout's AltGr key
; DESCRIPTION:
; On a Kana-style layout VK_RMENU has no scan code: RAlt is a plain Alt, and
; the AltGr key is SC138 under another virtual key (KS_AltGrKeyName). Readers
; that still named RAlt, vk 0xA5 or "<^>!" as AltGr were wrong there: the
; TextSender "altgr" modifier typed Ctrl+Alt (and its array form a plain Alt on
; every layout), the health check reported AltGr off while it was held, a bare
; AltGr press cancelled keep-awake, and the keylogger counted the AltGr key as
; a character key (kana-altgr-readers-2026-09-25).
; ==============================================================================

#Requires AutoHotkey v2.0

global _KAR_Sent := []

; Run Body on a standard (Kana false) or Kana-style (Kana true) layout with the
; SendInput primitive recorded.
_KAR_WithLayout(Kana, Body) {
	global _ALTGR_KANA_FIXUP, _AHK_SendInput, _KAR_Sent
	SavedKana := _ALTGR_KANA_FIXUP
	SavedSend := _AHK_SendInput
	_KAR_Sent := []
	_ALTGR_KANA_FIXUP := Kana
	_AHK_SendInput := (Keys) => _KAR_Sent.Push(Keys)
	try
		Body.Call()
	finally {
		_ALTGR_KANA_FIXUP := SavedKana
		_AHK_SendInput := SavedSend
	}
}

_KAR_TextSenderAltGrPressesTheKanaKey() {
	global _KAR_Sent
	_KAR_WithLayout(true, () => TextPressKey("e", "AltGr"))
	AssertEqual(1, _KAR_Sent.Length, "one keystroke must be sent")
	AssertEqual("{SC138 down}{e}{SC138 up}", _KAR_Sent[1],
		"on a Kana-style layout AltGr is the SC138 key; <^>! is Ctrl+Alt there")
	_KAR_WithLayout(true, () => TextPressKey("e", ["Shift", "AltGr"]))
	AssertEqual("{SC138 down}+{e}{SC138 up}", _KAR_Sent[1],
		"the array form must hold the same AltGr key around the other modifiers")
}
Test("kana altgr: the TextSender altgr modifier presses the Kana AltGr key (kana-altgr-readers-2026-09-25)",
	_KAR_TextSenderAltGrPressesTheKanaKey)

_KAR_TextSenderAltGrOnAStandardLayout() {
	global _KAR_Sent
	_KAR_WithLayout(false, () => TextPressKey("e", "AltGr"))
	AssertEqual("<^>!{e}", _KAR_Sent[1], "a standard layout's AltGr is LCtrl+RAlt")
	_KAR_WithLayout(false, () => TextPressKey("e", ["AltGr"]))
	AssertEqual("<^>!{e}", _KAR_Sent[1],
		"the array form must not degrade AltGr to a plain Alt")
}
Test("kana altgr: the TextSender altgr modifier is AltGr on a standard layout (kana-altgr-readers-2026-09-25)",
	_KAR_TextSenderAltGrOnAStandardLayout)

_KAR_AltGrScanCodeIsTheLayoutKey() {
	_KAR_WithLayout(true, () => AssertEqual(0x138, KS_AltGrScanCode(),
		"the Kana AltGr key is SC138"))
}
Test("kana altgr: the AltGr scan code comes from the layout's AltGr key (kana-altgr-readers-2026-09-25)",
	_KAR_AltGrScanCodeIsTheLayoutKey)

_KAR_KanaAltGrDoesNotCancelKeepAwake() {
	global ActivitySimulation
	ActivitySimulation := true
	try {
		; VK_OEM_8 is one of the virtual keys a Kana-style layout gives AltGr.
		_KAR_WithLayout(true, () => AwakeCancelOnKeypress(InputHook(), 0xDF, 0x138))
		AssertTrue(ActivitySimulation,
			"a bare AltGr press is a modifier and must not cancel keep-awake, whatever virtual key the layout gives it")
		_KAR_WithLayout(true, () => AwakeCancelOnKeypress(InputHook(), 0x41, 0x1E))
		AssertFalse(ActivitySimulation, "a character key must still cancel keep-awake")
	} finally {
		ActivitySimulation := false
	}
}
Test("kana altgr: a bare Kana AltGr press does not cancel keep-awake (kana-altgr-readers-2026-09-25)",
	_KAR_KanaAltGrDoesNotCancelKeepAwake)

; The readers that decide from key state or key events whether AltGr is
; involved. Each must name the layout's AltGr key, never RAlt or vk 0xA5 alone.
_KAR_EveryAltGrReaderUsesTheLayoutKey() {
	Readers := ["_HealthCheck_LayoutState", "AwakeIsIgnoredModifierKey", "AwakeCancelOnKeypress",
		"KL_Ergo_UpdatePinky", "KL_Watchers_DetectShortcut", "_CrashReport_StuckModifiers",
		"_TextSenderKeystroke"]
	for _, Name in Readers {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist")
		Assert(InStr(Body, "KS_AltGr") > 0,
			Name . " must identify AltGr through KS_AltGrKeyName or KS_AltGrScanCode, not RAlt")
		Assert(!InStr(Body, 'GetKeyState("RAlt"'),
			Name . " must not read RAlt as AltGr: a Kana-style layout's AltGr is SC138")
	}
}
Test("kana altgr: every AltGr reader names the layout's AltGr key (kana-altgr-readers-2026-09-25)",
	_KAR_EveryAltGrReaderUsesTheLayoutKey)
