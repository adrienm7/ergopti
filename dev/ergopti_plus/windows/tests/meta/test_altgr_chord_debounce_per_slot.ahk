; tests/meta/test_altgr_chord_debounce_per_slot.ahk

; ==============================================================================
; MODULE: AltGr Chord Debounce Per-Slot Independence Guard
; DESCRIPTION:
; Functional test for the F45 fix: _ScriptAltGrChordDebounce must key the
; 80ms debounce window per Slot string, not share a single global last_tick.
;
; ROOT CAUSE ENCODED:
; The original implementation used a single `static last_tick` shared across
; all four AltGr chord handlers. If two DISTINCT chords fired within 80ms of
; each other (e.g. AltGr+Delete followed immediately by AltGr+Escape), the
; second chord was silently dropped even though it was a different action.
; The fix uses a static Map keyed by Slot so each chord maintains its own
; independent debounce window.
;
; This test copies the fixed implementation verbatim and asserts per-slot
; independence: a first call for slot A must pass (false), an immediate call
; for a different slot B must also pass (false), and an immediate repeat of
; slot A must be rejected (true).
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Inline implementation under test =======
; ===================================================
; ===================================================

; Verbatim copy of the fixed _ScriptAltGrChordDebounce from lib/script_altgr_hotkeys.ahk.
; Keeping it inline lets the test run headless without #Including the full
; driver (which registers global hotkeys incompatible with the test runner).
_TestDebounce(Slot) {
	static last := Map()
	now := A_TickCount
	prev := last.Has(Slot) ? last[Slot] : 0
	if ((now - prev) & 0xFFFFFFFF) < 80
		return true
	last[Slot] := now
	return false
}




; ======================================================
; ======================================================
; ======= 2/ Per-slot independence assertions ==========
; ======================================================
; ======================================================

_ACDS_AssertPerSlotIndependence() {
	; First call for slot A must pass (not debounced)
	r1 := _TestDebounce("script_altgr_delete")
	Assert(r1 = false,
		"First call for script_altgr_delete must not be debounced (r1=" . r1 . ")")

	; Immediate call for a DIFFERENT slot must also pass — slots are independent
	r2 := _TestDebounce("script_altgr_escape")
	Assert(r2 = false,
		"Immediate call for script_altgr_escape must not be debounced — different slot (r2=" . r2 . ")")

	; Immediate repeat of slot A must be rejected — within 80ms window
	r3 := _TestDebounce("script_altgr_delete")
	Assert(r3 = true,
		"Immediate repeat of script_altgr_delete must be debounced (r3=" . r3 . ")")
}
Test("F45: AltGr chord debounce is per-slot (distinct chords within 80ms are not dropped)", _ACDS_AssertPerSlotIndependence)




; ==========================================================
; ==========================================================
; ======= 3/ Source scan: no shared last_tick ==============
; ==========================================================
; ==========================================================

_ACDS_AssertNoSharedLastTick() {
	; Move-resilient: locate the function bodies across the whole driver source
	Body := _DriverFuncBody("_ScriptAltGrChordDebounce")
	Assert(Body != "", "_ScriptAltGrChordDebounce must exist in lib/script_altgr_hotkeys.ahk")

	; Must use a Map, not a plain scalar last_tick
	Assert(!InStr(Body, "last_tick"),
		"_ScriptAltGrChordDebounce must not use a shared last_tick scalar (F45: all slots shared one debounce window)")
	Assert(InStr(Body, "Map()") > 0,
		"_ScriptAltGrChordDebounce must use a static Map() for per-slot debounce tracking (F45)")

	; Call site must pass Slot argument
	DispBody := _DriverFuncBody("_ScriptAltGrDispatch")
	Assert(DispBody != "", "_ScriptAltGrDispatch must exist in lib/script_altgr_hotkeys.ahk")
	Assert(RegExMatch(DispBody, "_ScriptAltGrChordDebounce\s*\(Slot\)") > 0,
		"_ScriptAltGrDispatch must call _ScriptAltGrChordDebounce(Slot) with the Slot argument (F45)")
}
Test("F45: _ScriptAltGrChordDebounce uses per-slot Map, not shared last_tick", _ACDS_AssertNoSharedLastTick)