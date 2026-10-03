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

/**
 * Whether this driver has an actual token streaming transport.
 * @param {String} Platform Canonical driver id.
 * @param {String} Backend Current native backend id.
 * @returns {Integer} Boolean capability.
 */
LLM_DisplayStreamingCapable(Platform, Backend) {
	return (Platform == "hs" && (Backend == "ollama" || Backend == "mlx"))
		|| (Platform == "linux" && Backend == "ollama")
}

/**
 * Admits token streaming only from a fresh native owner snapshot.
 * @param {Map} Snapshot Runtime gates and exact owner revision.
 * @returns {Integer} Boolean admission.
 */
LLM_DisplayStreamingReady(Snapshot) {
	if !(Snapshot is Map)
		return false
	for Field in ["owner", "generation", "platform", "backend", "streaming",
		"enabled", "paused", "blocked", "progressive"] {
		if !Snapshot.Has(Field)
			return false
	}
	for Field in ["streaming", "enabled", "paused", "blocked", "progressive"] {
		Value := Snapshot[Field]
		if !(Value is Integer) || (Value != true && Value != false)
			return false
	}
	return (Snapshot["owner"] is Object || (Snapshot["owner"] is String && Snapshot["owner"] != ""))
		&& Snapshot["generation"] is Integer && Snapshot["generation"] >= 0
		&& Snapshot["enabled"] && !Snapshot["paused"] && !Snapshot["blocked"]
		&& Snapshot["progressive"]
		&& LLM_DisplayStreamingCapable(Snapshot["platform"], Snapshot["backend"])
}

/**
 * Resolves a retained checkbox against the same current native source.
 * @param {Map} Expected Snapshot captured during rendering.
 * @param {Map} Current Fresh native snapshot before publication.
 * @returns {Map} Decision with admitted and optional value fields.
 */
LLM_DisplayStreamingIntent(Expected, Current) {
	if !LLM_DisplayStreamingReady(Expected) || !LLM_DisplayStreamingReady(Current)
		return Map("admitted", false)
	for Field in ["owner", "generation", "platform", "backend", "streaming", "progressive"] {
		if !(Expected[Field] == Current[Field])
			return Map("admitted", false)
	}
	return Map("admitted", true, "value", !Current["streaming"])
}
