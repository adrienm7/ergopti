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
;   1. FLUSH FIRST. A numeric edit armed by _HCW_ArmNumericWrite up to
;      _HCW_NUMERIC_DEBOUNCE_MS ago lands on a timer. If the reset loop runs
;      first, that pending write persists on top of the override the loop just
;      cleared, silently un-resetting one field.
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
; ======= 1/ Every reset handler flushes, then republishes =============
; =====================================================================
; =====================================================================

; Reset handlers, one per presentation tier. Derived by NAME rather than hardcoded
; to one file, so moving a handler between files does not silently drop it.
_HRR_ResetHandlers() {
	return ["_HCW_ResetAll", "_HCWWeb_ResetAll"]
}

_HRR_EveryResetHandlerRepublishes() {
	Handlers := _HRR_ResetHandlers()
	Checked := 0
	for Name in Handlers {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Checked += 1

		; Non-vacuity: it must really be a reset, or the assertions below could pass
		; against a stub that does nothing.
		Assert(InStr(Body, "_HCW_CATEGORY_LIST") > 0,
			Name . " must still walk the category list — otherwise it is not the reset handler this guard means")
		ClearPos := InStr(Body, "HotstringsClearOverride(")
		Assert(ClearPos > 0, Name . " must still clear the overrides")

		FlushPos := InStr(Body, "_HCW_FlushNumericWrite(")
		Assert(FlushPos > 0,
			Name . " must flush a pending debounced numeric edit BEFORE clearing. A write armed up to "
			. "_HCW_NUMERIC_DEBOUNCE_MS ago otherwise lands after the loop and persists on top of the override it "
			. "just cleared, silently un-resetting that field (hcw-webview-reset-does-not-republish)")
		Assert(FlushPos < ClearPos,
			Name . " flushes the pending numeric edit AFTER the clearing loop, which is the ordering the flush "
			. "exists to prevent — the pending write becomes the last writer")

		RepublishPos := InStr(Body, "_HCW_RepublishIfBakedField(")
		Assert(RepublishPos > 0,
			Name . " must republish after clearing. Delay and priority are baked into every Spec at registration and "
			. "this loop clears them through the storage primitives directly, bypassing the choke point where the "
			. "republish lives — so the window and the tooltip advertise the default delay while the engine keeps "
			. "gating on the old value, and the tooltip promises an expansion the engine refuses "
			. "(hcw-webview-reset-does-not-republish)")
		Assert(RepublishPos > ClearPos,
			Name . " republishes BEFORE it finishes clearing, so the rebuild captures state the loop then changes")
	}
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
		. "— the flush-then-republish rule belongs to the ACTION, and every presentation tier that offers it owes "
		. "the user the same guarantee (hcw-webview-reset-does-not-republish)")
}


Test("meta hcw-reset: every reset-all handler flushes then republishes (hcw-webview-reset-does-not-republish)",
	_HRR_EveryResetHandlerRepublishes)
Test("meta hcw-reset: no reset-all handler escapes the guard (hcw-webview-reset-does-not-republish)",
	_HRR_TheHandlerListIsComplete)
