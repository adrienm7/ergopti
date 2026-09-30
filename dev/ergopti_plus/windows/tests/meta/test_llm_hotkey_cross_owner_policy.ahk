; tests/meta/test_llm_hotkey_cross_owner_policy.ahk

; ==============================================================================
; MODULE: LLM Cross-Owner Hotkey Policy Meta Test
; DESCRIPTION:
; Source guard for the raw clipboard owner, whose textual permanent name must
; remain visible after the registrar freezes character hotkeys to explicit VK
; specs.
; ==============================================================================

#Requires AutoHotkey v2.0

_LHCM_TextualClipboardOwnerRemainsVisibleToFrozenAdmission() {
	ClipboardBody := _StripFullLineComments(_DriverFuncBody("KL_Clip_Start"))
	Assert(ClipboardBody != "",
		"the raw clipboard hotkey producer must remain reachable")
	Assert(RegExMatch(ClipboardBody,
		'is)Hotkey\(\s*"~\^v"\s*,\s*KL_Clip_OnPasteHK\s*,\s*"On"\s*\)') > 0,
		"the production inventory must retain the raw textual Ctrl+V owner")

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
	_LHCM_TextualClipboardOwnerRemainsVisibleToFrozenAdmission)
