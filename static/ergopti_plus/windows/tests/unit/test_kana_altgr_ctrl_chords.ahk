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

_KACC_AltGrMasksCtrlOnlyWhereItAddsOne() {
	AssertTrue(_PrefixAltGrMasksCtrl(false, true, false), "standard layout: RAlt held means the Ctrl is AltGr's fake LCtrl")
	AssertTrue(_PrefixAltGrMasksCtrl(false, false, true), "standard layout: the AltGr key held means the same")
	AssertFalse(_PrefixAltGrMasksCtrl(false, false, false), "no AltGr held: the Ctrl is the user's")
	AssertFalse(_PrefixAltGrMasksCtrl(true, false, true), "Kana layout: the AltGr key adds no Ctrl, a held Ctrl is the user's")
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	AssertTrue(InStr(Body, "AltGrHeld := _PrefixAltGrMasksCtrl(") > 0,
		"the live prefix watcher must decide through _PrefixAltGrMasksCtrl")
}
Test("kana altgr ctrl: the Kana AltGr does not mask a real Ctrl chord (kana-altgr-ctrl-chord-2026-09-26)",
	_KACC_AltGrMasksCtrlOnlyWhereItAddsOne)

_KACC_KeyloggerKeepsKanaCtrlShortcuts() {
	AssertEqual("", KL_Watchers_DetectShortcut(KLHOOK_VK_PACKET, 0),
		"text a Send typed (VK_PACKET) is never a shortcut's payload")
	Body := _DriverFuncBody("KL_Watchers_DetectShortcut")
	AssertTrue(InStr(Body, "if (AltGr and Ctrl and !LAlt and !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP))") > 0,
		"the keylogger must drop a Ctrl+AltGr chord as AltGr typing only where AltGr adds a Ctrl")
}
Test("kana altgr ctrl: the keylogger keeps a Ctrl+Kana AltGr shortcut (kana-altgr-ctrl-chord-2026-09-26)",
	_KACC_KeyloggerKeepsKanaCtrlShortcuts)
