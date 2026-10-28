; tests/unit/infra/dispatch/test_hotpath_latency_statistics.ahk

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
	AssertContains(Mark, 'LoggerInfo("Keystats", Format(')
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
	AssertContains(Mark, 'LoggerInfo("Keystats", Format(')
	AssertContains(Append, "refused by the current privacy predicate")
	Assert(InStr(Append, "if Keystats._shutting_down") < InStr(Append, "refused by the current privacy predicate"),
		"ordinary typing must not emit a privacy refusal line per keystroke")
}
Test("hotpath: reload shutdown attributes drains and reports privacy refusals (hotpath-latency-statistics)",
	_HPLS_ShutdownStagesAreDistinct)






; =============================================================
; =============================================================
; ======= 5/ Interval counters and process state (perf) =======
; =============================================================
; =============================================================

_PC_WithFreshRegistry(Scenario) {
	Owner := _PerfCountersOwner()
	SavedCounts := Owner.Counts
	SavedRefused := Owner.Refused
	Owner.Counts := Map()
	Owner.Refused := 0
	try Scenario(Owner)
	finally {
		Owner.Counts := SavedCounts
		Owner.Refused := SavedRefused
	}
}

_PC_CountsAccumulateAndAreBounded() {
	_Scenario(Owner) {
		AssertTrue(PerfCount("a"))
		AssertTrue(PerfCount("a", 4))
		AssertEqual(5, Owner.Counts["a"])
		SavedLimit := Owner.Limit
		Owner.Limit := 2
		try {
			AssertTrue(PerfCount("b"))
			AssertFalse(PerfCount("c"), "a full registry refuses a new name")
			AssertEqual(1, Owner.Refused)
			AssertTrue(PerfCount("b", 2), "capacity never rejects an existing name")
			AssertEqual(3, Owner.Counts["b"])
		} finally Owner.Limit := SavedLimit
	}
	_PC_WithFreshRegistry(_Scenario)
}
Test("perf counters: increments accumulate and the registry is bounded (perf-counters)",
	_PC_CountsAccumulateAndAreBounded)

_PC_FlushPublishesOneEvidenceRecordAndResets() {
	_Scenario(Lines, SetTime) {
		_Inner(Owner) {
			PerfCount("toml.file_read", 3)
			PerfCount("hook.keydown", 2)
			PerfCounters_Flush()
			Text := ""
			for Line in Lines
				Text .= Line . "`n"
			AssertContains(Text, "Interval counters (", "the counters are published")
			AssertContains(Text, "hook.keydown=2 toml.file_read=3", "names are sorted for stable diffs")
			AssertContains(Text, "Process state: working_set_mb=", "process state follows")
			AssertEqual(0, Owner.Counts.Count, "publishing resets the window")
			Before := Lines.Length
			PerfCounters_Flush()
			Text := ""
			Loop Lines.Length - Before
				Text .= Lines[Before + A_Index] . "`n"
			Assert(!InStr(Text, "Interval counters ("), "an empty window publishes no counter record")
		}
		_PC_WithFreshRegistry(_Inner)
	}
	_TLRC_WithDrivenLogger(_Scenario)
}
Test("perf counters: flush publishes sorted counters once and resets (perf-counters)",
	_PC_FlushPublishesOneEvidenceRecordAndResets)

_PC_ProcessStateReportsRealValues() {
	State := PerfProcessState()
	AssertTrue(State.WorkingSetMb > 0, "the working set is read")
	AssertTrue(State.PrivateMb > 0, "private bytes are read")
	AssertTrue(State.Handles > 0, "the handle count is read")
	AssertTrue(State.GdiObjects >= 0 && State.UserObjects >= 0, "GUI object counts are read")
}
Test("perf counters: process state reads memory and kernel-object counts (perf-counters)",
	_PC_ProcessStateReportsRealValues)

_PC_StageDebugLineIsLevelGated() {
	global LOGGER_MIN_LEVEL
	_Scenario(Lines, SetTime) {
		Started := PerfStage_Begin()
		LOGGER_MIN_LEVEL := "DEBUG"
		_LoggerRefreshFastFlags()
		PerfStage_End("Perf.test_stage", Started, 7)
		Text := ""
		for Line in Lines
			Text .= Line . "`n"
		AssertContains(Text, "Stage 'Perf.test_stage' took", "DEBUG shows the stage")
		AssertContains(Text, "(count=7)")
		Lines.Length := 0
		LOGGER_MIN_LEVEL := "INFO"
		_LoggerRefreshFastFlags()
		Elapsed := PerfStage_End("Perf.test_stage", Started, 7)
		AssertTrue(Elapsed >= 0, "the stage still reports its duration")
		AssertEqual(0, Lines.Length, "no line is built below DEBUG")
	}
	_TLRC_WithDrivenLogger(_Scenario)
}
Test("perf counters: the stage debug line is built only when DEBUG is enabled (perf-counters)",
	_PC_StageDebugLineIsLevelGated)

_PC_BootSummaryListsTopLevelStagesOnly() {
	Closed := _BootStageDurations()
	Saved := Closed.Clone()
	Closed.Length := 0
	try {
		Closed.Push({ Name: "feature gates", Ms: 250 })
		Closed.Push({ Name: "menu row llm", Ms: 266 })
		Closed.Push({ Name: "tray menu", Ms: 1813 })
		AssertEqual("feature_gates=250 tray_menu=1813", BootProfile_StageSummary(),
			"nested menu rows overlap the tray menu stage and are left out")
	} finally {
		Closed.Length := 0
		for Stage in Saved
			Closed.Push(Stage)
	}
}
Test("perf counters: the boot summary lists top-level stages in completion order (perf-counters)",
	_PC_BootSummaryListsTopLevelStagesOnly)
_PC_BuildMemoAnswersOncePerBuild() {
	Calls := 0
	Probe := () => (Calls += 1, true)
	AssertTrue(_MR_EvaluateDisabledGetter("llm_toggle_ready", Probe))
	AssertTrue(_MR_EvaluateDisabledGetter("llm_toggle_ready", Probe))
	AssertEqual(2, Calls, "outside a build every call is live")
	Owner := _MR_BuildMemoEnter()
	try {
		AssertTrue(Owner, "the outermost build owns the memo")
		AssertFalse(_MR_BuildMemoEnter(), "a nested build shares it without owning it")
		Calls := 0
		loop 5
			_MR_EvaluateDisabledGetter("llm_scope_ready", Probe)
		AssertEqual(1, Calls, "a memoised getter is asked once per build")
		loop 3
			_MR_EvaluateDisabledGetter("other_getter", Probe)
		AssertEqual(4, Calls, "any other getter stays live inside the build")
	} finally _MR_BuildMemoLeave(Owner)
	Calls := 0
	_MR_EvaluateDisabledGetter("llm_scope_ready", Probe)
	_MR_EvaluateDisabledGetter("llm_scope_ready", Probe)
	AssertEqual(2, Calls, "the memo is gone when the build ends, so clicks see live state")
	Refusing := () => false
	Owner := _MR_BuildMemoEnter()
	try AssertFalse(_MR_EvaluateDisabledGetter("llm_toggle_ready", Refusing))
	finally _MR_BuildMemoLeave(Owner)
	AssertTrue(Probe.Call() && !Refusing.Call(), "fixture sanity")
}
Test("perf counters: write-admission getters are answered once per menu build and live otherwise (menu-build-memo)",
	_PC_BuildMemoAnswersOncePerBuild)

_HPLS_DispatchAttributesOneEventInEight() {
	Counts := _PerfCountersOwner().Counts
	EventType := "perf_sample_probe"
	Seen := 0
	Probe(*) {
		Seen += 1
	}
	HookDispatcher.Register(EventType, Probe)
	try {
		loop 16
			HookDispatcher.Dispatch(EventType, 0)
		AssertEqual(16, Seen, "every subscriber still runs on every event")
		Samples := 0
		for Name, Count in Counts
			if InStr(Name, "hook.sub_samples." . EventType . ".")
				Samples += Count
		AssertEqual(2, Samples, "one dispatch in eight reports the subscriber's own time")
		Total := 0
		for Name, Count in Counts
			if InStr(Name, "hook.sub_us." . EventType . ".")
				Total += Count
		AssertTrue(Total >= 0, "its microseconds ride the interval counter record")
		for Name in ["hook.sub_samples.", "hook.sub_us."]
			for Key in [Name . EventType . ".Probe", Name . EventType . ".unnamed"]
				if Counts.Has(Key)
					Counts.Delete(Key)
	} finally HookDispatcher.Unregister(EventType, Probe)
}
Test("hook dispatcher: one dispatch in eight attributes its time to each named subscriber (hook-subscriber-sampling)",
	_HPLS_DispatchAttributesOneEventInEight)

_HPLS_PreReadyRetryDoesNotPayAdmission() {
	global _DriverReady, CONFIG_SAVE_DEFERRED
	Counts := _PerfCountersOwner().Counts
	Admissions := Counts.Get("config_io.full_state_can_persist", 0)
	Deferred := Counts.Get("config_io.save_retry_deferred_before_admission", 0)
	Coordinator := _ConfigFullSaveCoordinator()
	SavedReady := IsSet(_DriverReady) ? _DriverReady : false
	try {
		_DriverReady := false
		Result := SaveFullConfig(0, (*) => true, false)
		AssertEqual(CONFIG_SAVE_DEFERRED, Result, "a pre-ready timer retry stays deferred")
		AssertEqual(Admissions, Counts.Get("config_io.full_state_can_persist", 0),
			"and does not pay the registry deep compare of the admission")
		AssertEqual(Deferred + 1, Counts.Get("config_io.save_retry_deferred_before_admission", 0))
	} finally {
		_DriverReady := SavedReady
		_ConfigFullSaveCoordinator(Coordinator)
	}
	Body := _DriverFuncBody("SaveFullConfig")
	Early := InStr(Body, "if !RegisterRequest && !_DriverReady && !PublicationDebt {")
	Guard := InStr(Body, "if !PublicationDebt && !ConfigFullStateCanPersist() {")
	Assert(Early > 0 && Guard > Early,
		"only a non-registering retry before ready skips it; a new request and every ready attempt are admitted")
	Assert(Guard < InStr(Body, "Updates := HasMethod(CollectFn"), "admission still precedes every collection")
}
Test("config: a full-save retry before the driver is ready does not pay write admission (full-save-retry-admission)",
	_HPLS_PreReadyRetryDoesNotPayAdmission)
