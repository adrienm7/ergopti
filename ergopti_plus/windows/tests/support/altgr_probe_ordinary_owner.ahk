; tests/support/altgr_probe_ordinary_owner.ahk

; ==============================================================================
; MODULE: Native AltGr Probe Ordinary Suffix Admission
; DESCRIPTION:
; Keeps the competing ordinary owner on its asserted SC138 suffix. The unrelated
; Ctrl prefix must reach the system rather than an unobserved ordinary callback.
; ==============================================================================

#Requires AutoHotkey v2.0

_KCT_ProbeOrdinaryOwner(HotkeyName, Focused) {
	return Focused && RegExMatch(HotkeyName, "i)^\*?SC138$") != 0
}
