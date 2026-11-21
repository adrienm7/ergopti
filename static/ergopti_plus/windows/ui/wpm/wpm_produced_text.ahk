; ui/wpm/wpm_produced_text.ahk

; ==============================================================================
; MODULE: WPM Widget — Produced-Text Accounting
; DESCRIPTION:
; Takes back the characters a producer erased from the live speed's ring.
; Apart from wpm_display.ahk so the shared vectors can replay it in the unit
; suite, which replaces that file's keystroke pipeline with a recording stub.
;
; FEATURES & RATIONALE:
; 1. The live speed counts the produced text (maintainer decision MET-17,
;    21 November 2026, macOS's rule): a hotstring's trigger or the text an AI
;    rewrite replaced leaves the window before the output is added, the newest
;    samples at or before the producer's tick first.
; 2. A retracted sample keeps its slot, marked: the ring's head and capacity
;    stay as they were, and WPMWidget_Calc skips the mark.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Marks the Count newest samples at or before NowTick as retracted.
 * @param {Array} Ring The ring of Map("t", Tick, …) samples.
 * @param {Integer} Head The next slot to write (zero-based, modulo Cap).
 * @param {Integer} Cap The ring's capacity.
 * @param {Integer} Count The characters the producer erased.
 * @param {Integer} NowTick The producer's tick.
 * @returns {Integer} The samples retracted, at most Count.
 */
WPMRing_Retract(Ring, Head, Cap, Count, NowTick) {
	if !(Count is Integer) || Count <= 0
		return 0
	if !(Cap is Integer) || Cap <= 0 || !(NowTick is Integer)
		throw ValueError("WPMRing_Retract needs a positive capacity and an integer tick")
	Retracted := 0
	loop Ring.Length {
		if Retracted >= Count
			break
		; Newest first: the slot before the head, walking back over the ring.
		Slot := Mod(Head - A_Index + Cap * 2, Cap) + 1
		if Slot > Ring.Length
			continue
		Sample := Ring[Slot]
		Tick := Sample["t"]
		if Sample.Has("retracted") || !(Tick is Integer) || Tick > NowTick
			continue
		Sample["retracted"] := true
		Retracted += 1
	}
	return Retracted
}
