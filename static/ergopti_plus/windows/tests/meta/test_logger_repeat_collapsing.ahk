; tests/meta/test_logger_repeat_collapsing.ahk

; ==============================================================================
; MODULE: Logger Repeat Collapsing Ownership (AHK)
; DESCRIPTION:
; The shared corpus (test_corpus_logger_behaviour.ahk) pins WHAT repeat
; collapsing emits. This file pins what this driver owns around it: LoggerInit
; arms it exactly once, the existing flush tick summarises a streak whose source
; fell silent, and the exit/reload flush emits every pending summary.
;
; ROOT CAUSE ENCODED:
; Periodic sources with changing counters filled the daily log with thousands of
; near-identical lines, because the only suppression matched byte-identical
; consecutive lines. A collapser that is never armed, never flushed by a timer
; or never flushed at exit brings the flood back or loses the counts silently.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Driven Logger =======
; ================================
; ================================

; Runs Scenario(Lines, SetTime) with repeat collapsing armed on a driven clock
; and clock face, the file sinks blanked, and every piece of state restored in
; `finally` so a red scenario cannot leak suppression into later tests.
_TLRC_WithDrivenLogger(Scenario) {
	global LOGGER_MIN_LEVEL, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE, _LOGGER_SUB_PATHS
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	global _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime

	Now := 0
	Lines := []
	SavedLevel := LOGGER_MIN_LEVEL
	SavedLog := LOGGER_LOG_PATH
	SavedErrors := LOGGER_ERRORS_LOG_PATH
	SavedDate := _LOGGER_PATH_DATE
	SavedSubPaths := _LOGGER_SUB_PATHS
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_PATH_DATE := ""
	_LOGGER_SUB_PATHS := Map()
	LOGGER_MIN_LEVEL := "DEBUG"
	_LoggerRefreshFastFlags()
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LastErrTime := 0
	_LOGGER_CLOCK_FN := () => Now * 1000
	_LOGGER_STAMP_FN := () => FormatTime(DateAdd("20260115100000", Now, "Seconds"), "yyyy-MM-dd HH:mm:ss") . ":000"
	LoggerSetTestSink((L) => Lines.Push(L))
	try {
		_LoggerRepeatEnable()
		Scenario(Lines, (T) => Now := T)
	} finally {
		LoggerClearTestSink()
		_LoggerRepeatDisable()
		_LOGGER_CLOCK_FN := 0
		_LOGGER_STAMP_FN := 0
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_LEVEL := ""
		_LOGGER_DEDUP_COUNT := 0
		_LastErrTime := 0
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		LOGGER_LOG_PATH := SavedLog
		LOGGER_ERRORS_LOG_PATH := SavedErrors
		_LOGGER_PATH_DATE := SavedDate
		_LOGGER_SUB_PATHS := SavedSubPaths
		LOGGER_MIN_LEVEL := SavedLevel
		_LoggerRefreshFastFlags()
	}
}

; Counts the repeat summaries among captured lines: a repeat summary quotes its
; streak's text right after the arrow, a dedup summary never does.
_TLRC_RepeatSummaries(Lines) {
	Count := 0
	for _, Line in Lines {
		if InStr(Line, Chr(0x2191) . ' "')
			Count += 1
	}
	return Count
}





; ====================================
; ====================================
; ======= 2/ Boot Arms It Once =======
; ====================================
; ====================================

_TLRC_InitArmsOnce() {
	Body := _DriverFuncBody("LoggerInit")
	Assert(Body != "", "LoggerInit() must exist in the driver source")
	OneTime := InStr(Body, "if !_LOGGER_FLUSH_TIMER_STARTED")
	Arm := InStr(Body, "_LoggerRepeatEnable()")
	Assert(OneTime > 0, "prerequisite: LoggerInit still has its one-time timer block")
	Assert(Arm > OneTime,
		"LoggerInit must arm repeat collapsing inside its one-time block: LoggerInit runs again on "
		. "every level change and menu rebuild, and a second arming is refused")
	Assert(!InStr(Body, "_LoggerRepeatEnable()", true, Arm + 1),
		"LoggerInit must arm repeat collapsing exactly once")
}
Test("logger repeat: LoggerInit arms repeat collapsing once, in its one-time block", _TLRC_InitArmsOnce)





; ======================================
; ======================================
; ======= 3/ Flush Tick and Exit =======
; ======================================
; ======================================

_TLRC_FlushTickSummarisesSilentStreak() {
	_Scenario(Lines, SetTime) {
		global LOGGER_REPEAT_WINDOW_MS
		WindowSec := LOGGER_REPEAT_WINDOW_MS // 1000
		SetTime(0)
		LoggerDebug("RepeatTick", "Health-check tick (watchers={1})", 1)
		SetTime(30)
		LoggerDebug("RepeatTick", "Health-check tick (watchers={1})", 1)
		AssertEqual(1, Lines.Length, "the second occurrence inside the window must be withheld")

		; _LoggerFlush is the target of the existing periodic SetTimer
		SetTime(WindowSec - 1)
		_LoggerFlush(false)
		AssertEqual(0, _TLRC_RepeatSummaries(Lines), "a tick inside the window must emit nothing")
		SetTime(WindowSec)
		_LoggerFlush(false)
		AssertEqual(1, _TLRC_RepeatSummaries(Lines),
			"the flush tick must summarise a streak whose source fell silent, not wait for another line")
		AssertTrue(InStr(Lines[Lines.Length], "repeated 1 more time") > 0,
			"the summary must carry the withheld count, got: " . Lines[Lines.Length])
	}
	_TLRC_WithDrivenLogger(_Scenario)
}
Test("logger repeat: the periodic flush tick summarises a streak that fell silent",
	_TLRC_FlushTickSummarisesSilentStreak)

_TLRC_ExitFlushEmitsPending() {
	_Scenario(Lines, SetTime) {
		SetTime(0)
		LoggerInfo("RepeatExit", "Poll.")
		SetTime(30)
		LoggerInfo("RepeatExit", "Poll.")
		AssertEqual(0, _TLRC_RepeatSummaries(Lines), "prerequisite: the streak is still open")
		_LoggerOnExitFlush("Test", 0)
		AssertEqual(1, _TLRC_RepeatSummaries(Lines),
			"exit and reload are the last chance to close a streak: its summary must be emitted, not dropped")
	}
	_TLRC_WithDrivenLogger(_Scenario)
}
Test("logger repeat: the exit flush emits every pending summary", _TLRC_ExitFlushEmitsPending)
