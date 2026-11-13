; tests/meta/hotstrings/engine/catalogue/test_hcw_reset_all_teardown.ahk

; ==============================================================================
; MODULE: HCW ResetAll Teardown Guard Meta Test
; DESCRIPTION:
; Guards the fix for the _HCW_ResetAll() teardown regression where Gui.Destroy()
; was called without clearing _HCWGui and _HCWWidgets, and without cancelling
; the pending debounce timer first.
;
; WHY THIS MATTERS:
;   Gui.Destroy() in AHK v2 does NOT fire the OnEvent('Close') callback, so the
;   _HCW_OnClose handler that clears _HCWGui and _HCWWidgets never ran after a
;   Reset All. Two consequences:
;   1. _HCWGui remained truthy (destroyed Gui reference) causing
;      OpenHotstringsConfigWindow to call _HCWGui.Show() on a destroyed object —
;      a bare `try` swallowed the throw, making the window impossible to reopen.
;   2. A still-armed _HCW_PendingNumericWrites debounce timer could fire
;      _HCW_FlushNumericWrite -> _HCW_LoadCurrent and access destroyed controls,
;      crashing the script.
;   Fix: declare _HCWWidgets in the global statement, cancel the debounce before
;   destroying, then null both globals immediately after Destroy(). Reset All
;   must discard, not persist, a candidate it explicitly invalidates.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================================
; =================================================================
; ======= 1/ Source scan helpers ==================================
; =================================================================
; =================================================================






; =================================================================
; =================================================================
; ======= 2/ Teardown assertions ==================================
; =================================================================
; =================================================================

_HCWRA_WidgetsInGlobalDecl() {
	Src := _DriverDirConcat("hotstrings/ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_CompleteNativeReset")
	Assert(Body != "", "_HCW_CompleteNativeReset must own successful teardown")
	; The global declaration must include _HCWWidgets so AHK treats the assignment
	; below as the module-level variable, not a new local
	Assert(InStr(Body, "_HCWWidgets") > 0,
		"_HCW_CompleteNativeReset must declare _HCWWidgets in its global statement (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: success-only teardown owns the global widget handle", _HCWRA_WidgetsInGlobalDecl)

_HCWRA_GuiDetachedBeforeRetirement() {
	Src := _DriverDirConcat("hotstrings/ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_CompleteNativeReset")
	Assert(InStr(Body, "_HCWGui := 0") > 0,
		"successful reset teardown must detach _HCWGui before native retirement — a reentrant Open must not reuse A (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCWGui is detached before native retirement", _HCWRA_GuiDetachedBeforeRetirement)

_HCWRA_WidgetsDetachedBeforeRetirement() {
	Src := _DriverDirConcat("hotstrings/ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_CompleteNativeReset")
	Assert(InStr(Body, "_HCWWidgets := 0") > 0,
		"successful reset teardown must detach _HCWWidgets before native retirement so old completion cannot clear B (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCWWidgets is detached before native retirement", _HCWRA_WidgetsDetachedBeforeRetirement)

_HCWRA_CancelCalledBeforeDestroy() {
	Src := _DriverDirConcat("hotstrings/ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	Assert(InStr(Body, "_HCW_CancelAllNumericWrites()") > 0,
		"_HCW_ResetAll must discard and disarm pending numeric writes before controls are destroyed (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: pending numeric writes are cancelled", _HCWRA_CancelCalledBeforeDestroy)

; Source-level companion to native WM_DESTROY and explicit retirement-fault
; controls. Follow the actual record into its native cleanup helper.
_HCWRA_CustodyBeforeRetirement(Complete, Retry) {
	Code := _DriverMaskNonCode(&Complete)
	Cleanup := _DriverMaskNonCode(&Retry)
	Capture := InStr(Code, "Host := {window: _HCWGui")
	Widgets := InStr(Code, "widgets: _HCWWidgets")
	Queue := InStr(Code, "_HCW_RetiredNativeResets.Push(Host)")
	GuiZero := InStr(Code, "_HCWGui := 0")
	WidgetsZero := InStr(Code, "_HCWWidgets := 0")
	Drain := InStr(Code, "_HCW_RetryRetiredNativeResets()")
	Destroy := InStr(Cleanup, "Window.Destroy()")
	return Capture > 0 && Widgets > Capture && Queue > Widgets
		&& GuiZero > Queue && WidgetsZero > Queue && Drain > GuiZero && Drain > WidgetsZero
		&& !InStr(Code, ".Destroy()") && InStr(Cleanup, "Window := Host.window") > 0
		&& Destroy > InStr(Cleanup, "Window := Host.window")
		&& InStr(Cleanup, "Host.window := 0") > Destroy
		&& !InStr(Cleanup, "_HCWGui := 0") && !InStr(Cleanup, "_HCWWidgets := 0")
}

_HCWRA_CancelBeforeDestroy() {
	Src := _DriverDirConcat("hotstrings/ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	IdxCancel := InStr(Body, "_HCW_CancelAllNumericWrites()")
	IdxSuccess := InStr(Body, "_HCW_CompleteNativeReset.Bind(_HCWGui)")
	Assert(IdxCancel > 0 and IdxSuccess > 0 and IdxCancel < IdxSuccess,
		"pending numeric writes must be cancelled before the success-only teardown callback (hcw-reset-all-teardown)")
	Assert(InStr(Body, "_HCW_FlushNumericWrite()") == 0,
		"Reset All must not persist a debounced candidate it is about to erase")
	Assert(InStr(Body, ".Destroy()") == 0,
		"_HCW_ResetAll must not destroy the editor outside its all-writes-success callback")
	SuccessBody := _DriverFuncBody("_HCW_CompleteNativeReset")
	RetryBody := _DriverFuncBody("_HCW_RetryRetiredNativeResets")
	AssertTrue(_HCWRA_CustodyBeforeRetirement(SuccessBody, RetryBody),
		"success must retain exact cleanup custody and detach both globals before native retirement")
	AssertFalse(_HCWRA_CustodyBeforeRetirement(StrReplace(SuccessBody,
		"_HCW_RetiredNativeResets.Push(Host)", "; _HCW_RetiredNativeResets.Push(Host)"), RetryBody),
		"commented cleanup custody cannot qualify")
	AssertFalse(_HCWRA_CustodyBeforeRetirement(StrReplace(SuccessBody,
		"window: _HCWGui", "window: Foreign"), RetryBody),
		"a foreign retained window cannot qualify")
	AssertFalse(_HCWRA_CustodyBeforeRetirement(StrReplace(SuccessBody,
		"_HCWGui := 0", "Host.window.Destroy()"), RetryBody),
		"destroying before detachment cannot qualify")
}
Test("hcw_reset_all: cancellation precedes success-only teardown", _HCWRA_CancelBeforeDestroy)

; F46 (2026-07-01 audit): a pending debounce used to run after the reset loop
; and silently restore the cleared value. Flushing it first fixed ordering but
; added an obsolete write whose failure can abort Reset All. Cancellation at
; the top preserves the original guarantee without I/O.
_HCWRA_CancelBeforeResetLoop() {
	Body := _DriverFuncBody("_HCW_ResetAll")
	IdxCancel := InStr(Body, "_HCW_CancelAllNumericWrites()")
	IdxBuild := InStr(Body, "_HCW_BuildResetAllWrites(_HCW_CATEGORY_LIST)")
	Assert(IdxCancel > 0 and IdxBuild > 0 and IdxCancel < IdxBuild,
		"_HCW_CancelAllNumericWrites() must run BEFORE building the reset writes so no timer can re-commit a cleared override (hcw-reset-all-flush-order / F46)")
}
Test("hcw_reset_all: numeric cancellation runs before the reset plan (F46)",
	_HCWRA_CancelBeforeResetLoop)
