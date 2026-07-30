; tests/meta/test_config_window_republishes_baked_fields.ahk

; ==============================================================================
; MODULE: Regression — config-window writes to baked fields must re-register the
;         live engine (config-window-republish-baked)
; DESCRIPTION:
; Raising a trigger's delay in the hotstrings config window changed what the
; TOOLTIP said and nothing else. The tooltip renders the delay derived at read
; through HotstringsResolve, so it showed the new duration immediately — while
; the engine kept gating on Spec.TimeActivationSeconds, baked into the spec when
; it was registered. The window therefore advertised an expansion window the
; engine refused, until the next reload. Priority behaved the same way: the
; window showed the new value while collisions still resolved by the old one.
;
; ROOT CAUSE ENCODED: some override fields are derived at READ time (color,
; show_tooltip) and some are baked at REGISTRATION time (delay, priority).
; Persisting either only bumps the resolve generation. The baked ones therefore
; additionally need a live re-registration — which the tray-menu delay editors
; already did, and the config window did not. Two writers for one setting, one
; of which republished.
;
; The guard is placed on _HCW_SetOverride / _HCW_ClearOverride because they are
; the choke point BOTH config-window front-ends go through (the native Gui and
; the WebView bridge), so neither can regress independently.
;
; SCOPE: source-level. The config window builds a native Gui at top level and is
; deliberately outside the headless include graph — loading it hangs CI. See
; test_config_window_delay_write_per_keystroke.ahk for the same constraint.
; ==============================================================================

#Requires AutoHotkey v2.0

; The fields the config window can persist. Enumerated from source below and
; compared against this list, so a NEW field cannot be added without someone
; deciding whether it is derived-at-read or baked-at-registration.
global _CWRB_KNOWN_FIELDS := ["delay", "priority", "color", "show_tooltip"]

; The subset that the engine bakes into each spec at registration time.
global _CWRB_BAKED_FIELDS := ["delay", "priority"]

; The subset that HotstringsResolve derives at read time. Re-registering for
; these would cost a ~1.3 s rebuild per colour pick for no benefit, so their
; ABSENCE from the rebuild map is asserted just as hard as the others' presence.
global _CWRB_DERIVED_FIELDS := ["color", "show_tooltip"]




; ==================================================================
; ==================================================================
; ======= 1/ Both override writers republish =======================
; ==================================================================
; ==================================================================

; Setting an override and CLEARING one are the same event as far as the engine
; is concerned: the effective value changed. Clearing a delay override back to
; the category default is exactly as invisible to a baked spec as setting one,
; and it is the classic missed sibling — so both are asserted.
_CWRB_BothWritersRepublish() {
	for FuncName in ["_HCW_SetOverride", "_HCW_ClearOverride"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . "() must exist in the driver source")

		RepubPos := InStr(Body, "_HCW_RepublishIfBakedField")
		Assert(RepubPos > 0,
			FuncName . " must republish after writing — persisting an override only bumps the resolve generation, so a delay or priority baked into the registered specs keeps its old value while the window shows the new one")

		; After the write, not before: republishing first would re-register from
		; the value that is about to be replaced.
		WritePos := InStr(Body, "Hotstrings" . (InStr(FuncName, "Clear") ? "Clear" : "Set") . "Override")
		Assert(WritePos > 0, FuncName . " must still perform the override write")
		Assert(WritePos < RepubPos,
			"the republish must come AFTER the write in " . FuncName . " — re-registering first would bake the value being replaced")
	}
}

; The republish helper must actually re-register, and must contain its own
; failure: it runs from a UI callback while the user is still editing, so a
; throwing rebuild must not lose the write that already succeeded.
_CWRB_RepublishRebuildsAndContainsFailure() {
	Body := _DriverFuncBody("_HCW_RepublishIfBakedField")
	Assert(Body != "", "_HCW_RepublishIfBakedField() must exist in the driver source")
	Assert(InStr(Body, "RebuildHotstringsLive") > 0,
		"the republish must re-run the live registration — that is the only path that re-bakes delay and priority into the specs")
	Assert(InStr(Body, "catch") > 0 and InStr(Body, "LoggerError") > 0,
		"a failing rebuild must be caught and logged rather than propagating out of a UI callback: the override is already persisted at that point, and an uncaught throw would tear down the window the user is editing in")
}





; =================================================================
; =================================================================
; ======= 2/ The baked/derived split is complete and honest =======
; =================================================================
; =================================================================

; Every field name the config window writes, taken from its own source rather
; than from this test's expectations.
_CWRB_WrittenFields() {
	Src := _StripFullLineComments(_DriverDirConcat("ui/hotstrings_config_window"))
	Fields := Map()
	Pos := 1
	while (FoundPos := RegExMatch(Src,
		'_HCW_(?:SetOverride|ClearOverride|ArmNumericWrite)\((?:[^,]*,){0,2}\s*"([a-z_]+)"', &M, Pos)) {
		Pos := FoundPos + M.Len
		Fields[M[1]] := true
	}
	; _HCW_ArmNumericWrite takes the field FIRST; the override writers take it
	; third. One pattern cannot anchor both, so pick up the leading-arg shape too.
	Pos := 1
	while (FoundPos := RegExMatch(Src, '_HCW_ArmNumericWrite\("([a-z_]+)"', &M2, Pos)) {
		Pos := FoundPos + M2.Len
		Fields[M2[1]] := true
	}
	return Fields
}

; Drift guard. A new persisted field must be consciously classified, because
; getting it wrong is silent in both directions: a baked field left out keeps
; the engine on stale values, and a derived field wrongly added costs a ~1.3 s
; re-registration on every edit.
_CWRB_EveryWrittenFieldIsClassified() {
	global _CWRB_KNOWN_FIELDS
	Written := _CWRB_WrittenFields()

	Count := 0
	for _, _ in Written
		Count++
	Assert(Count >= 3,
		"the scan must reach the config window's real write sites (found only " . Count . " field(s)) — a scan that matches nothing cannot fail")

	for Field, _ in Written {
		Known := false
		for K in _CWRB_KNOWN_FIELDS
			if (K == Field)
				Known := true
		Assert(Known,
			"the config window writes an override field this guard does not know about: '" . Field . "'. Decide whether the engine BAKES it at registration (then add it to HCW_REBUILD_ON_WRITE_FIELDS and to _CWRB_BAKED_FIELDS) or DERIVES it at read (then add it to _CWRB_DERIVED_FIELDS). Leaving it unclassified is how delay and priority silently stopped reaching the engine")
	}
}

; The map itself: the baked fields must be in it, and the derived ones must not.
_CWRB_RebuildMapCoversExactlyTheBakedFields() {
	global _CWRB_BAKED_FIELDS, _CWRB_DERIVED_FIELDS
	Src := _StripFullLineComments(_DriverSourceConcat())
	if !RegExMatch(Src, "m)^global\s+HCW_REBUILD_ON_WRITE_FIELDS\s*:=\s*Map\(([^\r\n]*)\)", &M)
		Assert(false, "HCW_REBUILD_ON_WRITE_FIELDS must be declared as a module-level Map")
	Decl := M[1]

	for Field in _CWRB_BAKED_FIELDS
		Assert(InStr(Decl, '"' . Field . '"') > 0,
			"'" . Field . "' is baked into each spec at registration, so writing it must trigger a live re-registration — without it the window and the engine hold two different values for the same setting")

	for Field in _CWRB_DERIVED_FIELDS
		Assert(InStr(Decl, '"' . Field . '"') == 0,
			"'" . Field . "' is derived at read time, so it must NOT trigger a re-registration — a ~1.3 s rebuild on every colour pick would make the config window unusable")
}


Test("meta config-window-republish-baked: both override writers republish",
	_CWRB_BothWritersRepublish)
Test("meta config-window-republish-baked: the republish rebuilds and contains its failure",
	_CWRB_RepublishRebuildsAndContainsFailure)
Test("meta config-window-republish-baked: every written field is classified",
	_CWRB_EveryWrittenFieldIsClassified)
Test("meta config-window-republish-baked: the rebuild map covers exactly the baked fields",
	_CWRB_RebuildMapCoversExactlyTheBakedFields)
