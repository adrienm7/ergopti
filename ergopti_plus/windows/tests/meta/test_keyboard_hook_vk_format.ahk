; tests/meta/test_keyboard_hook_vk_format.ahk

; ==============================================================================
; MODULE: Keyboard Hook Normalized-Key Guard
; DESCRIPTION:
; Static source guard for the shared KeyboardHook normalized-key contract.
;
; ROOT CAUSE ENCODED:
; Hex VK strings are platform-specific and violate KeyboardHook.spec.js, which
; requires names such as Backspace and ArrowLeft. Unknown/printable VK values
; must be filtered from onKey instead of receiving a hex fallback.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ Canonical names replace raw VK formatting =======
; ============================================================
; ============================================================

_TKHVF_ZeroPaddedHex() {
	Normalize := _DriverFuncBody("_KH_NormalizeKey")
	Dispatch := _DriverFuncBody("_KH_DispatchKey")
	Assert(Normalize != "" and Dispatch != "",
		"KeyboardHook normalized-key functions must exist")
	AssertContains(Normalize, 'return "Backspace"')
	AssertContains(Normalize, 'return "ArrowLeft"')
	AssertContains(Normalize, 'return "F" . (VK - 0x6F)')
	AssertContains(Normalize, 'return ""',
		"unknown and printable VK values must have no onKey name")
	AssertFalse(InStr(Dispatch, "Format("),
		"onKey must never fall back to platform-specific hexadecimal VK strings")
	AssertContains(Dispatch, 'if (KeyName = "")',
		"onKey must filter values outside the shared normalized vocabulary")
}
Test("keyboard_hook: onKey uses normalized names, never raw VK hex (keyboard-hook-event-contract)",
	_TKHVF_ZeroPaddedHex)
