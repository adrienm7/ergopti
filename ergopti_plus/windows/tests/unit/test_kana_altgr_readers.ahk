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
; AltGrHeld is whether the layout's AltGr key reads logically down.
_KAR_WithLayout(Kana, Body, AltGrHeld := false) {
	global _AHK_SendInput, _KAR_Sent, _TextSenderKeyIsDown
	SavedFamily := _TestSetAltGrFamily(Kana)
	SavedSend := _AHK_SendInput
	SavedKeyIsDown := _TextSenderKeyIsDown
	_KAR_Sent := []
	_AHK_SendInput := (Keys) => _KAR_Sent.Push(Keys)
	_TextSenderKeyIsDown := (Name) => AltGrHeld and Name == KS_AltGrKeyName()
	try
		Body.Call()
	finally {
		_TestRestoreAltGrFamily(SavedFamily)
		_AHK_SendInput := SavedSend
		_TextSenderKeyIsDown := SavedKeyIsDown
	}
}

_KAR_TextSenderAltGrPressesTheKanaKey() {
	global _KAR_Sent
	_KAR_WithLayout(true, () => TextPressKey("e", "AltGr"))
	AssertEqual(1, _KAR_Sent.Length, "one keystroke must be sent")
	AssertEqual("{vkDF down}{e}{vkDF up}", _KAR_Sent[1],
		"on a Kana-style layout AltGr is the layout's AltGr key, by its virtual key; <^>! is Ctrl+Alt there")
	_KAR_WithLayout(true, () => TextPressKey("e", ["Shift", "AltGr"]))
	AssertEqual("{vkDF down}+{e}{vkDF up}", _KAR_Sent[1],
		"the array form must hold the same AltGr key around the other modifiers")
}
Test("kana altgr: the TextSender altgr modifier presses the Kana AltGr key (kana-altgr-readers-2026-09-25)",
	_KAR_TextSenderAltGrPressesTheKanaKey)

; AutoHotkey's Send reads a bare "SC138" as the right Alt modifier while it
; injects the layout's VK_OEM_8, which is no modifier, so the keystroke went out
; with a real right Alt added, a plain Alt on that layout: an Alt chord, no AltGr
; character (kana-altgr-send-name-2026-09-26). No payload may name it so.
_KAR_NoKanaPayloadNamesTheScanCode() {
	global _KAR_Sent
	for _, Mods in ["AltGr", ["AltGr"], ["Shift", "AltGr"], "Blind AltGr"] {
		_KAR_WithLayout(true, TextPressKey.Bind("e", Mods))
		AssertEqual(1, _KAR_Sent.Length, "one keystroke must be sent")
		AssertFalse(RegExMatch(_KAR_Sent[1], "i)\{SC138 (down|up)\}") > 0,
			"a Kana AltGr keystroke must never press SC138 by its scan code: " . _KAR_Sent[1])
	}
}
Test("kana altgr: no AltGr keystroke names the Kana key by its scan code (kana-altgr-send-name-2026-09-26)",
	_KAR_NoKanaPayloadNamesTheScanCode)

; The send name is the virtual key the boot probe read for the AltGr scan code;
; without one there is nothing safe to send, and the press is refused loudly.
_KAR_SendNameComesFromTheProbe() {
	global _KAR_Sent, _ALTGR_LAYOUT_PROBE
	_KAR_WithLayout(true, () => AssertEqual("vkDF", KS_AltGrSendKey(), "the Kana AltGr is sent by the layout's virtual key"))
	_KAR_WithLayout(false, () => AssertEqual("RAlt", KS_AltGrSendKey(), "a standard layout's AltGr is RAlt"))
	_KAR_WithLayout(true, () => (
		_ALTGR_LAYOUT_PROBE["altgr_vk"] := 0,
		AssertFalse(TextPressKey(KS_AltGrKeyName(), "Down", false), "a Kana AltGr with no virtual key must not be pressed"),
		AssertEqual(0, _KAR_Sent.Length, "nothing must be sent in its place")))
}
Test("kana altgr: the AltGr send name comes from the boot probe (kana-altgr-send-name-2026-09-26)",
	_KAR_SendNameComesFromTheProbe)

; A press of the AltGr key built from its identity (KS_AltGrKeyName, "SC138" on
; a Kana layout) anywhere in the driver re-opens the stuck right Alt; presses go
; through TextPressKey, which names the key by KS_AltGrSendKey.
_KAR_NoDriverPressBuiltFromTheIdentity() {
	Src := _DriverSourceNoComments()
	Assert(StrLen(Src) > 100000, "the driver source must be readable")
	Found := RegExMatch(Src, 'i)KS_AltGrKeyName\(\)\s*\.?\s*"\s+down\}|\{SC138 down\}', &Match)
	AssertEqual(0, Found, "no Send may press the AltGr key by its identity: " . (Found ? Match[0] : ""))
	Body := _DriverFuncBody("_TextSenderSustainedKey")
	AssertTrue(InStr(Body, "KS_AltGrSendKey()") > 0 and InStr(Body, "{Blind}") > 0,
		"a sustained AltGr Down/Up must be sent by its virtual key, blind")
}
Test("kana altgr: no driver Send presses the AltGr key by its identity (kana-altgr-send-name-2026-09-26)",
	_KAR_NoDriverPressBuiltFromTheIdentity)

; An AltGr the user or a tap-hold already holds must survive the keystroke: the
; wrap's release ended that hold (kana-altgr-held-keystroke-2026-09-26).
_KAR_HeldKanaAltGrIsNotWrapped() {
	global _KAR_Sent
	_KAR_WithLayout(true, () => TextPressKey("e", "AltGr"), true)
	AssertEqual("{e}", _KAR_Sent[1], "a held Kana AltGr already modifies the keystroke and must not be released")
	_KAR_WithLayout(true, () => TextPressKey("e", "Blind AltGr"), true)
	AssertEqual("{Blind}{e}", _KAR_Sent[1], "the blind form must leave the held AltGr alone too")
}
Test("kana altgr: a held Kana AltGr survives an AltGr keystroke (kana-altgr-held-keystroke-2026-09-26)",
	_KAR_HeldKanaAltGrIsNotWrapped)

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
	Readers := ["_HealthCheck_Input", "AwakeIsIgnoredModifierKey", "AwakeCancelOnKeypress",
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
