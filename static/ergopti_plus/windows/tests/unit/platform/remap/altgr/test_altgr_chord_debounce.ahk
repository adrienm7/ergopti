; tests/unit/platform/remap/altgr/test_altgr_chord_debounce.ahk

; ==============================================================================
; MODULE: Script AltGr Chord Debounce Behaviour Tests
; DESCRIPTION:
; Drives the real _ScriptAltGrChordDebounce and _ScriptAltGrDispatch from
; infra/script_altgr_hotkeys.ahk, replacing a verbatim copy of the debounce and
; source reads of both bodies.
;
; F45: one shared timestamp debounced every chord slot, so two different chords
; within 80 ms dropped the second. The debounce is keyed by slot, and the
; dispatch asks it first, so a chord completed just before a suspend/resume
; toggle cannot replay on the fresh thread spawned after resume.
;
; The dispatch probe passes an object as the suffix scan code: the physical-key
; check then throws a TypeError at its first GetKeyState, so reaching it is
; observable and nothing is ever sent or run.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 1/ Debounce slot isolation =======
; ==========================================
; ==========================================

; A slot name no earlier call has used, so the debounce's static map holds no
; timestamp for it.
; @param {String} Tag - Distinguishes the slots one test needs.
; @returns {String} The fresh slot name.
_TACD_FreshSlot(Tag) {
	static Sequence := 0
	Sequence += 1
	return "test_chord_debounce_" . Tag . "_" . A_TickCount . "_" . Sequence
}

; The debounce window is 80 ms; a runner stalled longer between two calls
; would make a true repeat look like a new press, so a stalled attempt retries.
_TACD_PerSlotIndependence() {
	loop 5 {
		First := _TACD_FreshSlot("first")
		Second := _TACD_FreshSlot("second")
		Started := A_TickCount
		FirstPress := _ScriptAltGrChordDebounce(First)
		OtherPress := _ScriptAltGrChordDebounce(Second)
		Repeat := _ScriptAltGrChordDebounce(First)
		if TickElapsed(Started) >= 40
			continue
		AssertFalse(FirstPress, "the first press of a slot is not debounced")
		AssertFalse(OtherPress, "a different slot pressed at once is not debounced (F45: one shared window dropped it)")
		AssertTrue(Repeat, "an immediate repeat of the same slot is debounced")
		return
	}
	Assert(false, "the runner stalled past the debounce window on every attempt")
}
Test("F45: the real AltGr chord debounce is per slot (distinct chords within 80ms are not dropped)",
	_TACD_PerSlotIndependence)




; ===========================================
; ===========================================
; ======= 2/ Dispatch asks it first =========
; ===========================================
; ===========================================

; An object scan code makes the physical-key check throw instead of reading
; the keyboard, which marks that the dispatch went past its debounce.
_TACD_DispatchProbe(Slot) {
	_ScriptAltGrDispatch({}, Slot, "")
}

_TACD_DebouncedChordStopsBeforeThePhysicalCheck() {
	loop 5 {
		Slot := _TACD_FreshSlot("dispatch")
		Started := A_TickCount
		_ScriptAltGrChordDebounce(Slot)
		Reached := false
		try _TACD_DispatchProbe(Slot)
		catch TypeError
			Reached := true
		if TickElapsed(Started) >= 40
			continue
		AssertFalse(Reached,
			"a chord debounced for its slot must return before the physical check and the action (altgr-dispatch-resume-aware)")
		AssertThrows(_TACD_DispatchProbe.Bind(_TACD_FreshSlot("control")),
			"control: a slot with no recent press must reach the physical check")
		return
	}
	Assert(false, "the runner stalled past the debounce window on every attempt")
}
Test("script_altgr: the dispatch asks the slot's debounce before the physical check (altgr-dispatch-resume-aware)",
	_TACD_DebouncedChordStopsBeforeThePhysicalCheck)

; The paused-state chords run through the same dispatch: a pause check at its
; head would make pause, reload and quit unreachable from the keyboard.
_TACD_PausedDispatchReachesThePhysicalCheck() {
	WasSuspended := A_IsSuspended
	Suspend(1)
	try Reached := _TACD_ReachesPhysicalCheck(_TACD_FreshSlot("paused"))
	finally Suspend(WasSuspended ? 1 : 0)
	AssertTrue(Reached, "a paused driver's chord must still reach the physical check (altgr-dispatch-resume-aware)")
}
_TACD_ReachesPhysicalCheck(Slot) {
	try _TACD_DispatchProbe(Slot)
	catch TypeError
		return true
	return false
}
Test("script_altgr: a paused chord still reaches the physical check (altgr-dispatch-resume-aware)",
	_TACD_PausedDispatchReachesThePhysicalCheck)
