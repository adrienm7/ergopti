; tests/meta/test_hcw_reset_all_republishes.ahk

; ==============================================================================
; MODULE: Hotstrings-Config "Reset all" Republish Coverage Meta Test
; DESCRIPTION:
; Regression guard for hcw-webview-reset-does-not-republish.
;
; The hotstrings config window exists TWICE — a native Gui and a WebView2 host
; sharing the shared frontend — and each has its own "reset all" handler. Two
; hardenings were applied to the native one and not to its twin:
;
;   1. CANCEL FIRST. A numeric edit armed by _HCW_ArmNumericWrite up to
;      _HCW_NUMERIC_DEBOUNCE_MS ago lands on a timer. Reset All invalidates that
;      candidate, so it must disarm the timer without persisting the value the
;      action is about to clear. Flushing performs redundant I/O and can make a
;      refused obsolete write prevent the reset itself.
;   2. REPUBLISH AFTER. The loop clears delay and priority through the storage
;      primitives DIRECTLY, bypassing the _HCW_SetOverride / _HCW_ClearOverride
;      choke point where the republish lives. Delay and priority are baked into
;      every Spec at registration, so clearing them only bumps the resolve
;      generation: the window and the TOOLTIP then advertise the default delay
;      while the engine keeps gating on the value the user had set. That is the
;      G5 preview-without-fire direction — the tooltip promises an expansion the
;      engine refuses — and it is invisible in a test that exercises one handler.
;
; ROOT CAUSE ENCODED: the guarantee belongs to the ACTION ("resetting the
; overrides leaves the engine, the window and the tooltip agreeing"), not to one
; implementation of it. So this enumerates every reset handler and requires both
; steps in the right ORDER in each, and it fails when a THIRD presentation tier
; appears without them.
;
; SCOPE: source introspection. Both handlers mutate real config files, destroy a
; live Gui and drive a WebView2 controller, none of which this runner can host.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================================
; =====================================================================
; ======= 1/ Every reset handler cancels, then republishes =============
; =====================================================================
; =====================================================================

; Reset handlers, one per presentation tier. Derived by NAME rather than hardcoded
; to one file, so moving a handler between files does not silently drop it.
_HRR_ResetHandlers() {
	return ["_HCW_ResetAll", "_HCWWeb_ResetAll"]
}

_HRR_ReconcileHelper(Name) {
	static Helpers := Map(
		"_HCW_ResetAll", "_HCW_ReconcileNativeReset",
		"_HCWWeb_ResetAll", "_HCWWeb_ReconcileReset"
	)
	return Helpers[Name]
}

_HRR_EveryResetHandlerRepublishes() {
	Handlers := _HRR_ResetHandlers()
	Checked := 0
	for Name in Handlers {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Checked += 1

		; Non-vacuity: it must really build the reset plan, or the assertions below
		; could pass against a stub that does nothing.
		Assert(InStr(Body, "_HCW_CATEGORY_LIST") > 0,
			Name . " must still consume the category list")
		BuildPos := InStr(Body, "_HCW_BuildResetAllWrites(_HCW_CATEGORY_LIST)")
		Assert(BuildPos > 0, Name . " must still build every reset write")

		CancelPos := InStr(Body, "_HCW_CancelAllNumericWrites(")
		Assert(CancelPos > 0 and BuildPos > CancelPos,
			Name . " must cancel every pending numeric edit before clearing — the reset invalidates those candidates, so persisting them first is redundant and lets an obsolete refused write block the reset")
		Assert(InStr(Body, "_HCW_FlushNumericWrite(") == 0,
			Name . " must not flush an invalidated numeric edit during Reset All")

		ReconcileName := _HRR_ReconcileHelper(Name)
		ReconcilePos := InStr(Body, ReconcileName . ".Bind()")
		Assert(ReconcilePos > 0,
			Name . " must pass its aggregate outcome to " . ReconcileName . ". Delay and priority are baked into every Spec at registration and "
			. "this loop clears them through the storage primitives directly, bypassing the choke point where the "
			. "republish lives — so the window and the tooltip advertise the default delay while the engine keeps "
			. "gating on the old value, and the tooltip promises an expansion the engine refuses "
			. "(hcw-webview-reset-does-not-republish)")
		Assert(ReconcilePos > BuildPos,
			Name . " schedules reconciliation BEFORE it finishes collecting the writes")
		ReconcileBody := _DriverFuncBody(ReconcileName)
		Assert(InStr(ReconcileBody, "_HCW_RepublishIfBakedField(") > 0,
			ReconcileName . " must actually republish the live engine after the durable batch")
	}
	Builder := _DriverFuncBody("_HCW_BuildResetAllWrites")
	Assert(InStr(Builder, "_HCW_BuildResetAllPlan(") > 0,
		"the writer builder must consume the shared backend-neutral reset plan")
	Assert(InStr(Builder, "_HCW_PatchTomlMeta.Bind(") > 0
		and InStr(Builder, "HotstringsClearOverride.Bind(") > 0,
		"the shared builder must cover both personal TOML and override-store backends")
	Assert(Checked == Handlers.Length,
		"every enumerated reset handler must have been checked (checked " . Checked . " of " . Handlers.Length . ")")
}

; A third presentation tier must not be able to appear without this guard noticing.
; Any function whose name matches a reset-all shape has to be in the list above.
_HRR_TheHandlerListIsComplete() {
	Src := _DriverSourceNoComments()
	Known := Map()
	for Name in _HRR_ResetHandlers()
		Known[Name] := true

	Found := 0
	Missing := ""
	Pos := 1
	while (FoundPos := RegExMatch(Src, "m)^\s*(_HCW[A-Za-z0-9_]*ResetAll)\s*\(", &M, Pos)) {
		Pos := FoundPos + M.Len
		Found += 1
		if !Known.Has(M[1])
			Missing .= (Missing == "" ? "" : ", ") . M[1]
	}
	Assert(Found >= 2,
		"the scan must reach both reset handlers (found " . Found . ") — a scan that matches fewer cannot fail for "
		. "the tier it missed")
	Assert(Missing == "",
		"a reset-all handler exists that this guard does not check: " . Missing . ". Add it to _HRR_ResetHandlers() "
		. "— the cancel-then-republish rule belongs to the ACTION, and every presentation tier that offers it owes "
		. "the user the same guarantee (hcw-webview-reset-does-not-republish)")
}

_HRR_PersonalResetUsesTheCanonicalOverrideFieldPlan() {
	Builder := _DriverFuncBody("_HCW_BuildResetAllWrites")
	Assert(Builder != "",
		"both reset presentations must share one reset-plan writer instead of duplicating the personal TOML field list")
	PlanBuilder := _DriverFuncBody("_HCW_BuildResetAllPlan")
	Assert(InStr(PlanBuilder, "_PersonalTomlOverrideFields()") > 0,
		"the shared reset plan must derive personal fields from the canonical personal TOML override-field list, including show_tooltip")
	for Name in _HRR_ResetHandlers() {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "_HCW_BuildResetAllWrites(_HCW_CATEGORY_LIST)") > 0,
			Name . " must use the shared reset plan — a private delay/color/priority copy previously omitted show_tooltip in both frontends")
	}
}


Test("meta hcw-reset: every reset-all handler cancels then republishes (hcw-webview-reset-does-not-republish)",
	_HRR_EveryResetHandlerRepublishes)
Test("meta hcw-reset: no reset-all handler escapes the guard (hcw-webview-reset-does-not-republish)",
	_HRR_TheHandlerListIsComplete)
Test("meta hcw-reset: personal reset derives every override field from one plan (hcw-reset-personal-fields)",
	_HRR_PersonalResetUsesTheCanonicalOverrideFieldPlan)
