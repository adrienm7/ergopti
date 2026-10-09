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

/**
 * Copies the ordered offsets owned by the generated numeric feature.
 * @param {Map} Feature Canonical number feature.
 * @returns {Array} Accepted integer choices.
 */
LLM_DisplayIndentValues(Feature) {
	if !(Feature is Map) || Feature.Get("type", "") != "number"
			|| !(Feature.Get("choice_values", 0) is Array)
			|| Feature["choice_values"].Length < 2
		throw TypeError("Indentation requires its canonical numeric choice catalogue.")
	Values := []
	for Index, Value in Feature["choice_values"] {
		if !(Value is Integer) || (Index > 1 && Value != Values[Index - 1] + 1)
			throw TypeError("Indentation choices must be ordered contiguous integers.")
		Values.Push(Value)
	}
	return Values
}

/**
 * Admits an indentation choice from a live multi-prediction owner.
 * @param {Map} Snapshot Current native owner and exact revision.
 * @returns {Integer} Boolean admission.
 */
LLM_DisplayIndentReady(Snapshot) {
	if !(Snapshot is Map)
		return false
	for Field in ["owner", "generation", "indentation", "progressive", "count", "enabled", "paused", "blocked"] {
		if !Snapshot.Has(Field)
			return false
	}
	for Field in ["progressive", "enabled", "paused", "blocked"] {
		Value := Snapshot[Field]
		if !(Value is Integer) || (Value != true && Value != false)
			return false
	}
	return Snapshot["owner"] is Object && Snapshot["generation"] is Integer
		&& Snapshot["generation"] >= 0 && Snapshot["indentation"] is Integer
		&& Snapshot["enabled"] && !Snapshot["paused"]
		&& LLM_DisplayShowAllReady(Snapshot["count"], Snapshot["blocked"])
}

/**
 * Resolves one retained offset against the same current native source.
 * @param {Map} Expected Captured rendering snapshot.
 * @param {Map} Current Fresh snapshot before the native setting owner.
 * @param {Integer} Value Requested offset.
 * @param {Array} Values Canonical integer choices.
 * @returns {Map} Decision with admitted and optional value fields.
 */
LLM_DisplayIndentIntent(Expected, Current, Value, Values) {
	if !LLM_DisplayIndentReady(Expected) || !LLM_DisplayIndentReady(Current)
		return Map("admitted", false)
	for Field in ["owner", "generation", "backend", "indentation", "progressive", "count"] {
		if !Expected.Has(Field) || !Current.Has(Field) || !(Expected[Field] == Current[Field])
			return Map("admitted", false)
	}
	for Accepted in Values {
		if Value is Integer && Value == Accepted
			return Map("admitted", true, "value", Value)
	}
	return Map("admitted", false)
}

/**
 * Admits Info Bar independently of prediction count and streaming capability.
 * @param {Map} Snapshot Current native owner, gates and exact revision.
 * @returns {Integer} Boolean admission.
 */
LLM_DisplayInfoBarReady(Snapshot) {
	if !(Snapshot is Map)
		return false
	for Field in ["owner", "generation", "backend", "info_bar", "enabled", "paused", "blocked"] {
		if !Snapshot.Has(Field)
			return false
	}
	for Field in ["info_bar", "enabled", "paused", "blocked"] {
		Value := Snapshot[Field]
		if !(Value is Integer) || (Value != true && Value != false)
			return false
	}
	return Snapshot["owner"] is Object && Snapshot["generation"] is Integer
		&& Snapshot["generation"] >= 0 && Snapshot["backend"] is String
		&& Snapshot["backend"] != "" && Snapshot["enabled"]
		&& !Snapshot["paused"] && !Snapshot["blocked"]
}

/**
 * Resolves a held checkbox against the same acknowledged native source.
 * @param {Map} Expected Rendering snapshot.
 * @param {Map} Current Fresh snapshot before the canonical setting owner.
 * @returns {Map} Decision with admitted and optional value fields.
 */
LLM_DisplayInfoBarIntent(Expected, Current) {
	if !LLM_DisplayInfoBarReady(Expected) || !LLM_DisplayInfoBarReady(Current)
		return Map("admitted", false)
	for Field in ["owner", "generation", "backend", "info_bar"] {
		if !(Expected[Field] == Current[Field])
			return Map("admitted", false)
	}
	return Map("admitted", true, "value", !Current["info_bar"])
}
