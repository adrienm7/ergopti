; tests/meta/test_kl_stop_flush_survives_suspend.ahk

; ==============================================================================
; MODULE: Keylogger Stop-Flush Suspend-Bypass Meta Test
; DESCRIPTION:
; Static source guard for the kl-stop-flush-defeated-by-suspend finding.
;
; When the driver is paused (A_IsSuspended) and the user quits or reloads,
; KL_Stop() calls KL_FlushBuffer() then KL_IngestOnce(). Both functions had
; early-return guards on A_IsSuspended, so quit-while-paused silently discarded
; every keystroke buffered since the last successful ingest cycle.
;
; The fix introduces Keylogger._shutting_down, published by KL_BeginShutdown()
; before KL_Stop() reaches the flush calls. The two suspend guards are amended
; to bypass on that flag so the shutdown flush is always allowed through
; regardless of pause state.
;
; Meta-static (scans source text) because keylogger.ahk cannot be #Included
; headlessly (it registers live hooks at load time).
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers ====================
; ====================================================
; ====================================================

_KSFS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ====================================================
; ====================================================
; ======= 2/ Shutdown-bypass assertions =============
; ====================================================
; ====================================================

_KSFS_ShutdownFlagDeclared() {
	Src := _KSFS_ReadSource("modules/keylogger/keylogger.ahk")
	Assert(InStr(Src, "_shutting_down") > 0,
		"Keylogger._shutting_down must be declared in keylogger.ahk (kl-stop-flush-defeated-by-suspend)")
	Assert(InStr(Src, "_shutting_down   := false") > 0,
		"Keylogger._shutting_down must initialise to false (kl-stop-flush-defeated-by-suspend)")
}
Test("keylogger: _shutting_down flag declared and initialised false (kl-stop-flush-defeated-by-suspend)", _KSFS_ShutdownFlagDeclared)

_KSFS_KLStopSetsFlag() {
	Src := _KSFS_ReadSource("modules/keylogger/keylogger.ahk")
	Body := _DriverFuncBody("KL_Stop")
	Assert(Body != "", "KL_Stop() must exist in keylogger.ahk")
	; The shutdown lease must be published BEFORE KL_FlushBuffer so its suspend
	; bypass is active during flush.  Verify the indirection owns the assignment,
	; rather than weakening this guard to a mere call-name check.
	BeginIdx := InStr(Body, "KL_BeginShutdown()")
	FlushIdx := InStr(Body, "KL_FlushBuffer()")
	Assert(BeginIdx > 0,
		"KL_Stop must publish the shutdown lease before flushing (kl-stop-flush-defeated-by-suspend)")
	Assert(FlushIdx > 0,
		"KL_Stop must call KL_FlushBuffer() (kl-stop-flush-defeated-by-suspend)")
	Assert(BeginIdx < FlushIdx,
		"KL_Stop must call KL_BeginShutdown BEFORE KL_FlushBuffer — the lease must be up when the flush guard runs (kl-stop-flush-defeated-by-suspend)")

	BeginBody := _DriverFuncBody("KL_BeginShutdown")
	Assert(BeginBody != "", "KL_BeginShutdown() must exist in keylogger.ahk")
	Assert(InStr(BeginBody, "_shutting_down := true") > 0,
		"KL_BeginShutdown must publish Keylogger._shutting_down := true (kl-stop-flush-defeated-by-suspend)")
}
Test("keylogger: KL_Stop() publishes shutdown lease before KL_FlushBuffer (kl-stop-flush-defeated-by-suspend)", _KSFS_KLStopSetsFlag)

_KSFS_AppendLogGuardBypasses() {
	Src := _KSFS_ReadSource("modules/keylogger/keylogger.ahk")
	Body := _DriverFuncBody("KL_AppendLog")
	Assert(Body != "", "KL_AppendLog() must exist in keylogger.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_AppendLog must still guard on A_IsSuspended (kl-stop-flush-defeated-by-suspend)")
	Assert(InStr(Body, "_shutting_down") > 0,
		"KL_AppendLog suspend guard must also check !Keylogger._shutting_down so shutdown flush is never blocked (kl-stop-flush-defeated-by-suspend)")
}
Test("keylogger: KL_AppendLog suspend guard includes _shutting_down bypass (kl-stop-flush-defeated-by-suspend)", _KSFS_AppendLogGuardBypasses)

_KSFS_IngestOnceGuardBypasses() {
	Src := _KSFS_ReadSource("modules/keylogger/keylogger.ahk")
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(Body != "", "KL_IngestOnce() must exist in keylogger.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_IngestOnce must still guard on A_IsSuspended (kl-stop-flush-defeated-by-suspend)")
	Assert(InStr(Body, "_shutting_down") > 0,
		"KL_IngestOnce suspend guard must also check !Keylogger._shutting_down so shutdown ingest is never blocked (kl-stop-flush-defeated-by-suspend)")
}
Test("keylogger: KL_IngestOnce suspend guard includes _shutting_down bypass (kl-stop-flush-defeated-by-suspend)", _KSFS_IngestOnceGuardBypasses)
