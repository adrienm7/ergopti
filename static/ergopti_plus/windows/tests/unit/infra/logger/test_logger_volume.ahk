; tests/unit/infra/logger/test_logger_volume.ahk

; ==============================================================================
; MODULE: Logger Volume Counters Tests
; DESCRIPTION:
; The AHK replay of _shared/lua/test/logger_volume_contract.lua (spec section
; 5.3): the same seven figures, in the same order, as the shared Lua core. Before
; this the Windows log had no figure at all for what the level threshold, the
; dedup and the collapser removed, so its volume could not be compared with the
; two other drivers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ A Controlled Logger =======
; ======================================
; ======================================

; Runs Body with a blank sink, a driven clock and zeroed counters.
; @param Body {Func} Called with (Clock) where Clock.Now is the fake tick reading.
; @param MinLevel {String} Level the scenario runs at.
_TLV_With(Body, MinLevel := "DEBUG") {
	global LOGGER_MIN_LEVEL, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_SUB_PATHS, _LOGGER_SUB_PENDING, LOGGER_SUB_FILES, _LOGGER_REPEAT_ENABLED
	Saved := [LOGGER_MIN_LEVEL, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_SUB_PATHS, LOGGER_SUB_FILES,
		_LOGGER_REPEAT_ENABLED]
	Clock := { Now: 1000 }
	try {
		LOGGER_LOG_PATH := ""
		LOGGER_ERRORS_LOG_PATH := ""
		_LOGGER_SUB_PATHS := Map()
		LOGGER_SUB_FILES := []
		LOGGER_MIN_LEVEL := MinLevel
		_LoggerRefreshFastFlags()
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_COUNT := 0
		_LOGGER_CLOCK_FN := () => Clock.Now
		_LOGGER_STAMP_FN := () => "2026-10-25 10:00:00:000"
		if _LOGGER_REPEAT_ENABLED
			_LoggerRepeatDisable()
		LoggerResetVolume()
		Body.Call(Clock)
	} finally {
		_LOGGER_CLOCK_FN := 0
		_LOGGER_STAMP_FN := 0
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_COUNT := 0
		if _LOGGER_REPEAT_ENABLED
			_LoggerRepeatDisable()
		LOGGER_MIN_LEVEL := Saved[1]
		LOGGER_LOG_PATH := Saved[2]
		LOGGER_ERRORS_LOG_PATH := Saved[3]
		_LOGGER_SUB_PATHS := Saved[4]
		LOGGER_SUB_FILES := Saved[5]
		if Saved[6]
			_LoggerRepeatEnable()
		_LoggerRefreshFastFlags()
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		LoggerResetVolume()
	}
}

; @param Expected {String} The figures, in the documented order.
_TLV_AssertVolume(Expected, Why) {
	AssertEqual(Expected, LoggerVolumeText(LoggerVolume()), Why)
}





; ==================================
; ==================================
; ======= 2/ What Is Counted =======
; ==================================
; ==================================

_TLV_WrittenPerLevel() {
	_Scenario(*) {
		LoggerDebug("m", "a"), LoggerTrace("m", "b"), LoggerDone("m", "c")
		LoggerInfo("m", "d"), LoggerStart("m", "e"), LoggerSuccess("m", "f")
		LoggerWarn("m", "g")
		_TLV_AssertVolume("debug=3 info=3 warn=1 error=0 dropped=0 suppressed=0 collapsed=0",
			"lifecycle variants count under their level")
	}
	_TLV_With(_Scenario)
}
Test("logger volume: written lines count under the four levels", _TLV_WrittenPerLevel)

_TLV_ThresholdDrops() {
	_Scenario(*) {
		LoggerDebug("m", "a"), LoggerInfo("m", "b"), LoggerWarn("m", "c")
		_TLV_AssertVolume("debug=0 info=0 warn=1 error=0 dropped=2 suppressed=0 collapsed=0",
			"a line under the threshold is dropped, on the wrappers' fast path too")
	}
	_TLV_With(_Scenario, "WARNING")
}
Test("logger volume: a line removed by the severity threshold counts as dropped", _TLV_ThresholdDrops)

_TLV_PreInitFilterMovesToDropped() {
	_Scenario(*) {
		global LOGGER_MIN_LEVEL, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		LoggerDebug("m", "boot detail")
		LoggerWarn("m", "boot warning")
		LOGGER_MIN_LEVEL := "WARNING"
		_LoggerRefreshFastFlags()
		_LoggerDropPreInitBelowLevel()
		Text := LoggerVolumeText(LoggerVolume())
		AssertContains(Text, "debug=0 ", "the queued DEBUG line never reaches the file")
		AssertContains(Text, "warn=1 ", "the warning stays")
		AssertContains(Text, "dropped=", "the removed line moves to the dropped figure")
		Assert(LoggerVolume()["dropped"] >= 1, "the removed line moves to the dropped figure")
	}
	_TLV_With(_Scenario)
}
Test("logger volume: the pre-init level filter moves a queued line to dropped", _TLV_PreInitFilterMovesToDropped)

_TLV_DedupSuppressed() {
	_Scenario(*) {
		LoggerInfo("m", "same"), LoggerInfo("m", "same"), LoggerInfo("m", "same")
		_TLV_AssertVolume("debug=0 info=1 warn=0 error=0 dropped=0 suppressed=2 collapsed=0",
			"consecutive duplicates are suppressed")
		LoggerInfo("m", "other")
		; The first line, the summary of the two swallowed ones and the new line.
		_TLV_AssertVolume("debug=0 info=3 warn=0 error=0 dropped=0 suppressed=2 collapsed=0",
			"the dedup summary is one written line")
	}
	_TLV_With(_Scenario)
}
Test("logger volume: consecutive duplicates count as suppressed and their summary as written", _TLV_DedupSuppressed)

_TLV_RepeatCollapsed() {
	_Scenario(Clock) {
		_LoggerRepeatEnable()
		LoggerInfo("m", "poll {1}", 1)
		Clock.Now += 10
		LoggerInfo("m", "other"), LoggerInfo("m", "poll {1}", 2)
		Clock.Now += 10
		LoggerInfo("m", "other2"), LoggerInfo("m", "poll {1}", 3)
		AssertEqual(2, LoggerVolume()["collapsed"], "the repeats were withheld")
		_LoggerFlushRepeats(true)
		; poll(1), other, other2 and the one repeat summary.
		_TLV_AssertVolume("debug=0 info=4 warn=0 error=0 dropped=0 suppressed=0 collapsed=2",
			"the repeat summary is one written line")
	}
	_TLV_With(_Scenario)
}
Test("logger volume: repeats the collapser withheld count as collapsed", _TLV_RepeatCollapsed)

_TLV_EvidenceNeverWithheld() {
	_Scenario(*) {
		LoggerEvidence("m", "same"), LoggerEvidence("m", "same")
		_TLV_AssertVolume("debug=0 info=2 warn=0 error=0 dropped=0 suppressed=0 collapsed=0",
			"an evidence record is an info line and is never withheld")
	}
	_TLV_With(_Scenario)
}
Test("logger volume: an evidence record counts as an info line", _TLV_EvidenceNeverWithheld)





; =================================
; =================================
; ======= 3/ How It Is Read =======
; =================================
; =================================

_TLV_Intervals() {
	_Scenario(*) {
		LoggerInfo("m", "a"), LoggerWarn("m", "b")
		First := LoggerVolumeInterval()
		AssertEqual(1, First["info"], "first interval")
		AssertEqual(1, First["warn"], "first interval")
		LoggerDebug("m", "c")
		Second := LoggerVolumeInterval()
		AssertEqual(0, Second["info"], "the mark moved")
		AssertEqual(1, Second["debug"], "second interval")
		AssertEqual(1, LoggerVolume()["info"], "the totals are untouched")
	}
	_TLV_With(_Scenario)
}
Test("logger volume: intervals do not disturb the totals", _TLV_Intervals)

_TLV_OneOrder() {
	AssertEqual("debug=1 info=2 warn=3 error=4 dropped=5 suppressed=6 collapsed=7",
		LoggerVolumeText(Map("collapsed", 7, "suppressed", 6, "dropped", 5, "error", 4, "warn", 3, "info", 2, "debug", 1)),
		"the one documented order, whatever the Map's")
	AssertEqual("debug=0 info=0 warn=0 error=0 dropped=0 suppressed=0 collapsed=0", LoggerVolumeText(Map()),
		"a missing figure is zero")
}
Test("logger volume: the figures render in the shared order", _TLV_OneOrder)

_TLV_OnTheIntervalRecord() {
	Lines := []
	_Scenario(*) {
		LoggerSetTestSink((Line) => Lines.Push(Line))
		try {
			LoggerWarn("m", "before the flush")
			PerfCounters_Flush()
		} finally LoggerClearTestSink()
		Text := ""
		for Line in Lines
			Text .= Line . "`n"
		Assert(RegExMatch(Text, "Process state: .*\. Log volume over \d+ s: debug=\d+ info=\d+ warn=1 error=\d+ dropped=\d+ suppressed=\d+ collapsed=\d+\.") > 0,
			"the seven figures travel on the interval evidence record: " . Text)
	}
	_TLV_With(_Scenario)
}
Test("logger volume: the interval evidence record carries the seven figures", _TLV_OnTheIntervalRecord)
