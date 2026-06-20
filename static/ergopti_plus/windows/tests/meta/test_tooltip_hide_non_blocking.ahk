; tests/meta/test_tooltip_hide_non_blocking.ahk

; ==============================================================================
; MODULE: TooltipHide Non-Blocking Meta Test
; DESCRIPTION:
; Static source guard for the tooltip-hide-inside-critical-finally finding.
;
; The hotstring fire path reaches TooltipHide() under the Critical held by
; _OnPrefixChar (HSE_DispatchMatch -> _ResetPrefixBuffer -> TooltipHide). Holding
; Critical across a Sleep/WinWait/ClipWait/MsgSleep yields the thread and freezes
; the low-level keyboard hook for that duration, dropping the keys typed right
; after an expansion. Today TooltipHide is fully synchronous (DllCall / Gui.Destroy
; / SetTimer), but the keystroke-loss guarantee depends on it STAYING that way.
;
; This test pins the invariant: it extracts the TooltipHide() body and rejects any
; blocking token (Sleep(, WinWait, ClipWait, MsgSleep). A future fade-out or
; animation await added directly to the teardown — instead of deferred onto a
; SetTimer — makes this test fail, surfacing the latent keystroke-loss trap.
;
; Meta-static (scans source text) because tooltip.ahk registers top-level GUI
; resources and cannot be #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

; Returns the function body from its declaration to the first closing brace at
; column 0 (AHK functions close flush-left; inner blocks close indented). Starts
; AFTER the declaration line so any tokens in the preceding docstring are excluded.
_TTHNB_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		return SubStr(Rest, 1, Match.Pos)
	return Rest
}


; ===================================================
; ===================================================
; ======= 2/ Non-blocking assertions ================
; ===================================================
; ===================================================

_TTHNB_TooltipHideIsNonBlocking() {
	Src := _DriverDirConcat("ui/tooltip")
	Body := _DriverFuncBody("TooltipHide")
	Assert(Body != "", "TooltipHide(DbgTag := ...) declaration must exist in the tooltip module")

	; A held Critical from the fire path spans this body — a blocking call here
	; would freeze the keyboard hook and drop keys typed after an expansion.
	Assert(InStr(Body, "Sleep(") == 0,
		"TooltipHide must not call Sleep() — it runs under the fire-path Critical; defer blocking work onto a SetTimer")
	Assert(InStr(Body, "WinWait") == 0,
		"TooltipHide must not call WinWait* — it runs under the fire-path Critical and would freeze the keyboard hook")
	Assert(InStr(Body, "ClipWait") == 0,
		"TooltipHide must not call ClipWait — it runs under the fire-path Critical and would freeze the keyboard hook")
	Assert(InStr(Body, "MsgSleep") == 0,
		"TooltipHide must not pump the message loop (MsgSleep) — it runs under the fire-path Critical")

	; The invariant must be documented at the function so the constraint is not
	; rediscovered the hard way by a maintainer adding an animation.
	Assert(InStr(Src, "MUST STAY NON-BLOCKING") > 0,
		"TooltipHide must carry the documented non-blocking invariant comment explaining the fire-path Critical")
}
Test("tooltip: TooltipHide stays non-blocking under the fire-path Critical (tooltip-hide-inside-critical-finally)", _TTHNB_TooltipHideIsNonBlocking)
