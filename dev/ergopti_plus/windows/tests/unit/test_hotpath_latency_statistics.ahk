; tests/unit/test_hotpath_latency_statistics.ahk

; ==============================================================================
; MODULE: Bounded Hot-Path Latency Statistics Tests
; DESCRIPTION:
; Fast callbacks must remain measurable without storing input content or an
; unbounded history. Counts and distributions survive snapshot publication.
; ==============================================================================

#Requires AutoHotkey v2.0

_HPLS_RecordsFastAndSlowSamples() {
	Stats := HotPathLatencyStatistics(2)
	for Ms in [0.1, 1, 5, 10, 50]
		AssertTrue(Stats.Record("dispatch", Ms, 5))
	Sample := Stats.Series["dispatch"]
	AssertEqual(5, Sample.Count)
	AssertEqual(66.1, Sample.TotalMs)
	AssertEqual(0.1, Sample.MinMs)
	AssertEqual(50, Sample.MaxMs)
	AssertEqual(2, Sample.Slow, "the slow threshold retains its strict comparison")
	AssertEqual(4, Sample.Ge1)
	AssertEqual(3, Sample.Ge5)
	AssertEqual(2, Sample.Ge10)
	AssertEqual(1, Sample.Ge50)
	AssertTrue(!Sample.HasOwnProp("Detail"), "input detail is never retained")
}
Test("hotpath: aggregate fast and slow samples without callback content (hotpath-latency-statistics)",
	_HPLS_RecordsFastAndSlowSamples)

_HPLS_BoundsLabelMemory() {
	Stats := HotPathLatencyStatistics(1)
	AssertTrue(Stats.Record("first", 0.2, 5))
	AssertFalse(Stats.Record("second", 0.3, 5))
	AssertEqual(1, Stats.Series.Count)
	AssertEqual(1, Stats.Refused)
	AssertTrue(Stats.Record("first", 0.4, 5), "capacity never rejects an existing segment")
	AssertEqual(2, Stats.Series["first"].Count)
	AssertThrows(() => HotPathLatencyStatistics(0))
}
Test("hotpath: label memory is bounded and refusals remain counted (hotpath-latency-statistics)",
	_HPLS_BoundsLabelMemory)

_HPLS_ReentrantFlushOwnsNextWindow() {
	_Scenario(Lines, SetTime) {
		Owner := _HotPathStatisticsOwner()
		AssertFalse(Owner.Started, "the headless fixture must own an inactive statistics scheduler")
		SavedStats := Owner.Stats
		try {
			Owner.Stats := HotPathLatencyStatistics(2)
			HotPath_StartStatistics()
			AssertThrows(() => HotPath_StartStatistics(), "duplicate timer ownership is rejected")
			HotPath_RecordLatency("first", 0.1, 5)
			HotPath_RecordLatency("first", 10, 5)
			HotPath_RecordLatency("second", 0.2, 5)
			Reentered := false
			LoggerSetTestSink((Line) => (
				Lines.Push(Line),
				InStr(Line, "Latency 'first':") && !Reentered
					? (Reentered := true, HotPath_RecordLatency("during.flush", 0.3, 5)) : 0))
			HotPath_FlushStatistics()
			AssertTrue(Reentered, "the real summary sink must publish a nested sample")
			AssertEqual(1, Owner.Stats.Series.Count)
			AssertEqual(1, Owner.Stats.Series["during.flush"].Count,
				"a sample during emission belongs to the new window")
			Text := ""
			for Line in Lines
				Text .= Line . "`n"
			AssertContains(Text, "Latency 'first': count=2")
			AssertContains(Text, "Latency 'second': count=1",
				"distinct summaries survive logger repeat collapsing")
			AssertTrue(HotPath_StopStatistics())
			AssertFalse(Owner.Started)
			AssertEqual(0, Owner.Timer)
			AssertFalse(HotPath_StopStatistics(), "an inactive scheduler cannot stop twice")
		} finally {
			if Owner.Started
				HotPath_StopStatistics()
			Owner.Stats := SavedStats
		}
	}
	_TLRC_WithDrivenLogger(_Scenario)
}
Test("hotpath: reentrant summaries retain the next window and close one timer (hotpath-latency-statistics)",
	_HPLS_ReentrantFlushOwnsNextWindow)

_HPLS_ProductionOwnershipIsWired() {
	Record := _DriverFuncBody("HotPath_LogIfSlow")
	Exit := _DriverFuncBody("_LoggerOnExitFlush")
	Flush := _DriverFuncBody("HotPath_FlushStatistics")
	Assert(Record != "" && Exit != "" && Flush != "", "all production owners must exist")
	AssertContains(Record, "HotPath_RecordLatency(Label, ElapsedMs, SlowMs)")
	Breakdown := _DriverFuncBody("_HotPathBreakdown")
	Assert(Breakdown != "", "the substep measurement owner must exist")
	AssertContains(Breakdown, 'HotPath_RecordLatency("Substep." . Label, ElapsedMs, _HOTPATH_SLOW_MS)')
	AssertContains(Exit, "HotPath_StopStatistics()")
	AssertContains(Flush, "Snapshot := Owner.Stats")
	AssertContains(Flush, "Owner.Stats := HotPathLatencyStatistics(Snapshot.Limit)")
	Assert(InStr(Flush, "Critical(PreviousCritical)") < InStr(Flush, "LoggerInfo("),
		"logging starts only after releasing the snapshot transaction")
	Start := _DriverFuncBody("HotPath_StartStatistics")
	Assert(Start != "", "the summary scheduler must exist")
	AssertContains(Start, "60000, -1")
}
Test("hotpath: every measured callback contributes and exit publishes before logger flush (hotpath-latency-statistics)",
	_HPLS_ProductionOwnershipIsWired)

_HPLS_DashboardStagesAreDistinct() {
	Open := _DriverFuncBody("KLWV_Open")
	Mark := _DriverFuncBody("KLWV_OpenTimingMark")
	Assert(Open != "" && Mark != "", "dashboard timing owners must exist")
	for Phase in ["host", "profile", "controller", "bindings", "mount", "navigate"]
		AssertContains(Open, 'KLWV_OpenTimingMark(which, "' . Phase . '", Timing)')
	AssertContains(Mark, "BootClockCpuMs()")
	AssertContains(Mark, "BootProfile_MenuWaitMs()")
	AssertContains(Mark, 'LoggerInfo("Keylogger", Format(')
	AssertContains(Mark, "HotPath_RecordLatency(")
	Diagnostics := _DriverFuncBody("HealthCheck_ShowWindow")
	DiagnosticsMark := _DriverFuncBody("_HC_OpenTimingMark")
	Assert(Diagnostics != "" && DiagnosticsMark != "", "diagnostics timing owners must exist")
	for Phase in ["snapshot", "host", "controller", "bindings", "navigate", "native_controls"]
		AssertContains(Diagnostics, '_HC_OpenTimingMark("' . Phase . '", Timing)')
	AssertContains(DiagnosticsMark, "HotPath_RecordLatency(")
	AssertContains(DiagnosticsMark, 'LoggerInfo("Healthcheck", Format(')
}
Test("hotpath: dashboard opening attributes native preparation stages (hotpath-latency-statistics)",
	_HPLS_DashboardStagesAreDistinct)

_HPLS_ShutdownStagesAreDistinct() {
	Stop := _DriverFuncBody("KL_Stop")
	Mark := _DriverFuncBody("_KL_StopTimingMark")
	Append := _DriverFuncBody("KL_AppendLog")
	Assert(Stop != "" && Mark != "" && Append != "", "shutdown timing owners must exist")
	for Phase in ["prepare", "hook", "watchers", "sensors_and_timers", "flush_and_journal", "categories", "ingest_and_state", "handle"]
		AssertContains(Stop, '_KL_StopTimingMark("' . Phase . '", Timing)')
	AssertContains(Mark, "HotPath_RecordLatency(")
	AssertContains(Mark, 'LoggerInfo("Keylogger", Format(')
	AssertContains(Append, "refused by the current privacy predicate")
	Assert(InStr(Append, "if Keylogger._shutting_down") < InStr(Append, "refused by the current privacy predicate"),
		"ordinary typing must not emit a privacy refusal line per keystroke")
}
Test("hotpath: reload shutdown attributes drains and reports privacy refusals (hotpath-latency-statistics)",
	_HPLS_ShutdownStagesAreDistinct)
