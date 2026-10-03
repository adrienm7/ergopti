; _shared/modules/llm/display_policy.ahk

; =================================
; MODULE: Prediction Display Polarity
; DESCRIPTION:
; Keeps the canonical progressive preference opposite to the native show-all
; checkbox. Drivers retain persistence, readiness and presentation ownership.
; =================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; =================================
; =================================
; =================================

/**
 * Converts canonical progressive display to the native show-all preference.
 * @param {Integer} Progressive Boolean canonical preference.
 * @returns {Integer} Boolean native preference.
 */
LLM_DisplayShowAll(Progressive) {
	if !(Progressive is Integer) || (Progressive != false && Progressive != true)
		throw TypeError("Progressive display must be boolean.")
	return !Progressive
}

/**
 * Converts a native show-all preference to canonical progressive display.
 * @param {Integer} ShowAll Boolean native preference.
 * @returns {Integer} Boolean canonical preference.
 */
LLM_DisplayProgressive(ShowAll) {
	return LLM_DisplayShowAll(ShowAll)
}

/**
 * Admits changes only while the current owner has multiple prediction slots.
 * @param {Integer} Count Current prediction count.
 * @param {Integer} Blocked Current native refusal gate.
 * @returns {Integer} Boolean admission.
 */
LLM_DisplayShowAllReady(Count, Blocked := false) {
	return (Blocked is Integer) && Blocked == false
		&& (Count is Integer) && Count >= 2
}
