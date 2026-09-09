; tests/meta/test_klr_builddatabase_failure_logged.ahk

; ==============================================================================
; MODULE: KLR_BuildDatabase Failure Logging Guard
; DESCRIPTION:
; Guards that terminal failure branches in KLR_BuildDatabase and
; KLPF_BuildAndWriteToPath emit a real central-log ERROR, not just a DEBUG-gated
; sidecar KLR_PrefetchDebug entry. The module header explicitly promises
; "a missing schema.sql, an invalid data.sql, or an absent winsqlite3.dll
; all surface immediately as Logger.error." Before the fix, none of the
; return-0 branches called LoggerError — a deployment failure made the
; metrics dashboard silently show "no data" with zero trace in
; ErgoptiPlus.log.
; ==============================================================================

#Requires AutoHotkey v2.0


_MetaCheckKlrBuildDatabaseFailureLogged() {
	Body := _DriverFuncBody("KLR_BuildDatabase")
	Assert(Body != "", "KLR_BuildDatabase(metrics_dir) must exist in keylogger_reader_db.ahk")

	; Load, symbol lookup, and version failures now share the module owner's
	; throwing boundary. The reader must log any rejected initialization there.
	ModulePos := InStr(Body, "SQLite_EnsureModule")
	Assert(ModulePos > 0, "KLR_BuildDatabase must acquire the validated module owner")
	AfterModule := SubStr(Body, ModulePos, 800)
	Assert(InStr(AfterModule, "catch") > 0 && InStr(AfterModule, "LoggerError") > 0,
		"module initialization failure must reach the central error logger")

	; The worker invokes KLPF_BuildAndWriteToPath, so its if !db branch must log.
	PrefetchBody := _DriverFuncBody("KLPF_BuildAndWriteToPath")
	Assert(PrefetchBody != "", "KLPF_BuildAndWriteToPath must exist in keylogger_prefetch.ahk")
	DbFailPos := InStr(PrefetchBody, "KLR_BuildDatabase returned 0")
	Assert(DbFailPos > 0, "KLPF_BuildAndWriteToPath must check KLR_BuildDatabase result")
	AfterDbFail := SubStr(PrefetchBody, DbFailPos, 500)
	Assert(InStr(AfterDbFail, "LoggerError") > 0,
		"KLPF_BuildAndWriteToPath's if !db branch must call LoggerError")
}

Test("meta metrics DB: KLR_BuildDatabase + KLPF_BuildAndWriteToPath failure branches log to central Logger",
	_MetaCheckKlrBuildDatabaseFailureLogged)
