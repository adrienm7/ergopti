; tests/meta/test_llm_nav_loop_ten.ahk

; ==============================================================================
; MODULE: LLM Nav Jump Loop-10 Meta Test
; DESCRIPTION:
; Regression guard ensuring the digit-hotkey binding loop in LLM_Menu_RebindNav
; covers all 10 prediction slots (1-9 and 0 for slot 10).
;
; The bug: the loop ran Loop 9, registering Alt+1 through Alt+9 as prediction-
; jump hotkeys.  Slot 10 (the tenth prediction candidate) was never bound —
; pressing Alt+0 did nothing even when a tenth prediction was displayed.  This
; was the off-by-one in: the keyboard has digits 1-9 plus 0, and the UI
; supports up to 10 simultaneous candidates.
;
; The fix: change the loop to Loop 10 and map A_Index == 10 to digit "0" so
; all ten slots get a corresponding hotkey.
;
; SCOPE: source introspection of ui/menu/menu_llm/tab_accept.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_LNLT_CheckLoopIsTen() {
	; Move-resilient: scan the whole driver source via the framework helper.
	; "Loop 10" and "Loop 9" are unique enough that whole-tree scope preserves
	; the present/absent semantics and strengthens the absent guard.
	Src := _DriverSourceConcat()

	Assert(!InStr(Src, "Loop 9"),
		"nav-jump binding loop must not be Loop 9 — that misses slot 10 (digit 0)")

	Assert(InStr(Src, "Loop 10"),
		"nav-jump binding loop must be Loop 10 to cover all 10 prediction slots")
}

_LNLT_CheckSlot10MapsToZero() {
	; Move-resilient: "A_Index == 10" is unique to tab_accept.ahk in the driver
	; source, so whole-tree scope cannot false-pass.
	Src := _DriverSourceConcat()

	; The mapping of index 10 to digit "0" must be present
	Assert(InStr(Src, "A_Index == 10") && InStr(Src, '"0"'),
		'nav-jump loop must map A_Index == 10 to digit "0" so Alt+0 jumps to slot 10')
}


Test("meta llm-nav-loop-ten: digit-hotkey binding loop covers 10 slots (not 9)",
	_LNLT_CheckLoopIsTen)

Test("meta llm-nav-loop-ten: index 10 maps to digit 0 in the nav-jump loop",
	_LNLT_CheckSlot10MapsToZero)
