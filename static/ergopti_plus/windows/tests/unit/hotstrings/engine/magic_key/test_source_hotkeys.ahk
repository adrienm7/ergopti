; tests/unit/hotstrings/engine/magic_key/test_source_hotkeys.ahk

; ==============================================================================
; MODULE: Magic Key Hotkey Tests (Windows)
; DESCRIPTION:
; The magic key is only the configured character (maintainer's decisions of
; 2026-11-21 and 2026-11-22): no hotkey turns any key into it. The replace
; section remapped the key an emulated layout declared ([extension.magic_key])
; to the configured character; before that, a key the user chose, a key
; detected on the OS layout and a modifiers + ★ → modifiers + S save did too.
; ==============================================================================

#Requires AutoHotkey v2.0

Test("magic key: no hotkey remaps any key to the magic key (magic-key-character)",
	_MKH_NoRemapCase)

_MKH_NoRemapCase() {
	Code := _DriverSourceNoComments()
	for Retired in ["LayoutRegistry_MagicKeySource", "LayoutRegistry_MagicKeyHotkeys",
			"LayoutRegistry_DeclaredMagicKey", "HotstringExtensions_MagicKey", "_KLE_MagicKeyOwnsKey",
			"MagicKeySourceScan", "_MagicKeySave", "LayoutRegistry_DetectMagicKeyScan"]
		AssertFalse(InStr(Code, Retired), Retired . " left with the magic key remap")
	AssertFalse(RegExMatch(Code, '\["replace"\]\["enabled"\]'), "no code reads the retired replace section")
	AssertFalse(RegExMatch(Code, '(?:Hotkey|RemapKey)\([^\n]*ScriptInformation\["MagicKey"\]'),
		"no hotkey binds a key to the configured magic key")
}

Test("magic key: the manifest declares no replace section (magic-key-character)", () => (
	AssertFalse(ManifestFindEntryByPath("hotstrings.magic_key.replace") is Map,
		"the J → ★ remap is no feature any more"),
	AssertFalse(ManifestBuildFeaturesMap()["hotstrings"]["magic_key"].Has("replace"))))
