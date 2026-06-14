; tests/meta/test_ingest_tick_guards.ahk

; ==============================================================================
; MODULE: Ingest Tick Guards Meta Test
; DESCRIPTION:
; Static source guard for the ingest-tick-blocks-keyboard-thread and
; ingest-prefetch-blocks-keyboard-thread findings.
;
; KL_IngestOnce runs on the 5 s ingest timer (same AHK pseudo-thread as the
; keyboard hook). Two blocking operations can cause it to exceed
; LowLevelHooksTimeout (~300 ms) and silently drop keystrokes:
;
; 1. FileAppend of multi-KB SQL bodies to data.sql — mitigated by the fact
;    that antivirus-held file handles stall synchronous writes.
;
; 2. KLWV_NotifyIngest() — full "live" dashboard rebuild (150-300 ms of
;    SQLite + JSON work) that runs during any typing burst when a WebView2
;    dashboard is open.
;
; The fix adds two guards to KL_IngestOnce:
; a) if A_IsSuspended return — short-circuits the entire tick while paused
;    (no new events are written during suspension, so the work is redundant
;    AND violates the pause invariant).
; b) Keyboard-idle gate before KLWV_NotifyIngest: the heavy rebuild is
;    deferred to the next tick if the user typed within
;    KeylogConst.INGEST_LIVE_PUSH_IDLE_MS ms, preventing the 150-300 ms
;    rebuild from running mid-burst.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_IATG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts the body of a function starting at FuncDef up to the first
; unindented closing brace, stripping comment lines.
_IATG_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ===================================================
; ===================================================
; ======= 2/ KL_IngestOnce assertions ==============
; ===================================================
; ===================================================

_IATG_IngestHasSuspendGuard() {
	Src := _IATG_ReadSource("modules/keylogger/keylogger.ahk")
	Body := _IATG_FuncBodyStripped(Src, "KL_IngestOnce() {")
	Assert(Body != "", "KL_IngestOnce must exist in modules/keylogger/keylogger.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_IngestOnce must check A_IsSuspended — the 5s ingest tick must not run heavy I/O while the driver is paused (pause-invariant violation and unnecessary work)")
}
Test("keylogger: KL_IngestOnce has A_IsSuspended early-return (ingest-tick-blocks-keyboard-thread)", _IATG_IngestHasSuspendGuard)

_IATG_IngestLivePushGated() {
	Src := _IATG_ReadSource("modules/keylogger/keylogger.ahk")
	Body := _IATG_FuncBodyStripped(Src, "KL_IngestOnce() {")
	Assert(Body != "", "KL_IngestOnce must exist in modules/keylogger/keylogger.ahk")
	Assert(InStr(Body, "KLWV_NotifyIngest") > 0,
		"KL_IngestOnce must reference KLWV_NotifyIngest (the live-push call must exist in this function)")
	; The live-push must be gated — it must appear after a KLHook.last_tick check
	; (or similar idle-guard) so it does not run during a typing burst
	Assert(InStr(Body, "KLHook.last_tick") > 0,
		"KL_IngestOnce must gate KLWV_NotifyIngest with a KLHook.last_tick idle check to prevent 150-300 ms rebuild during a typing burst (ingest-prefetch-blocks-keyboard-thread)")
}
Test("keylogger: KL_IngestOnce gates KLWV_NotifyIngest behind KLHook.last_tick idle check (ingest-prefetch-blocks-keyboard-thread)", _IATG_IngestLivePushGated)




; ===================================================
; ===================================================
; ======= 3/ KeylogConst assertions ================
; ===================================================
; ===================================================

_IATG_ConstHasLivePushIdle() {
	Src := _IATG_ReadSource("modules/keylogger/keylogger.ahk")
	Assert(InStr(Src, "INGEST_LIVE_PUSH_IDLE_MS") > 0,
		"KeylogConst must declare INGEST_LIVE_PUSH_IDLE_MS — the named constant for the keyboard-idle threshold before allowing the full dashboard rebuild")
}
Test("keylogger: KeylogConst declares INGEST_LIVE_PUSH_IDLE_MS constant (ingest-tick-blocks-keyboard-thread)", _IATG_ConstHasLivePushIdle)
