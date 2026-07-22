; tests/meta/test_keyboard_hook_vk_format.ahk

; ==============================================================================
; MODULE: Keyboard Hook VK Zero-Padded Hex Format Guard
; DESCRIPTION:
; Static source guard for the VK format {:02X} fix in
; adapters/keyboard_hook.ahk.
;
; ROOT CAUSE ENCODED:
; The original VK code was formatted with {1:X} (or {X}) which produced
; single-character hex for low VK values (e.g. VK 9 became "9" instead of
; "09"). Downstream consumers (the event log, the key-mapper, the corpus
; analyser) that expected two-digit hex strings would misinterpret these
; single-character entries, breaking lookups and comparisons.
;
; The fix changes the format specifier to {:02X} which zero-pads to at least
; two digits. This test confirms the correct specifier is present in the hook
; event construction and the broken single-digit form is absent.
; ==============================================================================

#Requires AutoHotkey v2.0

_TKHVF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TKHVF_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ============================================================
; ============================================================
; ======= 1/ {:02X} format specifier present for VK ==========
; ============================================================
; ============================================================

_TKHVF_ZeroPaddedHex() {
	Src := _TKHVF_StripLineComments(_TKHVF_ReadSource("adapters/keyboard_hook.ahk"))
	Assert(Src != "", "adapters/keyboard_hook.ahk must be readable")

	; The zero-padded two-digit hex format must be used
	Assert(InStr(Src, "{:02X}") > 0,
		"adapters/keyboard_hook.ahk must format VK codes with {:02X} (zero-padded two-digit hex)")

	; The single-digit form must not appear in the VK format call
	; Check that {1:X} (the v1-style single-digit form) is absent
	Assert(InStr(Src, "{1:X}") = 0,
		"adapters/keyboard_hook.ahk must NOT use {1:X} for VK formatting — single-digit hex breaks downstream consumers")
}
Test("keyboard_hook: VK codes formatted with {:02X} (zero-padded), not single-digit {1:X}", _TKHVF_ZeroPaddedHex)
