; _shared/modules/llm/trigger_policy.ahk

; ==============================================================================
; MODULE: Prediction Privacy Intent
; DESCRIPTION:
; Admits retained privacy checks only against the same live native owner.
; Drivers prove exact source bytes and retain acknowledged publication owners.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Requires a complete native boolean snapshot and an available live master. */
LLM_TriggerPrivacyReady(Snapshot) {
	if !(Snapshot is Map)
		return false
	for Field in ["owner", "generation", "backend", "value", "enabled", "paused", "blocked"] {
		if !Snapshot.Has(Field)
			return false
	}
	for Field in ["value", "enabled", "paused", "blocked"] {
		Value := Snapshot[Field]
		if !(Value is Integer) || (Value != true && Value != false)
			return false
	}
	return Snapshot["owner"] is Object && Snapshot["generation"] is Integer
		&& Snapshot["generation"] >= 0 && Snapshot["backend"] is String
		&& Snapshot["backend"] != "" && Snapshot["enabled"]
		&& !Snapshot["paused"] && !Snapshot["blocked"]
}

/** Resolves a retained check without borrowing a newer owner's privacy intent. */
LLM_TriggerPrivacyIntent(Expected, Current) {
	if !LLM_TriggerPrivacyReady(Expected) || !LLM_TriggerPrivacyReady(Current)
		return Map("admitted", false)
	for Field in ["owner", "generation", "value"] {
		if !(Expected[Field] == Current[Field])
			return Map("admitted", false)
	}
	if StrCompare(Expected["backend"], Current["backend"], true) != 0
		return Map("admitted", false)
	return Map("admitted", true, "value", !Current["value"])
}
