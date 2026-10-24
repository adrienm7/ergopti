; infra/hotstrings/preview_switches.ahk

; ==============================================================================
; MODULE: Preview-bubble switches
; DESCRIPTION:
; The four switches of the hotstring preview bubble (hotstrings.preview_star_enabled,
; preview_autocorrect_enabled, preview_ai_enabled, preview_colored_tooltips), as
; macOS and Linux have them. One home for the key list, the published values and
; the family classification, included by the config loader (infra/feature_state.ahk)
; and by the hotstring engine, so the headless harnesses that load only one of them
; still see the same definitions.
; ==============================================================================

; The four preview-bubble switches under [hotstrings], in the menu order. One
; list for the loader, the menu toggle and the engine readers.
; @returns {Array}
HSE_PreviewSwitchKeys() {
	return ["preview_star_enabled", "preview_autocorrect_enabled",
		"preview_ai_enabled", "preview_colored_tooltips"]
}

; The switches as the loader and the menu publish them. A key absent from the
; Map reads the manifest default.
global HSE_PreviewSwitches := Map()

; @param Key {String}
; @returns {Boolean} True for one of HSE_PreviewSwitchKeys().
HSE_PreviewSwitchIsKnown(Key) {
	for Known in HSE_PreviewSwitchKeys() {
		if Known == Key
			return true
	}
	return false
}

; Whether one preview switch is on: the published value, or the manifest
; default before the loader ran. Throws on a key that is no preview switch, so
; a misspelt call site cannot silently read "off".
; @param Key {String} One of HSE_PreviewSwitchKeys().
; @returns {Boolean}
HSE_PreviewSwitchCurrent(Key) {
	global HSE_PreviewSwitches
	if !HSE_PreviewSwitchIsKnown(Key)
		throw ValueError("Unknown preview switch: " . Key)
	if HSE_PreviewSwitches.Has(Key)
		return HSE_PreviewSwitches[Key] ? true : false
	return ManifestDefaultFor("hotstrings." . Key) ? true : false
}

; Publish one preview switch to the readers. Callers persist it first.
; @param Key {String} One of HSE_PreviewSwitchKeys().
; @param Value {Boolean}
HSE_PreviewSwitchPublish(Key, Value) {
	global HSE_PreviewSwitches
	if !HSE_PreviewSwitchIsKnown(Key)
		throw ValueError("Unknown preview switch: " . Key)
	HSE_PreviewSwitches[Key] := Value ? true : false
}

; Which switch governs one preview candidate. A row completed by the magic key
; is the star family, a row completed by an end character the autocorrect
; family: macOS and Linux split their previews on the same line (the star type
; against everything else).
; @param Decision {Object} A HSE_PreviewNextDecision answer.
; @returns {String} "preview_star_enabled" or "preview_autocorrect_enabled".
HSE_PreviewFamilySwitch(Decision) {
	return (Decision.EndChar == "") ? "preview_star_enabled"
		: "preview_autocorrect_enabled"
}
