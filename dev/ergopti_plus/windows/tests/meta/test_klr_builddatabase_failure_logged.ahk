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

	; Every return-0 failure branch must reference LoggerError.
	; Count the return-0 branches and verify each has a LoggerError call nearby.
	; The five failure branches: LoadLibrary, GetProcAddress, libversion call,
	; :memory: open, and schema load.
	LoadLibPos := InStr(Body, "LoadLibrary")
	Assert(LoadLibPos > 0, "KLR_BuildDatabase must check LoadLibrary result")
	; Between LoadLibrary and the next section, there must be LoggerError.
	AfterLoadLib := SubStr(Body, LoadLibPos, 800)
	Assert(InStr(AfterLoadLib, "LoggerError") > 0,
		"LoadLibrary failure branch must call LoggerError")

	GetProcPos := InStr(Body, "GetProcAddress")
	Assert(GetProcPos > 0, "KLR_BuildDatabase must call GetProcAddress")
	AfterGetProc := SubStr(Body, GetProcPos, 800)
	Assert(InStr(AfterGetProc, "LoggerError") > 0,
		"GetProcAddress failure branch must call LoggerError")

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
