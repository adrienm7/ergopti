; tests/meta/test_lalt_rctrl_accept_suspend_guard.ahk

; ==============================================================================
; MODULE: LAlt / RCtrl Accept Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the T-W04 finding: the LLM-accept path in
; lalt.ahk and rctrl.ahk must be gated by A_IsSuspended before calling
; LLM_Tooltip_FireTabOrAccept.
;
; Both tap-hold blocks reach LLM_Tooltip_FireTabOrAccept on a tap release
; that follows a KeyWait. Because the key-wait is non-blocking the AHK
; hotkey thread stays alive across a Suspend toggle, so the caller could
; fire the LLM accept callback while the driver is paused if no guard is
; present. The fix adds `if A_IsSuspended return` immediately before the
; call so a mid-wait suspend cancels the accept without affecting the rest
; of the tap-hold machinery.
;
; Assertion strategy: locate the contiguous hotkey block that contains
; LLM_Tooltip_FireTabOrAccept in each source file, then assert that
; A_IsSuspended appears at a position strictly before the call in that
; block. A position-based check catches both the presence of the guard and
; the order invariant — a guard added AFTER the call would still fail.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Source scan helpers ======================
; =====================================================
; =====================================================

_LARSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extract the smallest hotkey block that contains the given needle.
; A block is delimited by a blank #HotIf line on each side, so we walk
; backwards from the needle to the nearest preceding blank #HotIf and
; forward to the nearest following blank #HotIf.
_LARSG_HotIfBlock(Src, Needle) {
	CallPos := InStr(Src, Needle)
	if !CallPos
		return ""

	; Walk backward to find the nearest #HotIf ... block opener.
	; We search for any "#HotIf " (with a condition) before the call.
	BlockStart := 0
	SearchFrom := 1
	loop {
		Pos := InStr(Src, "#HotIf ", , SearchFrom)
		if (!Pos or Pos >= CallPos)
			break
		BlockStart := Pos
		SearchFrom := Pos + 1
	}
	if !BlockStart
		return SubStr(Src, 1, CallPos + StrLen(Needle))

	; Walk forward to find the nearest "#HotIf" (bare closer) after the call.
	ClosePos := InStr(Src, "`n#HotIf`n", , CallPos)
	if !ClosePos
		ClosePos := InStr(Src, "`n#HotIf`r`n", , CallPos)
	if ClosePos
		return SubStr(Src, BlockStart, ClosePos - BlockStart + 8)
	return SubStr(Src, BlockStart)
}


; =====================================================
; =====================================================
; ======= 2/ Assertions ================================
; =====================================================
; =====================================================

_LARSG_LaltAcceptHasSuspendGuard() {
	Src := _LARSG_ReadSource("modules/tap_holds/lalt.ahk")

	; Locate the hotkey block that calls LLM_Tooltip_FireTabOrAccept in lalt.ahk.
	CallTarget := "LLM_Tooltip_FireTabOrAccept"
	CallPos := InStr(Src, CallTarget)
	Assert(CallPos > 0, "LLM_Tooltip_FireTabOrAccept must exist in lalt.ahk")

	Seg := _LARSG_HotIfBlock(Src, CallTarget)
	Assert(Seg != "", "Could not extract the hotkey block containing LLM_Tooltip_FireTabOrAccept in lalt.ahk")

	; Verify A_IsSuspended is present in the segment.
	GuardPos := InStr(Seg, "A_IsSuspended")
	Assert(GuardPos > 0,
		"lalt.ahk: the LLM accept block must check A_IsSuspended — a Suspend toggle mid-KeyWait would fire the accept while paused without this guard")

	; Verify the guard appears BEFORE the call (position within the segment).
	LocalCallPos := InStr(Seg, CallTarget)
	Assert(GuardPos < LocalCallPos,
		"lalt.ahk: A_IsSuspended guard must appear BEFORE LLM_Tooltip_FireTabOrAccept — a guard placed after the call provides no protection")
}
Test("lalt: LLM accept path has A_IsSuspended guard", _LARSG_LaltAcceptHasSuspendGuard)


_LARSG_RctrlAcceptHasSuspendGuard() {
	Src := _LARSG_ReadSource("modules/tap_holds/rctrl.ahk")

	; Locate the hotkey block that calls LLM_Tooltip_FireTabOrAccept in rctrl.ahk.
	CallTarget := "LLM_Tooltip_FireTabOrAccept"
	CallPos := InStr(Src, CallTarget)
	Assert(CallPos > 0, "LLM_Tooltip_FireTabOrAccept must exist in rctrl.ahk")

	Seg := _LARSG_HotIfBlock(Src, CallTarget)
	Assert(Seg != "", "Could not extract the hotkey block containing LLM_Tooltip_FireTabOrAccept in rctrl.ahk")

	; Verify A_IsSuspended is present in the segment.
	GuardPos := InStr(Seg, "A_IsSuspended")
	Assert(GuardPos > 0,
		"rctrl.ahk: the LLM accept block must check A_IsSuspended — a Suspend toggle mid-KeyWait would fire the accept while paused without this guard")

	; Verify the guard appears BEFORE the call (position within the segment).
	LocalCallPos := InStr(Seg, CallTarget)
	Assert(GuardPos < LocalCallPos,
		"rctrl.ahk: A_IsSuspended guard must appear BEFORE LLM_Tooltip_FireTabOrAccept — a guard placed after the call provides no protection")
}
Test("rctrl: LLM accept path has A_IsSuspended guard", _LARSG_RctrlAcceptHasSuspendGuard)
