; tests/meta/test_hcw_reset_all_teardown.ahk

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
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_CompleteNativeReset")
	Assert(Body != "", "_HCW_CompleteNativeReset must own successful teardown")
	; The global declaration must include _HCWWidgets so AHK treats the assignment
	; below as the module-level variable, not a new local
	Assert(InStr(Body, "_HCWWidgets") > 0,
		"_HCW_CompleteNativeReset must declare _HCWWidgets in its global statement (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: success-only teardown owns the global widget handle", _HCWRA_WidgetsInGlobalDecl)

_HCWRA_GuiNulledAfterDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_CompleteNativeReset")
	Assert(InStr(Body, "_HCWGui := 0") > 0,
		"successful reset teardown must set _HCWGui := 0 after Destroy() — Gui.Destroy() does not fire OnEvent('Close') (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCWGui is zeroed after Destroy()", _HCWRA_GuiNulledAfterDestroy)

_HCWRA_WidgetsNulledAfterDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_CompleteNativeReset")
	Assert(InStr(Body, "_HCWWidgets := 0") > 0,
		"successful reset teardown must set _HCWWidgets := 0 after Destroy() to prevent debounce timer from accessing destroyed controls (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCWWidgets is zeroed after Destroy()", _HCWRA_WidgetsNulledAfterDestroy)

_HCWRA_CancelCalledBeforeDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	Assert(InStr(Body, "_HCW_CancelAllNumericWrites()") > 0,
		"_HCW_ResetAll must discard and disarm pending numeric writes before controls are destroyed (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: pending numeric writes are cancelled", _HCWRA_CancelCalledBeforeDestroy)

_HCWRA_CancelBeforeDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	IdxCancel := InStr(Body, "_HCW_CancelAllNumericWrites()")
	IdxSuccess := InStr(Body, "_HCW_CompleteNativeReset.Bind()")
	Assert(IdxCancel > 0 and IdxSuccess > 0 and IdxCancel < IdxSuccess,
		"pending numeric writes must be cancelled before the success-only teardown callback (hcw-reset-all-teardown)")
	Assert(InStr(Body, "_HCW_FlushNumericWrite()") == 0,
		"Reset All must not persist a debounced candidate it is about to erase")
	Assert(InStr(Body, ".Destroy()") == 0,
		"_HCW_ResetAll must not destroy the editor outside its all-writes-success callback")
	SuccessBody := _DriverFuncBody("_HCW_CompleteNativeReset")
	IdxDestroy := InStr(SuccessBody, ".Destroy()")
	IdxGuiZero := InStr(SuccessBody, "_HCWGui := 0")
	IdxWidgetsZero := InStr(SuccessBody, "_HCWWidgets := 0")
	Assert(IdxDestroy > 0 and IdxGuiZero > IdxDestroy and IdxWidgetsZero > IdxDestroy,
		"the successful teardown callback must clear both handles after Destroy()")
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
