; tests/meta/test_config_window_delay_write_per_keystroke.ahk

; ==============================================================================
; MODULE: Config-Window Numeric-Edit Debounce Meta Test
; DESCRIPTION:
; Static source guard for finding config-window-delay-write-per-keystroke.
;
; The delay / priority Edit fields fire a "Change" event on every keystroke.
; The old handlers persisted immediately: _HCW_SetOverride is a synchronous
; override-file rewrite (and for personal entries _HCW_PatchTomlMeta re-reads +
; re-serialises the whole TOML), so typing a 4-digit delay rewrote the file on
; every digit and flushed the resolve memo each time.
;
; The fix debounces the numeric write: the Change handlers now arm a one-shot
; SetTimer (_HCW_ArmNumericWrite -> _HCW_FlushNumericWrite) so a burst of digits
; coalesces into a single _HCW_SetOverride once the user pauses. This test pins
; that structure in source: if a future edit makes _HCW_OnDelayChanged call
; _HCW_SetOverride directly again (per-keystroke writes), the guard fails.
;
; Meta-static (scans source text) because hotstrings_config_window.ahk is NOT in
; the headless run_all include graph (it builds a native Gui at top level and
; touches GUI widgets), so the debounce functions cannot be called directly in
; the headless runner without a load-time error that hangs CI.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; A_ScriptDir is the runner dir (tests/); its parent is the windows/ driver root.




; ==================================================
; ==================================================
; ======= 2/ Debounce structure assertions =========
; ==================================================
; ==================================================

_CWDW_Source() {
	return _DriverDirConcat("ui/hotstrings_config_window")
}

; The Change handler must NOT persist directly -- it arms the debounce instead.
_CWDW_DelayHandlerDoesNotWriteDirectly() {
	Src := _CWDW_Source()
	Seg := _DriverFuncBody("_HCW_OnDelayChanged")
	Assert(Seg != "", "_HCW_OnDelayChanged must exist in hotstrings_config_window.ahk")
	Assert(InStr(Seg, "_HCW_ArmNumericWrite") > 0,
		"_HCW_OnDelayChanged must arm the debounce via _HCW_ArmNumericWrite, not persist per keystroke")
	Assert(InStr(Seg, "_HCW_SetOverride") == 0,
		"_HCW_OnDelayChanged must NOT call _HCW_SetOverride directly -- that rewrote the override file on every digit typed")
}
Test("hs_config: _HCW_OnDelayChanged debounces instead of writing per keystroke (config-window-delay-write-per-keystroke)", _CWDW_DelayHandlerDoesNotWriteDirectly)

_CWDW_PriorityHandlerDoesNotWriteDirectly() {
	Src := _CWDW_Source()
	Seg := _DriverFuncBody("_HCW_OnPriorityChanged")
	Assert(Seg != "", "_HCW_OnPriorityChanged must exist in hotstrings_config_window.ahk")
	Assert(InStr(Seg, "_HCW_ArmNumericWrite") > 0,
		"_HCW_OnPriorityChanged must arm the debounce via _HCW_ArmNumericWrite, not persist per keystroke")
	Assert(InStr(Seg, "_HCW_SetOverride") == 0,
		"_HCW_OnPriorityChanged must NOT call _HCW_SetOverride directly -- that rewrote the override file on every digit typed")
}
Test("hs_config: _HCW_OnPriorityChanged debounces instead of writing per keystroke (config-window-delay-write-per-keystroke)", _CWDW_PriorityHandlerDoesNotWriteDirectly)

; The arm helper must start a one-shot (negative interval) SetTimer that targets
; the single flush callback -- that is what coalesces the burst into one write.
_CWDW_ArmUsesOneShotTimer() {
	Src := _CWDW_Source()
	Seg := _DriverFuncBody("_HCW_ArmNumericWrite")
	Assert(Seg != "", "_HCW_ArmNumericWrite must exist in hotstrings_config_window.ahk")
	Assert(InStr(Seg, "_HCW_QueueNumericWrite") > 0,
		"_HCW_ArmNumericWrite must queue by entry/section/field instead of replacing one global slot — typing delay then priority inside the same debounce window must persist both values")
	Assert(InStr(Seg, "SetTimer(_HCW_FlushNumericWrite, -_HCW_NUMERIC_DEBOUNCE_MS)") > 0,
		"_HCW_ArmNumericWrite must re-arm a one-shot SetTimer (negative _HCW_NUMERIC_DEBOUNCE_MS) so each keystroke coalesces into a single deferred write")
}
Test("hs_config: numeric write is armed as a one-shot debounce timer (config-window-delay-write-per-keystroke)", _CWDW_ArmUsesOneShotTimer)

; The single deferred write must happen inside the flush callback.
_CWDW_FlushPerformsSingleWrite() {
	Src := _CWDW_Source()
	Seg := _DriverFuncBody("_HCW_FlushNumericWrite")
	Assert(Seg != "", "_HCW_FlushNumericWrite must exist in hotstrings_config_window.ahk")
	Assert(InStr(Seg, "_HCW_RunNumericWriteBatch") > 0,
		"_HCW_FlushNumericWrite must drain every distinct queued field through one aggregate persistence batch")
}
Test("hs_config: debounce flush drains every queued field (config-window-delay-write-per-keystroke)", _CWDW_FlushPerformsSingleWrite)

_CWDW_FieldResetCancelsItsPendingWrite() {
	Body := _DriverFuncBody("_HCW_ClearField")
	CancelPos := InStr(Body, "_HCW_CancelNumericWrite(Entry, Sec, Field)")
	ClearPos := InStr(Body, "_HCW_ClearOverride.Bind(")
	Assert(CancelPos > 0 and ClearPos > CancelPos,
		"_HCW_ClearField must cancel the matching debounced value before clearing it — otherwise the armed timer silently restores the value the user just reset")
}
Test("hs_config: field reset invalidates its matching debounced write",
	_CWDW_FieldResetCancelsItsPendingWrite)
