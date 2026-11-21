; tests/unit/hotstrings/engine/magic_key/test_source_hotkeys.ahk

; ==============================================================================
; MODULE: Magic Key Hotkey Tests (Windows)
; DESCRIPTION:
; The magic key is a configured character (maintainer's decision of
; 2026-11-21). The only key layout.ahk remaps is the one the emulated layout
; declares, and only its plain press: the old plan bound every level of it
; through RemapKey with a source character, plus a modifiers + ★ → modifiers +
; S save on every chord, and a key the user chose from the Layout menu.
; ==============================================================================

#Requires AutoHotkey v2.0

Test("magic key: layout.ahk registers only the declared key's plain press (magic-key-character)",
	_MKH_RegistrationCase)

_MKH_RegistrationCase() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Code := _StripFullLineComments(FileRead(WindowsDir . "\modules\keymap\layout.ahk", "UTF-8"))
	Assert(InStr(Code, 'LayoutRegistry_MagicKeyHotkeys(ScriptInformation["MagicKeySourceScan"])') > 0,
		"the magic key's hotkeys come from LayoutRegistry_MagicKeyHotkeys")
	Assert(!RegExMatch(Code, "(?:RemapKey)\([^)\n]*MagicKeySource"),
		"the declared key is no RemapKey: Shift, AltGr and the chords stay the emulated layout's")
	Assert(!InStr(Code, "_MagicKeySave") && !InStr(Code, "CTRL_MAGIC_SAVE"),
		"no modifiers + ★ → modifiers + S save is registered")
	Assert(!InStr(Code, "MagicKeySourceChosen") && !InStr(Code, "MagicKeySourceChar"),
		"no key chosen by the user nor detected on the OS layout")
}

Test("magic key: the boot resolves the source from the emulated layout's declaration alone (magic-key-character)",
	_MKH_BootCase)

_MKH_BootCase() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Code := _StripFullLineComments(FileRead(WindowsDir . "\ErgoptiPlus.ahk", "UTF-8"))
	AssertFalse(InStr(Code, "LayoutRegistry_DetectMagicKeyScan"), "the OS layout is never probed for a source character")
	AssertFalse(InStr(Code, "LayoutRegistry_ShippedMagicKey"), "the shipped position is no fallback")
	AssertFalse(InStr(Code, "magic_key_save.ahk"), "the save rule is not included")
}
