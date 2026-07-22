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
; The fix funnels every diagnostic line through a single KLR_PrefetchDebug
; helper that early-returns unless LoggerIsDebugEnabled() is true. In normal
; operation (LOGGER_MIN_LEVEL=INFO) the whole instrumentation path collapses to
; a boolean test and writes nothing.
;
; This guard fails if any FileAppend reappears inside KLR_BuildDatabase or
; KLR_ApplyIncremental, or if KLR_PrefetchDebug stops gating on the debug flag.
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
	Src := _KLRDBG_ReadSource("modules/keylogger/keylogger_reader.ahk")
	Seg := _DriverFuncBody("KLR_PrefetchDebug")
	Assert(Seg != "", "KLR_PrefetchDebug(logPath, line) helper must exist in keylogger_reader.ahk")
	Assert(InStr(Seg, "LoggerIsDebugEnabled") > 0,
		"KLR_PrefetchDebug must early-return unless LoggerIsDebugEnabled() so the prefetch.log instrumentation is silent below DEBUG level")
	Assert(InStr(Seg, "FileAppend") > 0,
		"KLR_PrefetchDebug must still own the single FileAppend that writes the diagnostic line when DEBUG is on")
}
Test("keylogger_reader: KLR_PrefetchDebug gates the only FileAppend on LoggerIsDebugEnabled (klr-builddatabase-debug-fileappend-hot)", _KLRDBG_PrefetchDebugGatesOnDebugFlag)
