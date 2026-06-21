; tests/meta/test_ingest_tick_guards.ahk

; ==============================================================================
; MODULE: Ingest Tick Guards Meta Test
; DESCRIPTION:
; Static source guards for the ingest-tick-blocks-keyboard-thread and
; ingest-prefetch-blocks-keyboard-thread findings.
;
; KL_IngestOnce() perform heavy tasks (SQL conversion, FileAppend to data.sql,
; and WebView2 live notification) that can take ~100-300 ms. Running these
; while the user is actively typing can exceed the LowLevelHooksTimeout and
; cause dropped keystrokes.
;
; The fix adds two keyboard-idle guards using KLHook.last_tick:
;   1. Before the SQL conversion / FileAppend.
;   2. Before the WebView2 notification (KLWV_NotifyIngest).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_ITG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Ingest guards assertion ================
; ===================================================
; ===================================================

_ITG_IngestHasIdleGuards() {
	Src := _ITG_ReadSource("modules/keylogger/keylogger.ahk")
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(Body != "", "KL_IngestOnce must exist in keylogger.ahk")
	
	Assert(InStr(Body, "INGEST_IDLE_MS") > 0,
		"KL_IngestOnce must check INGEST_IDLE_MS before the heavy SQL conversion/FileAppend (ingest-tick-blocks-keyboard-thread)")
	
	Assert(InStr(Body, "INGEST_LIVE_PUSH_IDLE_MS") > 0,
		"KL_IngestOnce must check INGEST_LIVE_PUSH_IDLE_MS before calling KLWV_NotifyIngest (ingest-prefetch-blocks-keyboard-thread)")
}
Test("keylogger: KL_IngestOnce has idle guards for heavy tasks (ingest-tick-blocks-keyboard-thread)", _ITG_IngestHasIdleGuards)
