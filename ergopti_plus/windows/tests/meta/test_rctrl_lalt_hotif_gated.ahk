; tests/meta/test_rctrl_lalt_hotif_gated.ahk

; ==============================================================================
; MODULE: RCtrl+LAlt hotkey gated by #HotIf, not a dead runtime if
; DESCRIPTION:
; AHK v2 registers `::` hotkeys at LOAD time regardless of any enclosing runtime
; control flow. platform/remap/lalt.ahk wrapped the SC11D & SC038 (RCtrl+LAlt)
; definition in `if TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" {`
; — dead decoration: the hotkey registered unconditionally, so RCtrl+LAlt emitted
; OneShotShiftFix()+Shift+Tab even when right_ctrl was not one_shot_shift. The
; condition must live in the #HotIf (re-evaluated live per press), not a runtime if.
; (F31, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_RLHG_RCtrlLAltGatedByHotIf() {
	; Move-resilient: the SC11D & SC038 definition exists in exactly ONE file, and a
	; file's content is contiguous inside the concatenation, so the nearest preceding
	; #HotIf is that file's own — no need to pin platform/remap/lalt.ahk's path.
	Src := _DriverSourceConcat()
	Assert(Src != "", "driver source must be readable for the RCtrl+LAlt gating meta-test")

	HotkeyPos := InStr(Src, "SC11D & SC038::")
	Assert(HotkeyPos > 0, "the RCtrl+LAlt (SC11D & SC038) hotkey must exist")

	; It must be gated by a #HotIf whose expression includes the right_ctrl condition.
	; Before the fix the nearest #HotIf was the left_alt-only criterion (the right_ctrl
	; test sat in a runtime `if`, which does not gate a load-time registration at all).
	Before := SubStr(Src, 1, HotkeyPos)
	HotIfPos := InStr(Before, "#HotIf ", , -1)
	Assert(HotIfPos > 0, "SC11D & SC038 must sit under a #HotIf context")
	NlPos := InStr(Src, "`n", , HotIfPos)
	HotIfLine := SubStr(Src, HotIfPos, (NlPos ? NlPos : StrLen(Src) + 1) - HotIfPos)
	Assert(InStr(HotIfLine, "right_ctrl") > 0,
		"the #HotIf gating SC11D & SC038 must include the right_ctrl condition so the combo fires only when right_ctrl is one_shot_shift")
}
Test("tap-holds: RCtrl+LAlt hotkey is gated by #HotIf, not a dead runtime if", _RLHG_RCtrlLAltGatedByHotIf)
