; tests/meta/test_logger_dedup_exit_flush.ahk

; ==============================================================================
; MODULE: Logger Dedup Streak Flushed On Exit
; DESCRIPTION:
; Regression guard: an in-flight log-dedup streak's suppressed-line count was
; silently lost on process exit/Reload. The dedup summary ("N identical lines
; suppressed") is normally only emitted when a DIFFERENT line arrives after the
; streak (see _LoggerEmit) — but _LoggerOnExitFlush only called _LoggerFlush,
; never checking whether a streak was still pending. If the very last log call
; before shutdown was itself a suppressed duplicate, its summary never got
; emitted, precisely when a repeating warning/error storm immediately preceding
; a crash/reload is most diagnostically valuable.
;
; The fix has _LoggerOnExitFlush emit the pending _LOGGER_DEDUP_COUNT summary
; (if any) before the final flush, mirroring the exact same emission the
; streak would have received had one more differing line arrived.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLDEF_ResetDedupState() {
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global LOGGER_MIN_LEVEL, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := []
	_LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LastErrTime := 0
	_LoggerRefreshFastFlags()
}




; ======================================================================
; ======================================================================
; ======= 1/ A pending streak is emitted, not dropped, on exit ========
; ======================================================================
; ======================================================================

_TLDEF_PendingStreakFlushedOnExit() {
	global _LOGGER_DEDUP_COUNT
	_TLDEF_ResetDedupState()

	LoggerWarn("DedupExit", "recurring-warning-before-shutdown")
	LoggerWarn("DedupExit", "recurring-warning-before-shutdown")  ; suppressed into the streak

	AssertEqual(1, _LOGGER_DEDUP_COUNT,
		"second identical warning must be suppressed into the pending dedup streak")

	for _, Line in LoggerRingBufferSnapshot()
		Assert(!InStr(Line, "identical"),
			"no dedup summary should exist yet — the streak has not ended")

	_LoggerOnExitFlush("Test", 0)

	AssertEqual(0, _LOGGER_DEDUP_COUNT,
		"_LoggerOnExitFlush must reset the pending dedup counter after emitting its summary")

	Found := false
	for _, Line in LoggerRingBufferSnapshot() {
		if InStr(Line, "identical") and InStr(Line, "suppressed")
			Found := true
	}
	AssertTrue(Found,
		"_LoggerOnExitFlush must emit the pending dedup-streak summary ('N identical lines "
		. "suppressed') instead of silently dropping it on shutdown (logger-dedup-streak-lost-on-exit)")
}
Test("logger: pending dedup streak is flushed on exit, not silently lost (logger-dedup-streak-lost-on-exit)",
	_TLDEF_PendingStreakFlushedOnExit)





; ======================================================================
; ======================================================================
; ======= 2/ No pending streak -> exit flush is a harmless no-op =======
; ======================================================================
; ======================================================================

_TLDEF_NoStreakExitFlushIsNoop() {
	global _LOGGER_DEDUP_COUNT
	_TLDEF_ResetDedupState()

	LoggerWarn("DedupExit", "single-warning-no-repeat")
	AssertEqual(0, _LOGGER_DEDUP_COUNT, "a single (non-repeated) warning must not start a pending streak")

	Threw := false
	try {
		_LoggerOnExitFlush("Test", 0)
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "_LoggerOnExitFlush must not throw when there is no pending dedup streak")
	AssertEqual(0, _LOGGER_DEDUP_COUNT, "the counter must remain 0 when there was nothing to flush")
}
Test("logger: exit flush with no pending streak is a harmless no-op", _TLDEF_NoStreakExitFlushIsNoop)
