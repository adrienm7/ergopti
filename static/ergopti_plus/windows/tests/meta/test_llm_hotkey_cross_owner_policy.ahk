; tests/meta/test_llm_hotkey_cross_owner_policy.ahk

; ==============================================================================
; MODULE: LLM Cross-Owner Hotkey Policy Meta Test
; DESCRIPTION:
; Source guard for the raw textual character owners, whose permanent names must
; remain visible after the registrar freezes character hotkeys to explicit VK
; specs. The LLM rescue hotkey (^!+i) is the production one: the clipboard's
; "~^v" was retired for an InputHook paste observer, since a hotkey named by a
; character never fires on the keys the driver declares by scan code.
; ==============================================================================

#Requires AutoHotkey v2.0

_LHCM_TextualCharacterOwnerRemainsVisibleToFrozenAdmission() {
	Assert(RegExMatch(_DriverSourceNoComments(), "m)^[ \t]*\^!\+i::") > 0,
		"the production inventory must retain the raw textual Ctrl+Alt+Shift+I owner")

	ReserveBody := _StripFullLineComments(
		_DriverFuncBody("_HotkeyRegistrarReserveOwned"))
	Assert(ReserveBody != "",
		"the registrar reservation boundary must remain reachable")
	ClaimPos := InStr(ReserveBody, "HOTKEY_REGISTRAR_SPECS[spec] := entry")
	DisplayProbePos := InStr(ReserveBody,
		"_HotkeyRegistrarNativeExists(DisplaySpec")
	FrozenProbePos := InStr(ReserveBody,
		"_HotkeyRegistrarNativeExists(spec")
	InstallPos := InStr(ReserveBody, "_HotkeyRegistrarInvoke(spec")
	Assert(ClaimPos > 0 && DisplayProbePos > ClaimPos
			&& FrozenProbePos > DisplayProbePos && InstallPos > FrozenProbePos,
		"a frozen character claim must probe its textual permanent name before "
		. "the explicit VK name and before any native install")
}

Test("[llm-hotkey-collision] frozen specs still see raw textual owners",
	_LHCM_TextualCharacterOwnerRemainsVisibleToFrozenAdmission)
