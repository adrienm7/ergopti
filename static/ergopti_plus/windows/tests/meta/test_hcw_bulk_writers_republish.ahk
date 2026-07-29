; tests/meta/test_hcw_bulk_writers_republish.ahk

; ==============================================================================
; MODULE: Regression — the config window's BULK writers must republish too
;         (hcw-bulk-writers-republish)
; DESCRIPTION:
; "Réinitialiser tout" cleared every delay and priority override and never
; re-registered the engine, so the window and the tooltip immediately advertised
; the default expansion window while the running specs kept gating on the value
; the user had set moments earlier. Typing the trigger then did nothing the
; tooltip had promised.
;
; ROOT CAUSE ENCODED: delay and priority are BAKED into each Spec at registration
; time, so persisting them only bumps the resolve generation — a live
; re-registration is additionally required. The repo already knew that and put
; _HCW_RepublishIfBakedField on _HCW_SetOverride / _HCW_ClearOverride, the
; per-field choke point. The bulk handlers walk the catalogue and call
; HotstringsClearOverride / _HCW_PatchTomlMeta DIRECTLY, so they never reach that
; choke point. Same invariant, sibling forgotten — which is why this asserts the
; property for the bulk writers as a group rather than for the one that broke.
;
; SCOPE: source-level. The config window builds a native Gui at top level and is
; deliberately outside the headless include graph — see
; test_config_window_republishes_baked_fields.ahk for the same constraint.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The bulk mutation handlers ============================
; ==================================================================
; ==================================================================

; The native config window's catalogue-wide handlers: one clears every override,
; the other forces every colour to grey. Both bypass _HCW_SetOverride /
; _HCW_ClearOverride by design (they call the storage primitives directly), so
; the republish they skip has to be asserted here.
_HCWBR_BulkWriters() {
	return ["_HCW_ResetAll", "_HCW_SetAllGrey"]
}

; The fields the engine bakes into each spec at registration. Colour and
; show_tooltip are derived at read and deliberately absent — a ~1.3 s
; re-registration on every colour pick would make the window unusable.
_HCWBR_BakedFields() {
	return ["delay", "priority"]
}





; ==================================================================
; ==================================================================
; ======= 2/ Assertion =============================================
; ==================================================================
; ==================================================================

; Conditional on purpose: it pins the baked/derived split from both sides. A bulk
; writer that touches delay or priority must republish; _HCW_SetAllGrey writes
; only colour and therefore must stay free to skip the rebuild.
_HCWBR_BulkWritersRepublishBakedFields() {
	Checked := 0
	WithBaked := 0
	for FuncName in _HCWBR_BulkWriters() {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . "() must exist in the driver source")
		Checked += 1

		TouchesBaked := false
		for Field in _HCWBR_BakedFields()
			if (InStr(Body, '"' . Field . '"') > 0)
				TouchesBaked := true
		if !TouchesBaked
			continue
		WithBaked += 1

		Assert(InStr(Body, "_HCW_RepublishIfBakedField") > 0,
			FuncName . " clears the same baked delay/priority overrides the per-field writers republish for, so it must republish too — without it the window and the tooltip show the default while the registered specs keep gating on the value the user just reset away, until the next reload")
	}

	Assert(Checked == 2,
		"both bulk mutation handlers must be reachable by name (found " . Checked . ") — a scan that resolves nothing cannot fail")
	Assert(WithBaked >= 1,
		"at least one bulk writer must be seen touching a baked field (found " . WithBaked . ") — if none matches, this guard is vacuous and would pass on the very regression it exists to catch")
}
Test("meta hcw-bulk-writers-republish: a bulk write to a baked field re-registers the engine",
	_HCWBR_BulkWritersRepublishBakedFields)
