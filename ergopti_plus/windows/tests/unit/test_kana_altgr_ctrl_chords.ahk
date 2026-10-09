; tests/unit/test_kana_altgr_ctrl_chords.ahk

; ==============================================================================
; MODULE: A Ctrl held with the Kana AltGr is the user's Ctrl
; DESCRIPTION:
; On a standard AltGr layout Windows adds a fake LCtrl to every AltGr press, so
; the hotstring watcher and the keylogger treat a Ctrl held with AltGr as
; AltGr typing a character. A Kana-style AltGr (SC138 on VK_OEM_8) adds no
; Ctrl: Ctrl+AltGr+V (with the AltGr layer off) pasted while the hotstring
; buffers kept a context no longer on screen, so a later expansion could
; backspace over the pasted text, and the keylogger dropped the shortcut
; (kana-altgr-ctrl-chord-2026-09-26). QWERTY's right Alt adds no Ctrl either,
; and it is the Alt of the chord the application receives.
; ==============================================================================

#Requires AutoHotkey v2.0

; Whether a Ctrl held with the right Alt (RAltDown) or the AltGr key
; (AltGrKeyDown) is masked as AltGr's own on layout Family.
_KACC_Masks(Family, RAltDown, AltGrKeyDown) {
	Saved := _TestSetAltGrFamily(Family == "kana", Family == "standard")
	try
		return _PrefixAltGrMasksCtrl(RAltDown, AltGrKeyDown)
	finally
		_TestRestoreAltGrFamily(Saved)
}

; QWERTY adds no fake LCtrl either: its right Alt is a plain Alt, so a real
; Ctrl+RAlt+V is the user's Ctrl chord and must reset the hotstring context
; (qwerty-user-lctrl-2026-09-26).
_KACC_AltGrMasksCtrlOnlyWhereItAddsOne() {
	AssertTrue(_KACC_Masks("standard", true, false), "standard layout: RAlt held means the Ctrl is AltGr's fake LCtrl")
	AssertTrue(_KACC_Masks("standard", false, true), "standard layout: the AltGr key held means the same")
	AssertFalse(_KACC_Masks("standard", false, false), "no AltGr held: the Ctrl is the user's")
	AssertFalse(_KACC_Masks("kana", false, true), "Kana layout: the AltGr key adds no Ctrl, a held Ctrl is the user's")
	AssertFalse(_KACC_Masks("qwerty", true, false), "QWERTY: right Alt is a plain Alt, a Ctrl held with it is the user's")
	AssertFalse(_KACC_Masks("qwerty", false, true), "QWERTY: the same through the SC138 state")
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	AssertTrue(InStr(Body, 'AltGrHeld := _PrefixAltGrMasksCtrl(KS_IsDown("RAlt"), KS_IsDown("SC138"))') > 0,
		"the live prefix watcher must decide through _PrefixAltGrMasksCtrl")
}
Test("kana altgr ctrl: the Kana AltGr does not mask a real Ctrl chord (kana-altgr-ctrl-chord-2026-09-26)",
	_KACC_AltGrMasksCtrlOnlyWhereItAddsOne)

; The keylogger's shortcut label for V (vk 0x56, sc 0x2F) pressed while exactly
; the keys named in Down are physically held, on layout Family, with the alt_gr
; tap-hold holding Hold ("" for no alt_gr tap-hold).
_KACC_Label(Family, Hold, Down*) {
	global TapHold
	Held := Map()
	for _, Name in Down
		Held[Name] := true
	Keys := Map()
	if (Hold != "")
		Keys["alt_gr"] := Map("tap_action", "tab", "time_activation_seconds", 0.2, "hold_modifier", Hold)
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(Family == "kana", Family == "standard") }
	try {
		TapHold := Map("keys", Keys, "layers", Map())
		return KL_Watchers_DetectShortcut(0x56, 0x2F, (Name) => Held.Has(Name))
	} finally {
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}

_KACC_KeyloggerKeepsKanaCtrlShortcuts() {
	AssertEqual("", KL_Watchers_DetectShortcut(KLHOOK_VK_PACKET, 0),
		"text a Send typed (VK_PACKET) is never a shortcut's payload")
	AssertEqual("Ctrl+V", _KACC_Label("kana", "", "LControl", "SC138"),
		"Kana layout: the AltGr key adds no Ctrl, so Ctrl held with it is the user's shortcut")
	AssertEqual("", _KACC_Label("kana", "", "SC138"), "Kana layout: the AltGr key alone types, it is no shortcut")
	AssertEqual("", _KACC_Label("standard", "", "LControl", "RAlt"),
		"standard layout: the LCtrl held with RAlt is AltGr's fake LCtrl, AltGr+V types a character")
	AssertEqual("Ctrl+Alt+V", _KACC_Label("standard", "", "LControl", "LAlt", "RAlt"),
		"standard layout: LAlt held with AltGr makes the chord a real Ctrl+Alt shortcut")
	AssertEqual("Ctrl+V", _KACC_Label("standard", "", "LControl"), "standard layout: a Ctrl chord without AltGr")
}
Test("kana altgr ctrl: the keylogger keeps a Ctrl+Kana AltGr shortcut (kana-altgr-ctrl-chord-2026-09-26)",
	_KACC_KeyloggerKeepsKanaCtrlShortcuts)

; On QWERTY the AltGr key is a plain right Alt (the boot probe finds no AltGr
; level): a key the AltGr layer leaves alone reaches the application under
; that Alt, so LCtrl+RAlt+V is Windows' Ctrl+Alt+V. The keylogger recorded it
; as Ctrl+V, and RAlt+V not at all (qwerty-keylogger-ralt-alt-2026-09-27).
; Held as another modifier by its tap-hold, the key is suppressed and the
; application never sees that Alt.
_KACC_KeyloggerCountsQwertyRightAlt() {
	AssertEqual("Ctrl+Alt+V", _KACC_Label("qwerty", "", "LControl", "RAlt"),
		"QWERTY: LCtrl+RAlt+V is Windows' Ctrl+Alt+V")
	AssertEqual("Alt+V", _KACC_Label("qwerty", "", "RAlt"), "QWERTY: RAlt+V is an Alt shortcut")
	AssertEqual("Alt+Shift+V", _KACC_Label("qwerty", "", "RAlt", "RShift"), "QWERTY: RAlt+Shift+V keeps both modifiers")
	AssertEqual("Ctrl+Alt+V", _KACC_Label("qwerty", "", "LControl", "LAlt", "RAlt"),
		"QWERTY: both Alts held count as one Alt")
	AssertEqual("Alt+V", _KACC_Label("qwerty", "alt_gr", "RAlt"),
		"QWERTY: AltGr held as itself passes the right Alt through")
	AssertEqual("", _KACC_Label("qwerty", "ctrl", "RAlt"),
		"QWERTY: AltGr held as Ctrl by its tap-hold is no Alt the application sees")
}
Test("kana altgr ctrl: the keylogger counts QWERTY's right Alt as Alt (qwerty-keylogger-ralt-alt-2026-09-27)",
	_KACC_KeyloggerCountsQwertyRightAlt)
