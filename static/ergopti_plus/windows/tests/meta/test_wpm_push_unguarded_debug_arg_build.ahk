; tests/meta/test_wpm_push_unguarded_debug_arg_build.ahk

; ==============================================================================
; MODULE: WPM Push Debug-Gate Guard (wpm-push-unguarded-debug-arg-build)
; DESCRIPTION:
; Static source guard for the wpm-push-unguarded-debug-arg-build finding.
;
; WPMWidget_Push runs on the per-keystroke hot path. logger.ahk documents that
; high-frequency call sites must gate their LoggerDebug with
; LoggerIsDebugEnabled() so the variadic arg-array and string interpolation are
; not built when DEBUG is disabled (the prefix watcher and HSE fire path all
; follow this). The fix wraps the per-Push LoggerDebug line in
; `if LoggerIsDebugEnabled()` so nothing is interpolated below DEBUG level.
;
; This is a meta-static test: ui/wpm/ registers GUI / timer state and is NOT in
; the headless run_all include graph, so a source-text guard is the only
; automated net available. It introspects one function body via _DriverFuncBody
; (whole-tree, split-resilient). ASCII-only per the suite convention. If the gate
; is removed this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Debug-gate assertion ==================
; ==================================================
; ==================================================

_WpmDbg_PushDebugIsGated() {
	Seg := _DriverFuncBody("WPMWidget_Push")
	Assert(Seg != "", "WPMWidget_Push declaration must exist in ui/wpm/")

	DbgIdx := InStr(Seg, "LoggerDebug(")
	Assert(DbgIdx > 0,
		"WPMWidget_Push must still emit the per-keystroke LoggerDebug line this test guards")

	; The DEBUG gate must appear before the LoggerDebug call within this body so
	; the arg array is built only when DEBUG is actually on (logger.ahk convention).
	GateIdx := InStr(Seg, "LoggerIsDebugEnabled()")
	Assert(GateIdx > 0 && GateIdx < DbgIdx,
		"WPMWidget_Push must gate its per-keystroke LoggerDebug behind 'if LoggerIsDebugEnabled()' so the arg array is not built when DEBUG is off (hot-path convention from logger.ahk)")
}
Test("wpm_widget: WPMWidget_Push gates its per-keystroke LoggerDebug on LoggerIsDebugEnabled (wpm-push-unguarded-debug-arg-build)", _WpmDbg_PushDebugIsGated)
