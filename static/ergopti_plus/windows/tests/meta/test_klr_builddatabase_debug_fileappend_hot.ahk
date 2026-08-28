; tests/meta/test_klr_builddatabase_debug_fileappend_hot.ahk

; ==============================================================================
; MODULE: KLR_BuildDatabase Debug-FileAppend Gate Meta Test
; DESCRIPTION:
; Static source guard for finding klr-builddatabase-debug-fileappend-hot.
;
; KLR_BuildDatabase / KLR_ApplyIncremental used to FileAppend 6+ diagnostic
; lines to prefetch.log on EVERY build. The build runs on every ingest tick
; (~5 s while a dashboard is open) and can land on the keystroke-servicing
; thread, so each open+write+close paid the NTFS/AV tax the rest of the module
; works to avoid, and grew prefetch.log without bound.
;
; The fix funnels every diagnostic line through KLR_PrefetchDebug and then the
; central bounded-debug owner. In normal operation (LOGGER_MIN_LEVEL=INFO) the
; whole instrumentation path collapses to a boolean test and writes nothing.
;
; This guard fails if any FileAppend reappears inside KLR_BuildDatabase or
; KLR_ApplyIncremental, or if the central owner loses its debug gate or cap.
;
; Meta-static (scans source text) because keylogger_reader.ahk is not part of
; the run_all.ahk include graph; calling its functions at load time would be a
; LOAD-TIME error that hangs the headless suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_KLRDBG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Hot-path FileAppend guard =============
; ==================================================
; ==================================================

_KLRDBG_BuildHasNoRawFileAppend() {
	Src := _KLRDBG_ReadSource("modules/keylogger/keylogger_reader.ahk")
	Seg := _DriverFuncBody("KLR_BuildDatabase")
	Assert(Seg != "", "KLR_BuildDatabase(metrics_dir) declaration must exist in keylogger_reader.ahk")
	Assert(!InStr(Seg, "FileAppend"),
		"KLR_BuildDatabase must not call FileAppend directly - the build runs every ingest tick and can land on the keystroke thread; route diagnostics through the debug-gated KLR_PrefetchDebug helper")
}
Test("keylogger_reader: KLR_BuildDatabase has no ungated FileAppend (klr-builddatabase-debug-fileappend-hot)", _KLRDBG_BuildHasNoRawFileAppend)

_KLRDBG_IncrementalHasNoRawFileAppend() {
	Src := _KLRDBG_ReadSource("modules/keylogger/keylogger_reader.ahk")
	Seg := _DriverFuncBody("KLR_ApplyIncremental")
	Assert(Seg != "", "KLR_ApplyIncremental(db, md, logPath) declaration must exist in keylogger_reader.ahk")
	Assert(!InStr(Seg, "FileAppend"),
		"KLR_ApplyIncremental must not call FileAppend directly - it runs on the same hot ingest path; route diagnostics through KLR_PrefetchDebug")
}
Test("keylogger_reader: KLR_ApplyIncremental has no ungated FileAppend (klr-builddatabase-debug-fileappend-hot)", _KLRDBG_IncrementalHasNoRawFileAppend)

_KLRDBG_PrefetchDebugGatesOnDebugFlag() {
	Seg := _DriverFuncBody("KLR_PrefetchDebug")
	Central := _DriverFuncBody("LoggerAppendBoundedDebug")
	Assert(Seg != "", "KLR_PrefetchDebug(logPath, line) helper must exist in keylogger_reader.ahk")
	Assert(InStr(Seg, "LoggerAppendBoundedDebug") > 0,
		"KLR_PrefetchDebug must delegate fixed-name log ownership to the central logger")
	Assert(InStr(Central, "LoggerIsDebugEnabled") > 0,
		"the central owner must keep auxiliary diagnostics silent below DEBUG")
	Assert(InStr(Central, "LOGGER_AUXILIARY_LOG_MAX_BYTES") > 0
		and InStr(Central, "FileAppend") > 0,
		"the central owner must enforce the shared cap before its single append")
}
Test("keylogger_reader: KLR_PrefetchDebug delegates to the bounded debug owner (klr-builddatabase-debug-fileappend-hot)", _KLRDBG_PrefetchDebugGatesOnDebugFlag)
