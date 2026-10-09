; tests/meta/test_keylogger_pause_metrics.ahk

; ==============================================================================
; MODULE: Keylogger Pause Metrics Meta Test
; DESCRIPTION:
; Static source guard for the "pause_before_ms always 0" bug. Before the fix,
; KL_FlushBuffer read Keylogger.current_pause_ms (a field that was declared and
; initialised to 0 but never updated), so every typing event recorded
; pause_before_ms = 0, corrupting the think-pause analytics. The fix uses the
; delay of the first keystroke in the buffer as the inter-burst gap.
; ==============================================================================

#Requires AutoHotkey v2.0

; The dead Keylogger.current_pause_ms field must no longer appear in the source.
; If it reappears, pause_before_ms will be hardcoded 0 again.
_TKPM_DeadFieldRemoved() {
	Src := _DriverSourceConcat()
	Assert(!InStr(Src, "current_pause_ms"),
		"Keylogger must not declare or use current_pause_ms — it was never updated and hardcoded pause_before_ms to 0")
}

; snap_pause must be derived from snap_events[1][2] (first event delay = inter-burst gap).
; Any literal use of a hard-zero fallback without this expression indicates a regression.
_TKPM_SnapPauseUsesFirstEventDelay() {
	Src := _DriverDirConcat("modules/keylogger")
	Assert(InStr(Src, "snap_events[1][2]") > 0,
		"KL_FlushBuffer must use snap_events[1][2] as snap_pause (first event delay = inter-burst gap)")
}

Test("Keylogger: dead current_pause_ms field is removed", _TKPM_DeadFieldRemoved)
Test("Keylogger: snap_pause uses first event delay (inter-burst gap)", _TKPM_SnapPauseUsesFirstEventDelay)
