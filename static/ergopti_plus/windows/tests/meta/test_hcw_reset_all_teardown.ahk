; tests/meta/test_hcw_reset_all_teardown.ahk

; ==============================================================================
; MODULE: HCW ResetAll Teardown Guard Meta Test
; DESCRIPTION:
; Guards the fix for the _HCW_ResetAll() teardown regression where Gui.Destroy()
; was called without clearing _HCWGui and _HCWWidgets, and without flushing the
; pending debounce timer first.
;
; WHY THIS MATTERS:
;   Gui.Destroy() in AHK v2 does NOT fire the OnEvent('Close') callback, so the
;   _HCW_OnClose handler that clears _HCWGui and _HCWWidgets never ran after a
;   Reset All. Two consequences:
;   1. _HCWGui remained truthy (destroyed Gui reference) causing
;      OpenHotstringsConfigWindow to call _HCWGui.Show() on a destroyed object —
;      a bare `try` swallowed the throw, making the window impossible to reopen.
;   2. A still-armed _HCW_PendingNumericWrite debounce timer could fire
;      _HCW_FlushNumericWrite -> _HCW_LoadCurrent and access destroyed controls,
;      crashing the script.
;   Fix: declare _HCWWidgets in the global statement, flush the debounce before
;   destroying, then null both globals immediately after Destroy().
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
	Body := _DriverFuncBody("_HCW_ResetAll")
	Assert(Body != "", "_HCW_ResetAll must exist in hotstrings_config_window.ahk")
	; The global declaration must include _HCWWidgets so AHK treats the assignment
	; below as the module-level variable, not a new local
	Assert(InStr(Body, "_HCWWidgets") > 0,
		"_HCW_ResetAll must declare _HCWWidgets in its global statement (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCWWidgets present in function body (global declaration)", _HCWRA_WidgetsInGlobalDecl)

_HCWRA_GuiNulledAfterDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	Assert(InStr(Body, "_HCWGui := 0") > 0,
		"_HCW_ResetAll must set _HCWGui := 0 after Destroy() — Gui.Destroy() does not fire OnEvent('Close') (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCWGui is zeroed after Destroy()", _HCWRA_GuiNulledAfterDestroy)

_HCWRA_WidgetsNulledAfterDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	Assert(InStr(Body, "_HCWWidgets := 0") > 0,
		"_HCW_ResetAll must set _HCWWidgets := 0 after Destroy() to prevent debounce timer from accessing destroyed controls (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCWWidgets is zeroed after Destroy()", _HCWRA_WidgetsNulledAfterDestroy)

_HCWRA_FlushCalledBeforeDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	Assert(InStr(Body, "_HCW_FlushNumericWrite()") > 0,
		"_HCW_ResetAll must call _HCW_FlushNumericWrite() to drain the debounce timer before controls are destroyed (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCW_FlushNumericWrite() is called", _HCWRA_FlushCalledBeforeDestroy)

_HCWRA_FlushBeforeDestroy() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Body := _DriverFuncBody("_HCW_ResetAll")
	IdxFlush := InStr(Body, "_HCW_FlushNumericWrite()")
	IdxDestroy := InStr(Body, ".Destroy()")
	Assert(IdxFlush > 0 and IdxDestroy > 0 and IdxFlush < IdxDestroy,
		"_HCW_FlushNumericWrite() must appear BEFORE .Destroy() in _HCW_ResetAll — controls must still be live when flushed (hcw-reset-all-teardown)")
}
Test("hcw_reset_all: _HCW_FlushNumericWrite() appears before Destroy()", _HCWRA_FlushBeforeDestroy)

; F46 (2026-07-01 audit): _HCW_FlushNumericWrite() used to run AFTER the reset
; loop, not just before Destroy(). If a numeric edit (delay/priority) was still
; inside its 250ms debounce window when Reset All was clicked, that eager flush
; re-persisted the exact override the reset loop had just cleared moments
; earlier, silently un-resetting that one field. The fix moves the flush to the
; TOP of the function so it commits, and the reset loop then genuinely
; overwrites it last.
_HCWRA_FlushBeforeResetLoop() {
	Body := _DriverFuncBody("_HCW_ResetAll")
	IdxFlush := InStr(Body, "_HCW_FlushNumericWrite()")
	IdxLoop := InStr(Body, "for _, E in _HCW_CATEGORY_LIST")
	Assert(IdxFlush > 0 and IdxLoop > 0 and IdxFlush < IdxLoop,
		"_HCW_FlushNumericWrite() must run BEFORE the reset loop — flushing after the loop lets a still-pending debounced numeric edit silently re-commit the override the reset just cleared (hcw-reset-all-flush-order / F46)")
}
Test("hcw_reset_all: _HCW_FlushNumericWrite() runs before the reset loop, not after (F46)", _HCWRA_FlushBeforeResetLoop)
