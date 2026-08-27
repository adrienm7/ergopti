; tests/meta/test_mutex_yield_is_recorded.ahk

; ==============================================================================
; MODULE: Single-Owner Mutex Yield Recording Meta Test
; DESCRIPTION:
; The single-owner gate yields when another instance still holds the driver
; mutex, and it logged that fact with LoggerWarn — from the SECOND statement of
; the script.
;
; That call could never write anything. LoggerInit has not run at that point, so
; LOGGER_LOG_PATH is empty and the logger's severity globals are unset;
; LoggerWarn raises UnsetError, the bare `try` swallows it, and the line
; disappears. ExitApp(0) fires on the next line, so even a successfully queued
; line would never be flushed. The one event that proves multi-instance
; contention occurred was unwritable by construction — which is precisely why
; three consecutive audits found no evidence of it.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE — the yield must be recorded through a sink that
;    works before ANY initialisation — rather than "a warning exists".
; 2. Forbids the two tempting non-fixes: routing it through the logger (which
;    cannot work there) and calling LoggerInit (which would make a yielding
;    instance DELETE the live owner's sub-logs via _LoggerInitSubFiles).
;
; SCOPE: source introspection of ErgoptiPlus.ahk's mutex gate.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ The yield leaves a trace ==========
; ==============================================
; ==============================================

; Extract the non-owner branch from its classified decision to ExitApp.
; Everything the rejecting instance is able to do lives in there.
_MYIR_YieldBranch() {
	Src := _DriverSourceNoComments()
	GatePos := InStr(Src,
		"_DriverMutexDecision != DRIVER_MUTEX_ACQUIRED")
	Assert(GatePos > 0,
		"the single-owner mutex rejection branch must still exist")
	ExitPos := InStr(Src, "ExitApp(", , GatePos)
	Assert(ExitPos > GatePos, "the mutex rejection branch must still exit")
	return SubStr(Src, GatePos, ExitPos - GatePos)
}

_MYIR_YieldIsWrittenDirectly() {
	Branch := _MYIR_YieldBranch()

	Assert(InStr(Branch, "FileAppend") > 0,
		"the mutex yield must be written straight to disk — it runs before LoggerInit, so the logger has no path to write to and ExitApp fires before any queue could flush")
	Assert(InStr(Branch, "A_AppData") > 0,
		"the yield sink must resolve from a built-in that needs no bootstrap; every configured path is still unresolved at this point in the script")
	Assert(InStr(Branch, "DRIVER_MUTEX_WAIT_MS") > 0,
		"the recorded line must state how long this instance waited before yielding")
}

; The two non-fixes that look right and are not.
_MYIR_YieldDoesNotUseTheLogger() {
	Branch := _MYIR_YieldBranch()

	Assert(InStr(Branch, "LoggerWarn") == 0 and InStr(Branch, "LoggerError") == 0,
		"the yield branch must not route through the logger: LOGGER_LOG_PATH is empty and the severity globals are unset this early, so the call raises UnsetError into a bare try and the line is lost")
	Assert(InStr(Branch, "LoggerInit") == 0,
		"the yield branch must not call LoggerInit — it runs _LoggerInitSubFiles, which deletes any sub-file whose mtime is a previous day, so a yielding instance would destroy the LIVE owner's gestures/layout/tray sub-logs on its way out")
}


Test("meta mutex: a yielding instance records the fact through a bootstrap-safe sink",
	_MYIR_YieldIsWrittenDirectly)
Test("meta mutex: the yield branch uses neither the logger nor LoggerInit",
	_MYIR_YieldDoesNotUseTheLogger)
