; tests/unit/test_magic_key_source_hotkeys.ahk

; ==============================================================================
; MODULE: Physical Magic Key Hotkey Tests (Windows)
; DESCRIPTION:
; The magic key's hotkeys were registered one way for every source key: RemapKey
; on the key's scan code with the source character ("j"), which binds every
; level of it (*SC → {Blind}j, ^SC, !SC, #SC), plus Ctrl+★ → Ctrl+S. The
; editor action belongs to an ordinary user-owned slot. The layout's own
; magic-key position has J on Shift. A key the user chose from the Layout menu is some other key
; of their layout: with Semicolon chosen, Shift+; typed "J", and with KeyV chosen
; Ctrl+V sent Ctrl+J, or Ctrl+S with ctrl_magic_save on. These cases pin the
; plan layout.ahk registers.
; ==============================================================================

#Requires AutoHotkey v2.0

Test("magic key source: a chosen key gives the magic key its plain press only (magic-key-source)",
	_MKH_ChosenKeyCase)

_MKH_ChosenKeyCase() {
	for CtrlSave in [false, true] {
		Hotkeys := LayoutRegistry_MagicKeyHotkeys("SC027", true, CtrlSave)
		AssertEqual(1, Hotkeys.Length, "one hotkey, whatever ctrl_magic_save says")
		AssertEqual("magic", Hotkeys[1]["kind"],
			"no RemapKey: its *SC027 → {Blind}j made Shift+; type J")
		AssertEqual("SC027", Hotkeys[1]["hotkey"],
			"the plain press, neither a wildcard nor a chord: Shift, AltGr and Ctrl keep the layout's")
	}
}

Test("magic key source: the layout's own key keeps its levels and Ctrl+S without an editor chord (magic-key-source)",
	_MKH_LayoutKeyCase)

_MKH_LayoutKeyCase() {
	AssertEqual("remap SC02E, ctrl_save ^SC02E",
		_MKH_Describe(LayoutRegistry_MagicKeyHotkeys("SC02E", false, true)))
	AssertEqual("remap SC02E",
		_MKH_Describe(LayoutRegistry_MagicKeyHotkeys("SC02E", false, false)))
}

_MKH_Describe(Hotkeys) {
	Text := ""
	for Index, Entry in Hotkeys
		Text .= (Index > 1 ? ", " : "") . Entry["kind"] . " " . Entry["hotkey"]
	return Text
}

Test("magic key source: layout.ahk registers the magic key through its plan (magic-key-source)",
	_MKH_RegistrationCase)

_MKH_RegistrationCase() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Code := _StripFullLineComments(FileRead(WindowsDir . "\modules\keymap\layout.ahk", "UTF-8"))
	Assert(InStr(Code, 'LayoutRegistry_MagicKeyHotkeys(ScriptInformation["MagicKeySourceScan"],') > 0,
		"the magic key's hotkeys come from LayoutRegistry_MagicKeyHotkeys")
	Assert(InStr(Code, 'ScriptInformation["MagicKeySourceChosen"]') > 0,
		"the plan knows whether the user chose the key")
	Assert(!RegExMatch(Code, "(?:RemapKey|Hotkey)\([^)\n]*MagicKeySourceScan"),
		"no hotkey is bound to the source scan code outside the plan")
}
