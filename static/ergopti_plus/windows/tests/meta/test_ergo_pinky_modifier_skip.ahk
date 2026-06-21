; tests/meta/test_ergo_pinky_modifier_skip.ahk

; ==============================================================================
; MODULE: KL_Ergo_UpdatePinky Modifier VK Early Return Guard
; DESCRIPTION:
; Static source guard for the modifier-VK early-return fix in
; modules/keylogger/keylogger_ergonomics.ahk.
;
; ROOT CAUSE ENCODED:
; KL_Ergo_UpdatePinky tracks consecutive same-pinky keypresses to detect pinky
; overload. Modifier keys (Shift, Ctrl, Alt, Win) held while typing are not
; physical pinky presses in the ergonomic sense and should not count toward the
; streak. Without the early return, every modifier keystroke incremented the
; pinky run counter, causing spurious pinky_overload events for users who type
; with modifiers held (e.g. Shift for capitals).
;
; The fix adds an early return for all modifier VK codes:
;   0x10-0x12 (generic Shift/Ctrl/Alt), 0xA0/0xA1 (LShift/RShift),
;   0xA2/0xA3 (LCtrl/RCtrl), 0xA4/0xA5 (LAlt/RAlt), 0x5B/0x5C (LWin/RWin).
; ==============================================================================

#Requires AutoHotkey v2.0

_TEPMS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TEPMS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; =====================================================================
; =====================================================================
; ======= 1/ Modifier VK codes guarded with early return ==============
; =====================================================================
; =====================================================================

_TEPMS_ModifierVkEarlyReturn() {
	Src := _TEPMS_StripLineComments(_TEPMS_ReadSource("modules/keylogger/keylogger_ergonomics.ahk"))
	Assert(Src != "", "modules/keylogger/keylogger_ergonomics.ahk must be readable")

	Body := _DriverFuncBody("KL_Ergo_UpdatePinky")
	Assert(Body != "", "KL_Ergo_UpdatePinky must be defined in modules/keylogger/keylogger_ergonomics.ahk")

	; Generic Shift/Ctrl/Alt (0x10, 0x11, 0x12) must be in the guard
	Assert(InStr(Body, "0x10") > 0,
		"KL_Ergo_UpdatePinky must skip generic Shift VK 0x10 (modifier VK early return)")
	Assert(InStr(Body, "0x11") > 0,
		"KL_Ergo_UpdatePinky must skip generic Ctrl VK 0x11 (modifier VK early return)")
	Assert(InStr(Body, "0x12") > 0,
		"KL_Ergo_UpdatePinky must skip generic Alt VK 0x12 (modifier VK early return)")

	; Extended modifier VKs must also be guarded
	Assert(InStr(Body, "0xA0") > 0,
		"KL_Ergo_UpdatePinky must skip LShift VK 0xA0 (modifier VK early return)")
	Assert(InStr(Body, "0x5B") > 0,
		"KL_Ergo_UpdatePinky must skip LWin VK 0x5B (modifier VK early return)")

	; Must actually return early (not just check) — confirm "return" appears in the guard block
	Assert(InStr(Body, "return") > 0,
		"KL_Ergo_UpdatePinky must early-return for modifier VKs so they are not counted in pinky streak")
}
Test("keylogger_ergonomics: KL_Ergo_UpdatePinky early-returns for modifier VKs (0x10-0x12, 0xA0-0xA5, 0x5B/0x5C)", _TEPMS_ModifierVkEarlyReturn)
