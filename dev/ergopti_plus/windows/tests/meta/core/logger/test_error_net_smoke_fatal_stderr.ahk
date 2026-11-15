; tests/meta/core/logger/test_error_net_smoke_fatal_stderr.ahk

; ==============================================================================
; MODULE: Regression — a startup smoke ended by an error names it on stderr
;         (smoke-fatal-empty-streams)
; DESCRIPTION:
; The compiled upgrade run of 2026-11-09 exited 1 after « Driver fully
; initialised — ready » with empty stdout and stderr and no fatal log line.
;
; ROOT CAUSE ENCODED: in a startup smoke the error net ends every uncaught error
; with PLC_ExitProcessNow(1). Its only durable trace was the logged fatal line,
; flushed by _LoggerFlush(true) — which returns without writing when the failing
; thread interrupted a flush already in progress (the smoke's own
; LoggerPrepareShutdown, or a timer's). ExitProcess never lets that interrupted
; owner resume, so the line was lost and the exit code was the whole verdict.
; The smoke branch now writes one line to standard error, which its harness
; keeps with the failure evidence.
;
; SCOPE: the line builder and the logger refusal run for real; the branch itself
; ends the process, so its wiring is checked in source.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ The fatal line survives the logger =======
; =====================================================
; =====================================================

; The refusal the fatal line cannot get past: a forced flush that finds another
; flush active only marks a replay, which an exiting process never runs.
_ENSF_InterruptedFlushWritesNothing() {
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING
	SavedActive := _LOGGER_FLUSH_ACTIVE
	SavedPending := _LOGGER_FORCE_FLUSH_PENDING
	_LOGGER_FLUSH_ACTIVE := true
	_LOGGER_FORCE_FLUSH_PENDING := false
	try {
		AssertEqual(false, _LoggerFlush(true), "a flush interrupted by the error net must refuse to write")
		AssertEqual(true, _LOGGER_FORCE_FLUSH_PENDING, "the refusal only leaves a replay for the interrupted owner")
	} finally {
		_LOGGER_FLUSH_ACTIVE := SavedActive
		_LOGGER_FORCE_FLUSH_PENDING := SavedPending
	}
}
Test("error net smoke: an interrupted flush leaves the fatal line unwritten (smoke-fatal-empty-streams)",
	_ENSF_InterruptedFlushWritesNothing)

; The line names the fault, its site and the phase, on a single line.
_ENSF_FatalLineNamesTheFault() {
	try throw TargetError("The startup boot full-save generation`nis not committed.", "StartupSmokeProbe")
	catch as Err
		Fault := Err
	SplitPath(Fault.File, &FileName)
	Line := ErrorNet_StartupSmokeFatalLine(Fault, "ready")
	AssertEqual("startup-smoke: uncaught TargetError during phase 'ready' in StartupSmokeProbe: "
		. "The startup boot full-save generation is not committed. at " . FileName . ":" . Fault.Line, Line,
		"the line carries the type, phase, site and description of the fault")
	AssertEqual(0, InStr(Line, "`n") + InStr(Line, "`r"), "the diagnostic is one line")
	AssertEqual("startup-smoke: uncaught String during phase 'starting': thrown text",
		ErrorNet_StartupSmokeFatalLine("thrown text", "starting"), "a thrown string is named as itself")
}
Test("error net smoke: the stderr line names the fault, its site and the phase (smoke-fatal-empty-streams)",
	_ENSF_FatalLineNamesTheFault)

; The smoke branch hands that line to the process exit, after the log flush.
_ENSF_SmokeExitCarriesTheLine() {
	Body := _StripFullLineComments(_DriverFuncBody("ErgoptiGlobalErrorHandler"))
	Assert(Body != "", "ErgoptiGlobalErrorHandler must exist in infra/error_net.ahk")
	FlushPos := InStr(Body, "_LoggerFlush(true)")
	ExitPos := InStr(Body, "PLC_ExitProcessNow(1, ErrorNet_StartupSmokeFatalLine(Exc, _DriverBootPhase))")
	Assert(ExitPos > 0,
		"a smoke ended by an uncaught error must write its fatal line to stderr (smoke-fatal-empty-streams)")
	Assert(FlushPos > 0 && FlushPos < ExitPos, "the log flush is still attempted before the smoke exits")
	AssertEqual(0, InStr(Body, "PLC_ExitProcessNow(1)"), "no smoke exit may leave the streams empty")
}
Test("error net smoke: the smoke exit writes the fatal line to stderr (smoke-fatal-empty-streams)",
	_ENSF_SmokeExitCarriesTheLine)
