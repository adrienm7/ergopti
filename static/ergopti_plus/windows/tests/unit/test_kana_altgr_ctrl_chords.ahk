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
; (kana-altgr-ctrl-chord-2026-09-26).
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

_KACC_KeyloggerKeepsKanaCtrlShortcuts() {
	AssertEqual("", KL_Watchers_DetectShortcut(KLHOOK_VK_PACKET, 0),
		"text a Send typed (VK_PACKET) is never a shortcut's payload")
	Body := _DriverFuncBody("KL_Watchers_DetectShortcut")
	AssertTrue(InStr(Body, "if (AltGr and Ctrl and !LAlt and KS_AltGrAddsFakeLCtrl())") > 0,
		"the keylogger must drop a Ctrl+AltGr chord as AltGr typing only where AltGr adds a Ctrl (not on Kana or QWERTY)")
}
Test("kana altgr ctrl: the keylogger keeps a Ctrl+Kana AltGr shortcut (kana-altgr-ctrl-chord-2026-09-26)",
	_KACC_KeyloggerKeepsKanaCtrlShortcuts)
