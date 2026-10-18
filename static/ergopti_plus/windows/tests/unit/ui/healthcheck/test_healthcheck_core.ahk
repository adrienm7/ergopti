; tests/unit/ui/healthcheck/test_healthcheck_core.ahk

; ==============================================================================
; MODULE: HealthCheck Core Behavioral Tests
; DESCRIPTION:
; Exercises the counter functions and HealthCheck_Run() from
; ui/healthcheck/core.ahk with real assertions. Replaces the 9 no-op
; AssertTrue(true) placeholder tests that previously lived in test_logger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

_TestHC_NativeWindowTitle() {
	global _I18nCache, _I18nCacheLoaded, _SharedDir
	SavedCache := _I18nCache, SavedLoaded := _I18nCacheLoaded
	try {
		Locales := JsonParse(FileRead(_SharedDir . "\data\locale_order.json", "UTF-8"))["order"]
		AssertEqual(21, Locales.Length)
		for Locale in Locales {
			Strings := JsonParse(FileRead(_SharedDir . "\data\locales\" . Locale . ".json", "UTF-8"))
			Label := Strings["menu.debug.healthcheck"]
			_I18nCache := Map("menu.debug.healthcheck", Label), _I18nCacheLoaded := true
			Window := _HC_NewWindow()
			try AssertEqual("ErgoptiPlus — " . Label, Window.Title, Locale . " native diagnostics title")
			finally Window.Destroy()
		}
	} finally {
		_I18nCache := SavedCache, _I18nCacheLoaded := SavedLoaded
	}
}
Test("HealthCheck: native diagnostics title has one product prefix in every locale (diagnostics-window-title)",
	_TestHC_NativeWindowTitle)


; =============================================
; ======= 1/ Counter functions ================
; =============================================

_TestHC_RecordWarnIncrementsCounter() {
	global _HealthCheckWarnCount
	Before := _HealthCheckWarnCount
	HealthCheck_RecordWarn()
	Assert(_HealthCheckWarnCount == Before + 1,
		"RecordWarn must increment _HealthCheckWarnCount by 1")
}

Test("HealthCheck: RecordWarn increments the warning counter",
	_TestHC_RecordWarnIncrementsCounter)


_TestHC_RecordErrorStoresAndCounts() {
	global _HealthCheckErrCount, _HealthCheckLastError
	Before := _HealthCheckErrCount
	HealthCheck_RecordError("test error message")
	Assert(_HealthCheckErrCount == Before + 1,
		"RecordError must increment _HealthCheckErrCount by 1")
	Assert(_HealthCheckLastError == "test error message",
		"RecordError must store the message in _HealthCheckLastError")
}

Test("HealthCheck: RecordError increments counter and stores the message",
	_TestHC_RecordErrorStoresAndCounts)


_TestHC_MultipleRecordWarn() {
	global _HealthCheckWarnCount
	Before := _HealthCheckWarnCount
	loop 5
		HealthCheck_RecordWarn()
	Assert(_HealthCheckWarnCount == Before + 5,
		"Five RecordWarn calls must increment counter by 5")
}

Test("HealthCheck: multiple RecordWarn calls accumulate correctly",
	_TestHC_MultipleRecordWarn)


; =============================================
; ======= 2/ HealthCheck_Run structure ========
; =============================================

_TestHC_RunIsVersion2() {
	Result := HealthCheck_Run()
	Assert(Result is Map, "HealthCheck_Run must return a Map")
	AssertEqual(2, Result["schema_version"])
	AssertEqual("windows", Result["driver"])
	Assert(RegExMatch(Result["generated_at"], "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"),
		"generated_at must be UTC ISO 8601: " . Result["generated_at"])
	for Id in ["github_api", "ai_health"]
		AssertEqual("not_run", Result["probes"][Id]["state"], Id . " must not start without extensive opt-in")
}

Test("HealthCheck: Run returns a version 2 quick snapshot with probes explicitly not run", _TestHC_RunIsVersion2)

/** Proves the actual starter admits only the independent extensive selection. */
_TestHC_ExtensiveAdmission(Selected, ExpectedStarts) {
	global _HC_Session, _HC_ProbeRun
	if _HC_ProbeRun
		throw Error("A foreign diagnostic probe run is active.")
	SavedSession := _HC_Session
	Calls := []
	Start(Epoch, Schema, Publish) {
		Calls.Push(Epoch)
		AssertTrue(Schema is Map)
		AssertTrue(HasMethod(Publish, "Call"))
		return true
	}
	try {
		_HC_Session := Map("extensive", Selected, "detailed", true)
		_HC_RestartProbes(71, Start)
		AssertEqual(ExpectedStarts, Calls.Length)
		if ExpectedStarts
			AssertEqual(71, Calls[1])
	} finally _HC_Session := SavedSession
}
Test("HealthCheck extensive: quick privacy opt-in creates no probe", _TestHC_ExtensiveAdmission.Bind(false, 0))
Test("HealthCheck extensive: explicit opt-in reaches actual starter once", _TestHC_ExtensiveAdmission.Bind(true, 1))



; Every section the schema declares for Windows is produced, and nothing the
; schema does not declare: the page would never show it.
_TestHC_RunMatchesTheSchema() {
	Result := HealthCheck_Run()
	Schema := HealthCheck_Config()["schema"]
	for Section in Schema["sections"] {
		if (Section.Get("kind", "fields") == "summary") || !_HealthCheck_Applies(Section)
			continue
		Assert(Result["sections"].Has(Section["id"]), "the snapshot misses the section " . Section["id"])
	}
	Check := HealthCheck_CheckFields(Result, Schema)
	AssertEqual(0, Check["undeclared"].Length, "undeclared fields: " . _HC_Join(Check["undeclared"], ", "))
}

Test("HealthCheck: Run produces the schema's sections and only its fields",
	_TestHC_RunMatchesTheSchema)


_TestHC_RunReflectsCounters() {
	global _HealthCheckLastError

	HealthCheck_RecordWarn()
	HealthCheck_RecordError("run-reflects-test")

	Issues := HealthCheck_Run()["sections"]["issues"]
	Assert(Issues["warn_count"] >= 1, "warn_count must reflect recorded warnings")
	Assert(Issues["err_count"] >= 1, "err_count must reflect recorded errors")
	; HealthCheck_Run probes live adapters and may itself record a newer diagnostic.
	; The snapshot must therefore mirror the current healthcheck state at the end
	; of the probe, rather than assuming the pre-probe test message stays newest.
	AssertEqual(_HealthCheckLastError, Issues["last_error"],
		"last_error must reflect the healthcheck state captured by HealthCheck_Run")
}

Test("HealthCheck: Run reflects recorded warnings, errors, and last error message",
	_TestHC_RunReflectsCounters)


; The last error is the whole logged line, as on macOS and Linux: the bare body
; told a reader neither when it happened nor which module raised it.
_TestHC_LoggerErrorRecordsFullLine() {
	global _HealthCheckLastError
	Marker := "full-line-" . A_TickCount
	LoggerError("HcProbe", "boom {1}", Marker)
	AssertContains(_HealthCheckLastError, "[ERROR] [HcProbe] boom " . Marker,
		"a real LoggerError must reach the last error with its level and module")
}

Test("HealthCheck: a LoggerError is recorded as its full line (healthcheck-last-error-wired)",
	_TestHC_LoggerErrorRecordsFullLine)


_TestHC_RunSystemAndVersions() {
	Sections := HealthCheck_Run()["sections"]
	Assert(Sections["system"]["uptime"] >= 0, "uptime must be non-negative")
	AssertContains(Sections["system"]["os"], "Windows")
	AssertEqual("AutoHotkey " . A_AhkVersion, SubStr(Sections["versions"]["runtime"], 1, 11 + StrLen(A_AhkVersion)))
	Assert(Sections["developer"]["phase_a_ms"] is Number, "the synchronous phase must record its duration")
}

Test("HealthCheck: Run reports the system, the runtime and its own duration",
	_TestHC_RunSystemAndVersions)


; Open applications are opt-in: collected only when the user ticks the box.
_TestHC_RunningAppsAreOptIn() {
	AssertFalse(HealthCheck_Run(false)["sections"]["system"].Has("running_apps"),
		"the open applications must not be collected without details")
	Assert(HealthCheck_Run(true)["sections"]["system"]["running_apps"] is Array,
		"the open applications must be collected once details are included")
}

Test("HealthCheck: open applications are collected only with details (opt-in)",
	_TestHC_RunningAppsAreOptIn)


; Phase A runs on the thread that serves the keyboard hook, within 5 ms. The
; recent-issue bounds were read and parsed from the shared tree on every
; opening (1.6 ms of that budget, measured): the shared documents are read
; once, so an opening after the first reads no shared file at all
; (phase-a-shared-files-once).
_TestHC_SecondOpeningReadsNoSharedFile() {
	global _SharedDir
	HealthCheck_Run()
	Saved := _SharedDir
	_SharedDir := A_Temp . "\ergopti_hc_no_shared_" . A_TickCount
	try {
		Issues := HealthCheck_Run()["sections"]["issues"]
	} finally {
		_SharedDir := Saved
	}
	AssertTrue(Issues.Has("recent_source"), "the issues section must be collected")
	AssertTrue(Issues["recent_source"] != "unavailable",
		"a second opening read the recent-issue bounds from the shared tree again")
}

Test("HealthCheck: an opening after the first reads no shared file (phase-a-shared-files-once)",
	_TestHC_SecondOpeningReadsNoSharedFile)


; Phase A logged its own overrun of the budget as a WARNING, which the next
; snapshot counted among the session's problems: the window inflated the
; counts it reports. The duration stays in the developer section. Compared
; with the same two collections under a budget they cannot overrun, so a
; collector's own warning does not count here (phase-a-budget-not-a-warning).
_TestHC_OverBudgetIsNotAWarning() {
	global _HealthCheckWarnCount
	Schema := HealthCheck_Config()["schema"]
	Saved := Schema["phase_a_budget_ms"]
	try {
		Schema["phase_a_budget_ms"] := 1000000
		Before := _HealthCheckWarnCount
		HealthCheck_Run()
		HealthCheck_Run()
		WithinBudget := _HealthCheckWarnCount - Before
		; Every collection overruns a negative budget
		Schema["phase_a_budget_ms"] := -1
		Before := _HealthCheckWarnCount
		HealthCheck_Run()
		Last := HealthCheck_Run()
		OverBudget := _HealthCheckWarnCount - Before
	} finally {
		Schema["phase_a_budget_ms"] := Saved
	}
	AssertEqual(WithinBudget, OverBudget, "an over-budget collection logged a warning")
	Assert(Last["sections"]["developer"]["phase_a_ms"] is Number, "the duration stays in the developer section")
}

Test("HealthCheck: an over-budget collection is not a warning (phase-a-budget-not-a-warning)",
	_TestHC_OverBudgetIsNotAWarning)


; =============================================
; ======= 2b/ The probes ======================
; =============================================

_TestHC_GithubAnswerIsRead() {
	Answer := _HC_GithubAnswer(200, '{"resources":{"core":{"limit":60,"remaining":57}}}')
	AssertEqual("ok", Answer["result"]["state"])
	AssertEqual("HTTP 200, 57/60", Answer["sections"]["network"]["github_api"])
	AssertEqual("HTTP 503", _HC_GithubAnswer(503, "")["result"]["detail"])
	AssertEqual("error", _HC_GithubAnswer(0, "")["result"]["state"], "no answer at all is an error, not a success")
}

Test("HealthCheck: the GitHub probe reads the rate limit and reports a failed request",
	_TestHC_GithubAnswerIsRead)


; A probe answers once into its run, and a cancelled run publishes nothing.
_TestHC_CancelledRunPublishesNothing() {
	global _HC_ProbeRun
	Published := []
	Aborted := []
	Request := { Abort: (*) => (Aborted.Push(true), true) }
	Run := { Epoch: 5, Cancelled: false, Requests: [Request], Publish: (Epoch, Id, Result, Sections) => Published.Push(Id) }
	_HC_ProbeFinish(Run, "github_api", A_TickCount, Map("state", "ok"))
	AssertEqual(1, Published.Length, "a live run publishes its answer")
	Saved := _HC_ProbeRun
	try {
		_HC_ProbeRun := Run
		HealthCheck_CancelProbes()
		AssertTrue(Run.Cancelled, "cancelling marks the run")
		AssertEqual(1, Aborted.Length, "cancelling stops the run's curl children")
		AssertEqual(0, _HC_ProbeRun, "no run remains current")
		_HC_ProbeFinish(Run, "ai_health", A_TickCount, Map("state", "ok"))
		AssertEqual(1, Published.Length, "a cancelled run must not publish a late answer")
		HealthCheck_CancelProbes()
	} finally {
		_HC_ProbeRun := Saved
	}
}

Test("HealthCheck: a cancelled probe run publishes nothing and stops its children",
	_TestHC_CancelledRunPublishesNothing)


; The load: the machine's processor, and ErgoptiPlus's own share of it and
; memory, which a report of a slow or stuck driver is read for (system-load).
_TestHC_ProcessMemoryInPhaseA() {
	Memory := HealthCheck_Run()["sections"]["system"].Get("process_memory", 0)
	AssertTrue(Memory is Integer, "the working set is a byte count")
	AssertTrue(Memory > 1048576, "a running AutoHotkey process uses more than 1 MB, got " . Memory)
}

Test("HealthCheck: phase A reports ErgoptiPlus's memory (system-load)", _TestHC_ProcessMemoryInPhaseA)

_TestHC_CpuSharesArithmetic() {
	; 100 ns units; Windows counts the idle time inside the kernel time
	Before := Map("idle", 1000, "kernel", 3000, "user", 1000, "process", 100)
	After := Map("idle", 2500, "kernel", 6000, "user", 2000, "process", 500)
	Shares := HealthCheck_CpuShares(Before, After)
	AssertEqual(62.5, Shares["system"], "4000 elapsed, 1500 idle")
	AssertEqual(10.0, Shares["process"], "400 of 4000")
	Threw := false
	try HealthCheck_CpuShares(After, After)
	catch ValueError
		Threw := true
	AssertTrue(Threw, "two identical samples measure nothing and must say so")
}

Test("HealthCheck: the processor shares come from two samples (system-load)", _TestHC_CpuSharesArithmetic)

_TestHC_CpuProbeSamplesTwice() {
	Published := []
	Run := { Epoch: 7, Cancelled: false, Requests: [],
		Publish: (Epoch, Id, Result, Sections) => Published.Push(Map("id", Id, "result", Result, "sections", Sections)) }
	_HC_ProbeCpu(Run, Map("sample_ms", 30, "timeout_ms", 4000))
	AssertEqual(0, Published.Length, "the second sample waits for its timer")
	Deadline := A_TickCount + 2000
	while (Published.Length = 0 && A_TickCount < Deadline)
		Sleep(20)
	AssertEqual(1, Published.Length, "the probe answers once after its sample")
	AssertEqual("cpu_load", Published[1]["id"])
	AssertEqual("ok", Published[1]["result"]["state"])
	System := Published[1]["sections"]["system"]
	for Key in ["cpu_usage", "process_cpu"]
		AssertTrue(System[Key] >= 0 && System[Key] <= 100, Key . " is a share of the machine, got " . System[Key])
	Cancelled := { Epoch: 8, Cancelled: false, Requests: [], Publish: (*) => Published.Push("late") }
	_HC_ProbeCpu(Cancelled, Map("sample_ms", 30, "timeout_ms", 4000))
	Cancelled.Cancelled := true
	Sleep(150)
	AssertEqual(1, Published.Length, "a cancelled sample publishes nothing")
}

Test("HealthCheck: the processor probe publishes the load once (system-load)", _TestHC_CpuProbeSamplesTwice)


; =============================================
; ======= 3/ Registered in run_all ============
; =============================================

_TestHC_FunctionsExist() {
	Assert(IsSet(HealthCheck_RecordWarn),
		"HealthCheck_RecordWarn must be defined")
	Assert(IsSet(HealthCheck_RecordError),
		"HealthCheck_RecordError must be defined")
	Assert(IsSet(HealthCheck_Run),
		"HealthCheck_Run must be defined")
}

Test("HealthCheck: core functions are defined (core.ahk included in run_all)",
	_TestHC_FunctionsExist)

_TestHC_NativeSnapshotText() {
	global _I18nCache, _I18nCacheLoaded
	SavedCache := _I18nCache, SavedLoaded := _I18nCacheLoaded
	try {
		_I18nCache := Map("healthcheck.deep_tests.title", "In-depth checks",
			"healthcheck.probe.not_run", "Not run: %s",
			"healthcheck.deep_tests.reason.not_embedded", "The suite is not embedded",
			"healthcheck.export.privacy_notice", "Only approved technical facts are shared")
		_I18nCacheLoaded := true
		Snapshot := Map("driver", "windows", "generated_at", "2026-10-09T09:10:36Z", "sections", Map())
		Text := _HC_NativeSnapshotText(Snapshot)
		Config := HealthCheck_Config()
		AssertContains(Text, Config["schema"]["export_strings"][Config["schema"]["share_policy"]["notice_key"]],
			"Native fallback uses canonical English without consulting the UI notice override.")
		AssertContains(Text, "driver-suites: not_run")
		AssertContains(Text, "page-model-checks: not_collected")
		AssertContains(Text, '"driver":"windows"')
		AssertContains(Text, '"generated_at":"2026-10-09T09:10:36Z"')
		AssertEqual(0, InStr(Text, "%s"), "the native fallback must interpolate the locale placeholder")
	} finally {
		_I18nCache := SavedCache, _I18nCacheLoaded := SavedLoaded
	}
}
Test("HealthCheck: native quick export formats the unexecuted-test reason", _TestHC_NativeSnapshotText)

_TestHC_StructuredNativeFallback() {
	Snapshot := Map("driver", "windows", "generated_at", "2026-10-01T21:35:37Z",
		"sections", Map(
			"system", Map("ram_free", 1512222720, "keyboard_layout", "0xFC06040C"),
			"issues", Map("recent", ["first warning", "second warning"], "warn_count", 2)))
	Window := _HC_NewWindow()
	try {
		Tree := _HC_ShowNativeSnapshot(Window, Snapshot)
		Assert(Window.NativeDiagnostics == Tree,
			"the window must own the native control for resize and destruction")
		Summary := Tree.GetNext(0)
		AssertEqual(t("healthcheck.section.summary"), Tree.GetText(Summary))
		System := Tree.GetNext(Summary)
		AssertEqual(t("healthcheck.section.system"), Tree.GetText(System),
			"sections must follow the shared schema, not Map's key order")
		Item := Tree.GetChild(System)
		AssertEqual(t("healthcheck.field.keyboard_layout") . ": 0xFC06040C", Tree.GetText(Item))
		Item := Tree.GetNext(Item)
		AssertEqual(t("healthcheck.field.ram_free") . ": 1512222720", Tree.GetText(Item))
		Issues := Tree.GetNext(System)
		AssertEqual(t("healthcheck.section.issues"), Tree.GetText(Issues))
		Node := Tree.GetChild(Issues)
		while Node && Tree.GetText(Node) != t("healthcheck.field.recent")
			Node := Tree.GetNext(Node)
		Assert(Node != 0, "recent issues must be a separate expandable field")
		First := Tree.GetChild(Node)
		AssertEqual("1: first warning", Tree.GetText(First))
		AssertEqual("2: second warning", Tree.GetText(Tree.GetNext(First)),
			"each log record must be readable separately")
		AssertEqual(0, Tree.GetNext(Issues), "absent sections must not create empty headings")
		_HC_OnSize(Tree, Window, 0, 720, 520)
		Tree.GetPos(, , &Width, &Height)
		AssertEqual(720, Width, "the native view must resize with the host")
		AssertEqual(520 - HC_NATIVE_EXPORT_ROW, Height, "the native toolbar remains outside the resized tree")
		AssertTrue(Window.NativeCollection["start"].Enabled, "Native Diagnostics retains the one-click collection action.")
		Window.NativeCollection["progress"].GetPos(, &ProgressY)
		AssertTrue(ProgressY + 24 <= 520, "the actual native progress control remains within the host")
	} finally {
		Window.Destroy()
	}
}
Test("HealthCheck: real browser failure retains schema-ordered native sections and separate logs",
	_TestHC_StructuredNativeFallback)

/** Replay the actual poll with a deterministic tick and a recording request. */
_TestHC_ProbeRollover(Started, Elapsed, Completed := false, Cancellation := "", AbortAllowed := true) {
	Now := Started + Elapsed
	Published := [], Arms := [], Aborts := [], Waits := [], Interpretations := []
	Request := { Status: 200, ResponseText: "literal-success", WaitForResponse: Wait, Abort: Abort }
	ProbeRun := { Epoch: 73, Cancelled: Cancellation == "before", Requests: [Request], Publish: Publish }
	Wait(This, Milliseconds) {
		AssertEqual(0, Milliseconds, "the actual poll never waits for network work")
		Waits.Push(Milliseconds)
		return Completed
	}
	Abort(This) {
		Aborts.Push(true)
		if Cancellation == "abort"
			ProbeRun.Cancelled := true
		return AbortAllowed
	}
	Publish(Epoch, Id, Result, Sections) {
		AssertEqual(73, Epoch, "publication retains the admitted window epoch")
		AssertEqual("clock-regression", Id)
		AssertTrue(Sections is Map)
		Published.Push(Result)
	}
	Interpret(Status, Body) {
		AssertEqual(200, Status)
		AssertEqual("literal-success", Body)
		Interpretations.Push(true)
		return Map("result", Map("state", "ok"))
	}
	Arm(ActualRun, Id, ActualRequest, ActualInterpret, ActualStarted, Timeout) {
		AssertTrue(ActualRun == ProbeRun && ActualRequest == Request, "rearming keeps exact owner identities")
		AssertTrue(ActualInterpret == Interpret)
		AssertEqual(Started, ActualStarted)
		AssertEqual(2000, Timeout)
		Arms.Push(Id)
	}
	_HC_ProbeStarted("clock-regression", "isolated deterministic polling")
	_HC_ProbePoll(ProbeRun, "clock-regression", Request, Interpret, Started, 2000, Now, Arm)
	InitiallyCancelled := Cancellation == "before"
	Overdue := !Completed && Elapsed > 3000
	Terminal := !InitiallyCancelled && (Completed || Overdue) && !(Overdue && Cancellation == "abort")
	AssertEqual(InitiallyCancelled ? 0 : 1, Waits.Length, "a retired run never queries the transport")
	AssertEqual(!InitiallyCancelled && Completed ? 1 : 0, Interpretations.Length,
		"a pending timeout cannot become an interpreted success")
	AssertEqual(Terminal ? 1 : 0, Published.Length, "only terminal current results publish once")
	AssertEqual(!InitiallyCancelled && Overdue ? 1 : 0, Aborts.Length)
	AssertEqual(!InitiallyCancelled && !Completed && !Overdue ? 1 : 0, Arms.Length,
		"the exact budget remains pending under the existing strict greater-than rule")
	AssertTrue(ProbeRun.Requests.Length == 1 && ProbeRun.Requests[1] == Request,
		"transport cleanup authority remains attached even when Abort refuses")
	if Terminal {
		AssertEqual(Completed ? "ok" : "timeout", Published[1]["state"],
			"pending expiry stays timeout even when transport cleanup refuses")
		AssertEqual(Elapsed, Published[1]["ms"], "published duration retains the full native monotonic difference")
	} else if !InitiallyCancelled && !Overdue {
		ProbeRun.Cancelled := true
		_HC_ProbePoll(ProbeRun, "clock-regression", Request, Interpret, Started, 2000, Now, Arm)
		AssertEqual(0, Published.Length, "later cancellation cannot publish the pending result")
		AssertEqual(1, Waits.Length, "the cancelled replay cannot touch its transport")
		AssertEqual(1, Arms.Length, "the cancelled replay cannot schedule more work")
	}
}

/** Every finish caller retains full native duration without changing its result. */
_TestHC_ProbeFinishRollover(Started, Elapsed := 80) {
	Published := []
	Sections := Map("system", Map("fixture", "unchanged"))
	Result := Map("state", "error", "detail", "literal-error")
	ProbeRun := { Epoch: 93, Cancelled: false, Publish: Publish }
	Publish(Epoch, Id, ActualResult, ActualSections) {
		AssertEqual(93, Epoch)
		AssertEqual("clock-finish", Id)
		AssertTrue(ActualResult == Result && ActualSections == Sections, "finish retains actual result and section objects")
		Published.Push(ActualResult)
	}
	_HC_ProbeStarted("clock-finish", "isolated finish duration")
	_HC_ProbeFinish(ProbeRun, "clock-finish", Started, Result, Sections, Started + Elapsed)
	AssertEqual(1, Published.Length)
	AssertEqual(Elapsed, Result["ms"], "the shared finish owner retains full native elapsed time")
	AssertEqual("error", Result["state"], "an elapsed-time fix cannot convert failure into success")
	AssertEqual("literal-error", Result["detail"])
}

for _HCClockOrigin in [100, 0xFFFFFFF0] {
	_HCClockLabel := _HCClockOrigin == 100 ? "ordinary" : "DWORD-boundary"
	for _HCClockElapsed in [2999, 3000, 3001]
		Test("HealthCheck probe-clock-native64: " . _HCClockLabel . " budget " . _HCClockElapsed,
			_TestHC_ProbeRollover.Bind(_HCClockOrigin, _HCClockElapsed))
	Test("HealthCheck probe-clock-native64: " . _HCClockLabel . " observed completion wins",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, true))
	Test("HealthCheck probe-clock-native64: " . _HCClockLabel . " cancelled run drops completion",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, true, "before"))
	Test("HealthCheck probe-clock-native64: " . _HCClockLabel . " abort refusal remains timeout",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, false, "", false))
	Test("HealthCheck probe-clock-native64: " . _HCClockLabel . " cancellation during abort drops result",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, false, "abort"))
	Test("HealthCheck probe-clock-native64: " . _HCClockLabel . " shared finish retains failure",
		_TestHC_ProbeFinishRollover.Bind(_HCClockOrigin))
}

for _HCClockOrigin in [100, 0x100000064] {
	for _HCClockElapsed in [0x100000BB7, 0x100000BB8, 0x100000BB9]
		Test("HealthCheck probe-clock-native64: long budget origin=" . _HCClockOrigin . " elapsed=" . _HCClockElapsed,
			_TestHC_ProbeRollover.Bind(_HCClockOrigin, _HCClockElapsed))
	Test("HealthCheck probe-clock-native64: long observed completion origin=" . _HCClockOrigin,
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 0x100000FA0, true))
	Test("HealthCheck probe-clock-native64: long cancelled origin=" . _HCClockOrigin,
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 0x100000FA0, true, "before"))
	Test("HealthCheck probe-clock-native64: long abort refusal origin=" . _HCClockOrigin,
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 0x100000FA0, false, "", false))
	Test("HealthCheck probe-clock-native64: long cancellation during abort origin=" . _HCClockOrigin,
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 0x100000FA0, false, "abort"))
	Test("HealthCheck probe-clock-native64: long shared finish origin=" . _HCClockOrigin,
		_TestHC_ProbeFinishRollover.Bind(_HCClockOrigin, 0x100000050))
}


/** Exercises the actual cancel/refresh/export owner without a live WebView or probe run. */
_TestHC_CancelRefreshExportHistory(Refresh := true) {
	global _HC_Session, _HC_ResetDone, _HC_ProbeRun
	if _HC_ProbeRun
		throw Error("A foreign diagnostic probe run is active.")
	SavedSession := _HC_Session, SavedReset := _HC_ResetDone, SavedProbeRun := _HC_ProbeRun
	try {
		_HC_ResetDone := true
		; This Windows-host fixture supplies the identity required by typed sharing.
		_HC_Session := Map("snapshot", Map("driver", "windows", "probes", Map(
			"github_api", Map("state", "timeout", "cleanup", "unknown", "ms", 23),
			"ai_health", Map("state", "pending"))), "extensive", false, "detailed", false)
		Config := HealthCheck_Config()
		AssertEqual("windows", _HC_Session["snapshot"]["driver"], "the native Windows fixture has its host identity before cancel/export")
		AssertEqual("windows", HealthCheck_ShareSnapshot(_HC_Session["snapshot"], Config["schema"])["driver"],
			"the genuine sharing owner admits the fixture's known host identity")
		AssertThrows(() => HealthCheck_ShareSnapshot(Map("probes", Map()), Config["schema"]),
			"the genuine sharing owner still refuses a missing host identity")
		AssertThrows(() => HealthCheck_ShareSnapshot(Map("driver", "unknown", "probes", Map()), Config["schema"]),
			"the genuine sharing owner still refuses an invalid host identity")
		_HC_PerformPageAction(0, Map("action", "cancel"), Config)
		if Refresh {
			_HC_PerformPageAction(0, Map("action", "refresh", "detailed", false, "extensive", false), Config)
			AssertTrue(_HC_Session["snapshot"].Has("retired_probes"), "refresh must retain unconfirmed prior cleanup")
			AssertEqual(1, _HC_Session["snapshot"]["retired_probes"].Length)
			_HC_PerformPageAction(0, Map("action", "refresh", "detailed", false, "extensive", false), Config)
			AssertEqual(1, _HC_Session["snapshot"]["retired_probes"].Length, "idle refresh must not duplicate the cohort")
		}
		_HC_PerformPageAction(0, Map("action", "export_snapshot", "export_sequence", 3), Config)
		Encoded := JsonParse(_HC_ValueToJson(_HC_Session["snapshot"]))
		Rows := Refresh ? Encoded["retired_probes"][1]["probes"] : Encoded["probes"]
		AssertEqual("timeout", Rows["github_api"]["state"], "cleanup metadata must not change a terminal business result")
		AssertEqual("unknown", Rows["github_api"]["cleanup"], "export must not invent a cleanup ACK")
		AssertEqual(23, Rows["github_api"]["ms"])
		AssertEqual("cancelled", Rows["ai_health"]["state"])
		AssertEqual("pending", Rows["ai_health"]["cleanup"])
	} finally {
		_HC_Session := SavedSession
		_HC_ResetDone := SavedReset
		AssertEqual(SavedProbeRun, _HC_ProbeRun, "the fixture retains the exact idle probe owner after session/reset restoration")
	}
}
Test("HealthCheck cleanup-history: cancel then refresh then export preserves unknown cleanup", _TestHC_CancelRefreshExportHistory)
Test("HealthCheck cleanup-history: immediate cancel export retains existing truthful metadata", _TestHC_CancelRefreshExportHistory.Bind(false))

/** Runs collection state regressions in an owned synthetic directory without launching a worker. */
_TestHC_CollectionState(TestCase) {
	D := DiagnosticCollectionWindows()
	Root := A_Temp . "\ergopti-hc-collection-" . D.Id
	D.Directory := Root . "\" . D.Id
	D.Archive := D.Directory . ".zip"
	DirCreate(Root)
	try {
		if TestCase == "launch-failure" {
			FileAppend("synthetic blocker", D.Directory, "UTF-8-RAW")
			AssertEqual(false, D.Start(), "A pre-spawn filesystem failure must be contained.")
			AssertTrue(D.Terminal, "No native task exists; the failed session must allow retry.")
			AssertEqual("failed", D.Result["phase"])
			AssertEqual("synthetic blocker", FileRead(D.Directory, "UTF-8"), "The preexisting file is not owned output.")
		} else {
			DirCreate(D.Directory)
			if TestCase == "cancel" {
				AssertTrue(D.Cancel())
				First := D.CancelTick
				AssertTrue(D.Cancel())
				AssertEqual(First, D.CancelTick, "Repeated cancellation must not postpone retirement.")
				AssertEqual(false, D.SkipGuided(), "Cancelled observations cannot be acknowledged.")
				AssertTrue(FileExist(D.Directory . "\cancel"))
				AssertEqual(false, D.Terminal, "A request is not a native retirement acknowledgement.")
			} else if TestCase == "skip" {
				AssertTrue(D.SkipGuided())
				Receipt := JsonParse(FileRead(D.Directory . "\physical.json", "UTF-8"))
				AssertEqual("SKIP", Receipt["physical_text"])
				AssertEqual("SKIP", Receipt["physical_display"])
				AssertEqual(D.Id, Receipt["session_id"])
				D.Completed(1, "", "")
				AssertTrue(D.Terminal)
				AssertEqual("failed", D.Result["phase"])
				AssertEqual(false, D.Result["archive_created"])
			} else if TestCase == "progress" {
				Value := Map("schema_version", 1, "session_id", D.Id, "phase", "guided", "completed", 0,
					"total", D.Contract["checks"].Length, "results", [])
				AssertTrue(D.AcceptProgress(Value))
				Bad := Value.Clone(), Bad["session_id"] := "foreign"
				AssertThrows(() => D.AcceptProgress(Bad))
				Bad := Value.Clone(), Bad["completed"] := 1
				AssertThrows(() => D.AcceptProgress(Bad))
				Bad := Value.Clone(), Bad["completed"] := 1
				Bad["results"] := [Map("id", "callbacks", "status", "PASS", "evidence_class", "unexecuted")]
				AssertThrows(() => D.AcceptProgress(Bad), "An unexecuted check must never become PASS.")
				Bad["results"][1]["status"] := "UNRUN"
				AssertTrue(D.AcceptProgress(Bad))
				Pending := Value.Clone(), Pending["phase"] := "completed", Pending["archive_created"] := true
				Pending["results"] := []
				for Id in D.Contract["checks"]
					Pending["results"].Push(Map("id", Id, "status", "UNRUN", "evidence_class", "unexecuted"))
				Pending["completed"] := Pending["results"].Length
				AssertTrue(D.AcceptProgress(Pending))
				AssertEqual("retiring", D.Result["phase"], "Worker progress cannot attest to native task retirement.")
				AssertFalse(D.Result["archive_created"], "Only the exact terminal acknowledgement may expose the archive action.")
				AssertTrue(D.Result["owner_pending"])
				D.Completed(1, "", "")
				AssertFalse(D.AcceptProgress(Value), "Stale progress cannot resurrect a retired session.")
				AssertEqual("failed", D.Result["phase"])
			} else if TestCase == "terminate-reentry" {
				D.Task := {requestTerminate: Retire}
				Retire(This) {
					D.Completed(1, "", "")
					return true
				}
				D.Write("progress.json", Map("schema_version", 1, "session_id", D.Id, "phase", "guided", "completed", 0,
					"total", D.Contract["checks"].Length, "results", []))
				D.Cancel()
				D.CancelTick := A_TickCount - D.Contract["retirement_grace_ms"] - 1
				D.Tick()
				AssertTrue(D.Terminal)
				AssertEqual("failed", D.Result["phase"], "Synchronous retirement cannot be overwritten by stale guided progress.")
			} else if TestCase == "exit-refusal" {
				D.Task := {requestTerminate: (*) => false}
				AssertEqual(1, D.Exit("Exit", 0), "Unacknowledged worker retirement must veto application exit.")
				AssertFalse(D.Terminal)
				AssertFalse(FileExist(D.Directory . "\host-exit.json"), "A refused exit cannot write a cleanup acknowledgement.")
			} else if TestCase == "cancel-write-failure" {
				D.DefineProp("Write", {Call: RefuseWrite})
				RefuseWrite(This, Name, Value) {
					throw Error("Injected cancellation filesystem failure.")
				}
				AssertTrue(D.Cancel(), "A failed control write cannot crash the cancellation action.")
				AssertTrue(D.Result["cancel_control_failed"])
				AssertEqual("cleanup_pending", D.Result["phase"])
				AssertFalse(D.Terminal, "Control write failure cannot invent worker retirement.")
			} else if TestCase == "archive-ack" || TestCase == "archive-good" || TestCase == "archive-failed" {
				FileAppend("synthetic archive bytes", D.Archive, "UTF-8-RAW")
				Ack := Map("schema_version", 1, "session_id", D.Id, "archive_committed", true,
					"bytes", FileGetSize(D.Archive), "sha256", CryptoSha256Bytes(FileRead(D.Archive, "RAW")))
				if TestCase == "archive-ack" {
					Bad := Ack.Clone(), Bad["sha256"] := StrReplace(Ack["sha256"], SubStr(Ack["sha256"], 1, 1), "z")
					AssertTrue(D.Completed(0, _HC_ValueToJson(Bad), ""))
					AssertFalse(D.Result["archive_created"], "Existence and size alone cannot acknowledge an archive.")
					AssertFalse(D.Completed(0, _HC_ValueToJson(Ack), ""), "A duplicate completion cannot replace a failed terminal receipt.")
					AssertFalse(D.Result["archive_created"])
				} else if TestCase == "archive-failed" {
					AssertTrue(D.Completed(1, _HC_ValueToJson(Ack), ""))
					AssertEqual("failed", D.Result["phase"], "A valid ZIP cannot promote the worker's primary failure.")
					AssertTrue(D.Result["archive_created"], "Failed collection retains its exact acknowledged evidence archive.")
					AssertFalse(D.Result["owner_pending"], "Only canonical native completion retires worker custody.")
					AssertTrue(D.Result["worker_tree_retired"])
					AssertTrue(D.Result["folder_available"])
				} else {
					AssertTrue(D.Completed(0, _HC_ValueToJson(Ack), ""))
					AssertTrue(D.Result["archive_created"])
					FileAppend("replacement", D.Archive, "UTF-8-RAW")
					AssertFalse(D.OpenFolder(), "A changed archive must be refused before opening Explorer.")
				}
			}
		}
	} finally {
		SetTimer(D.CollectionTimer, 0)
		DirDelete(Root, true)
	}
}
Test("Diagnostics collection contains pre-spawn failure (groups247-collection)", (*) => _TestHC_CollectionState("launch-failure"))

/** Replays the worker's nullable failure receipt through the actual page serializer. */
_TestHC_CollectionNullableProgress() {
	global JSON_NULL
	D := DiagnosticCollectionWindows()
	Raw := '{"schema_version":1,"session_id":"' . D.Id . '","phase":"collecting","completed":1,"total":'
		. D.Contract["checks"].Length . ',"results":[{"id":"native_uia","status":"FAIL","evidence_class":"native_synthetic","receipt":null}]}'
	AssertTrue(D.AcceptProgress(JsonParse(Raw)))
	Published := JsonParse(_HC_ValueToJson(Map("type", "collection", "collection", D.Result)))
	Row := Published["collection"]["results"][1]
	AssertEqual("FAIL", Row["status"], "Transporting a missing receipt cannot promote the native failure.")
	AssertTrue(IsObject(Row["receipt"]) && ObjPtr(Row["receipt"]) == ObjPtr(JSON_NULL),
		"The worker's JSON null retains its exact sentinel through page publication.")
	AssertTrue(Published["collection"]["owner_pending"])
	AssertFalse(Published["collection"]["archive_created"])
}
Test("Diagnostics collection publishes actual nullable worker receipts (groups247-collection)", _TestHC_CollectionNullableProgress)
Test("Diagnostics collection cancellation retains acknowledgement ownership (groups247-collection)", (*) => _TestHC_CollectionState("cancel"))
Test("Diagnostics collection skipped physical checks never pass (groups247-collection)", (*) => _TestHC_CollectionState("skip"))
Test("Diagnostics collection validates progress and refuses resurrection (groups247-collection)", (*) => _TestHC_CollectionState("progress"))
Test("Diagnostics collection synchronous retirement keeps terminal state (groups247-collection)", (*) => _TestHC_CollectionState("terminate-reentry"))
Test("Diagnostics collection exit refusal keeps cleanup custody (groups247-collection)", (*) => _TestHC_CollectionState("exit-refusal"))
Test("Diagnostics collection archive acknowledgement binds exact bytes (groups247-collection)", (*) => _TestHC_CollectionState("archive-ack"))
Test("Diagnostics collection rejects replaced acknowledged archives (groups247-collection)", (*) => _TestHC_CollectionState("archive-good"))
Test("Diagnostics collection failed cancel write retains cleanup custody (groups247-collection)", (*) => _TestHC_CollectionState("cancel-write-failure"))

_TestHC_ResidentObservationProjection() {
	Assert(IsSet(DiagSnapshot_ResidentObservations), "the collecting resident must produce its own closed observations")
	global HSE_Buffer, HSE_LastMatch, _PrefixBuffer
	Saved := [HSE_Buffer, HSE_LastMatch, _PrefixBuffer]
	Sentinel := "private synthetic corpus token sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	try {
		HSE_Buffer := Sentinel, HSE_LastMatch := Sentinel, _PrefixBuffer := Sentinel
		Receipt := DiagSnapshot_ResidentObservations()
		AssertEqual(1, Receipt["schema_version"])
		Assert(Receipt["captured_at_filetime"] is Integer && Receipt["captured_at_filetime"] > 0)
		AssertEqual(4, Receipt["rows"].Length)
		AssertFalse(InStr(_HC_ValueToJson(Receipt), Sentinel), "private input and corpus values cannot enter technical observations")
		for Row in Receipt["rows"] {
			AssertFalse(Row["scenario_qualified"], "a state read cannot qualify the unexecuted functional scenario")
			AssertTrue(Row["values"] is Map)
		}
		AssertEqual("runtime_state", Receipt["rows"][1]["scope"])
		AssertEqual("UNRUN", Receipt["rows"][2]["status"], "an absent production runtime cannot become native identity evidence")
		AssertEqual("UNRUN", Receipt["rows"][3]["status"], "headless execution cannot start a native capture owner")
		AssertEqual("UNRUN", Receipt["rows"][4]["status"], "headless execution cannot load or initialize a native DLL")
	} finally {
		HSE_Buffer := Saved[1], HSE_LastMatch := Saved[2], _PrefixBuffer := Saved[3]
	}
}
Test("Diagnostics collection projects resident observations without private content (groups247-resident-observations)", _TestHC_ResidentObservationProjection)

_TestHC_ResidentIdentityDebt() {
	global _OllamaIdentityPendingHandles, _LLM_ManagedBootstrap
	SavedHandles := _OllamaIdentityPendingHandles, SavedFlow := _LLM_ManagedBootstrap
	try {
		; Zero is an invalid recording handle, never an acquired process resource.
		Debt := Map(0, true)
		_OllamaIdentityPendingHandles := Debt
		_LLM_ManagedBootstrap := {Port: 0, Ready: true, Runtime: {Record: Map("target", Map())}}
		Receipt := DiagSnapshot_ResidentObservations()
		Row := Receipt["rows"][2]
		AssertEqual("UNRUN", Row["status"], "an existing probe-handle debt refuses another identity query")
		AssertEqual("native_identity_cleanup_pending", Row["reason"])
		AssertEqual(1, Row["values"]["identity_handle_debt"])
		AssertTrue(_OllamaIdentityPendingHandles == Debt)
		AssertTrue(Debt.Has(0), "collection cannot retire another operation's retained handle")
		AssertFalse(Row["scenario_qualified"])
	} finally {
		_OllamaIdentityPendingHandles := SavedHandles
		_LLM_ManagedBootstrap := SavedFlow
	}
}
Test("Diagnostics collection preserves existing identity handle debt (groups247-resident-observations)", _TestHC_ResidentIdentityDebt)

Test("Diagnostics collection primary failure retains its verified archive (groups247-collection)", (*) => _TestHC_CollectionState("archive-failed"))

/** Receives a real exclusive native writer without inventing a progress or retirement ACK. */
_TestHC_CollectionExclusiveProgress(Scenario := "retry") {
	D := DiagnosticCollectionWindows()
	Root := A_Temp . "\ergopti-hc-exclusive-" . D.Id
	D.Directory := Root . "\" . D.Id
	D.Archive := D.Directory . ".zip"
	DirCreate(D.Directory)
	Handle := 0
	try {
		D.Write("progress.json", Map("schema_version", 1, "session_id", D.Id, "phase", "guided", "completed", 0,
			"total", D.Contract["checks"].Length, "results", []))
		Handle := DllCall("CreateFileW", "Str", D.Directory . "\progress.json", "UInt", 0xC0000000,
			"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Handle && Handle != -1, "The native writer must own an exclusive real file handle.")
		if Scenario == "deadline"
			D.Started := A_TickCount - D.Contract["deadline_ms"] - 1
		D.Tick()
		AssertFalse(D.ProgressFault, "A sharing conflict is not invalid progress or a worker completion.")
		AssertFalse(D.Terminal, "A retry cannot attest to native task retirement.")
		AssertEqual(Scenario == "deadline", D.Cancelled, "The original deadline still cancels behind a busy writer.")
		AssertTrue(DllCall("CloseHandle", "Ptr", Handle, "Int"))
		Handle := 0
		if Scenario == "malformed" {
			FileDelete(D.Directory . "\progress.json")
			FileAppend("invalid JSON", D.Directory . "\progress.json", "UTF-8-RAW")
			D.Tick()
			AssertTrue(D.ProgressFault, "Actual malformed bytes must still fail closed after the writer retires.")
			AssertTrue(D.Cancelled)
			AssertEqual("invalid_progress", D.Result["reason"])
		} else if Scenario == "retry" {
			D.Tick()
			AssertFalse(D.ProgressFault)
			AssertEqual("guided", D.Result["phase"], "The next normal read receives the actual committed progress.")
			AssertTrue(D.Result["owner_pending"])
			AssertFalse(D.Result["archive_created"])
		}
	} finally {
		if Handle
			AssertTrue(DllCall("CloseHandle", "Ptr", Handle, "Int"))
		SetTimer(D.CollectionTimer, 0)
		DirDelete(Root, true)
	}
}
Test("Diagnostics collection retries actual exclusive progress writes (groups247-collection)", _TestHC_CollectionExclusiveProgress)
Test("Diagnostics collection preserves malformed progress refusal after sharing (groups247-collection)", _TestHC_CollectionExclusiveProgress.Bind("malformed"))
Test("Diagnostics collection keeps its deadline behind exclusive progress (groups247-collection)", _TestHC_CollectionExclusiveProgress.Bind("deadline"))

/** Supplies deterministic boundaries while retaining the actual control owner. */
_TestHC_WindowControlState() {
	State := {Message: 0xC001, Ready: true, Opened: 0, Listeners: [], Timers: [],
		ThrowListen: false, ThrowArm: false, ThrowCancel: false, ThrowShow: false,
		WithdrawReady: false, WithdrawArm: false, WithdrawMessage: false,
		WithdrawListen: false, ReenterShow: false}
	State.Control := HealthCheckWindowControl(Message, Listen, Timer, Show, Ready, 101, 202, 303)
	return State
	Message() {
		if State.WithdrawMessage
			State.Control.Stop()
		return State.Message
	}
	Listen(Id, Callback, Threads) {
		State.Listeners.Push([Id, Callback, Threads])
		if State.WithdrawListen && Threads == 1
			State.Control.Stop()
		if State.ThrowListen
			throw Error("Injected listener boundary failure.")
	}
	Timer(Callback, Period) {
		State.Timers.Push([Callback, Period])
		if Period < 0 && State.WithdrawArm
			State.Control.Stop()
		if (Period < 0 && State.ThrowArm) || (Period == 0 && State.ThrowCancel)
			throw Error("Injected timer boundary failure.")
	}
	Ready() {
		if State.WithdrawReady
			State.Control.Stop()
		return State.Ready
	}
	Show() {
		State.Opened += 1
		if State.ThrowShow
			throw Error("Injected window construction failure.")
		if State.ReenterShow
			AssertEqual(1, State.Control.OnMessage(202, 303, State.Message, 101))
	}
}

_TestHC_WindowControlDeferred() {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	AssertEqual(1, State.Listeners.Length)
	AssertEqual(1, State.Listeners[1][3])
	AssertEqual(1, Control.OnMessage(202, 303, State.Message, 101))
	AssertEqual(0, State.Opened, "A synchronous Win32 sender never enters WebView2.")
	AssertEqual(1, Control.OnMessage(202, 303, State.Message, 101))
	AssertEqual(1, State.Timers.Length, "Pending window requests coalesce.")
	AssertEqual(-1, State.Timers[1][2])
	AssertTrue(Control.Open())
	AssertEqual(1, State.Opened)
	AssertFalse(Control.Open(), "An already spent callback cannot open another window.")
	Control.Stop()
	AssertEqual(0, State.Listeners[2][3])
}
Test("Diagnostics control opens through one deferred request (diagnostics-control)", _TestHC_WindowControlDeferred)

_TestHC_WindowControlWrongTarget(Scenario) {
	State := _TestHC_WindowControlState(), Control := State.Control
	if Scenario != "unstarted"
		Control.Start()
	if Scenario == "not-ready"
		State.Ready := false
	AssertEqual(0, Control.OnMessage(Scenario == "wparam" ? 1 : 202,
		Scenario == "lparam" ? 1 : 303, Scenario == "message" ? 0xC002 : State.Message,
		Scenario == "window" ? 102 : 101))
	AssertEqual(0, State.Timers.Length)
	AssertEqual(0, State.Opened)
	Control.Stop()
}
for _HCControlWrong in ["unstarted", "not-ready", "wparam", "lparam", "message", "window"]
	Test("Diagnostics control rejects " . _HCControlWrong . " (diagnostics-control)",
		_TestHC_WindowControlWrongTarget.Bind(_HCControlWrong))

_TestHC_WindowControlInvalidMessage(Value) {
	State := _TestHC_WindowControlState(), State.Message := Value
	AssertThrows(() => State.Control.Start())
	AssertEqual(0, State.Listeners.Length)
	AssertFalse(State.Control.Active)
	State.Control.Stop()
}
for _HCControlMessage in [0, -1, "49153", 0xBFFF, 0x10000]
	Test("Diagnostics control refuses message " . _HCControlMessage . " (diagnostics-control)",
		_TestHC_WindowControlInvalidMessage.Bind(_HCControlMessage))

_TestHC_WindowControlWithdrawal(Phase) {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	if Phase == "ready"
		State.WithdrawReady := true
	if Phase == "arm"
		State.WithdrawArm := true
	Ack := Control.OnMessage(202, 303, State.Message, 101)
	if Phase == "pending"
		Control.Stop()
	if Phase == "not-ready"
		State.Ready := false
	AssertEqual(Phase == "ready" || Phase == "arm" ? 0 : 1, Ack)
	AssertFalse(Control.Open(), "A withdrawn request cannot open a successor window.")
	AssertEqual(0, State.Opened)
	Control.Stop()
	AssertThrows(() => Control.Start(), "A retired owner cannot be initialized again.")
}
for _HCControlPhase in ["ready", "arm", "pending", "not-ready"]
	Test("Diagnostics control fences " . _HCControlPhase . " withdrawal (diagnostics-control)",
		_TestHC_WindowControlWithdrawal.Bind(_HCControlPhase))

_TestHC_WindowControlRetainedTimer() {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start(), State.ThrowArm := true
	AssertEqual(0, Control.OnMessage(202, 303, State.Message, 101))
	AssertFalse(Control.Active)
	AssertTrue(Control.Pending, "A throwing arm can still own the callback.")
	State.ThrowCancel := true
	AssertThrows(() => Control.Stop())
	AssertTrue(Control.Pending, "Unknown cancellation cannot release the callback.")
	AssertFalse(Control.Listening, "Listener retirement is attempted even after cancellation fails.")
	AssertFalse(Control.Open())
	AssertEqual(0, State.Opened)
	State.ThrowCancel := false
	Control.Stop()
	AssertFalse(Control.Pending)
}
Test("Diagnostics control retains a throwing timer acquisition (diagnostics-control)", _TestHC_WindowControlRetainedTimer)

_TestHC_WindowControlRetainedListener() {
	State := _TestHC_WindowControlState(), Control := State.Control
	State.ThrowListen := true
	AssertThrows(() => Control.Start())
	AssertFalse(Control.Active)
	AssertTrue(Control.Listening)
	AssertThrows(() => Control.Stop())
	AssertTrue(Control.Listening, "Unknown unregistration retains its original listener.")
	AssertEqual(0, Control.OnMessage(202, 303, State.Message, 101))
	State.ThrowListen := false
	Control.Stop()
	AssertFalse(Control.Listening)
}
Test("Diagnostics control retains an uncertain listener (diagnostics-control)", _TestHC_WindowControlRetainedListener)

_TestHC_WindowControlShow(Scenario) {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	AssertThrows(() => Control.Start(), "Duplicate initialization is rejected.")
	State.ThrowShow := Scenario == "throw", State.ReenterShow := Scenario == "reenter"
	AssertEqual(1, Control.OnMessage(202, 303, State.Message, 101))
	if State.ThrowShow
		AssertThrows(() => Control.Open())
	else
		AssertTrue(Control.Open())
	AssertEqual(1, State.Opened)
	AssertFalse(Control.Opening)
	AssertFalse(Control.Pending)
	AssertEqual(1, State.Timers.Length, "A reentrant request cannot schedule a duplicate opener.")
	Control.Stop()
}
for _HCControlShow in ["throw", "reenter"]
	Test("Diagnostics control owns a " . _HCControlShow . " window call (diagnostics-control)",
		_TestHC_WindowControlShow.Bind(_HCControlShow))

_TestHC_WindowControlStartWithdrawal(Phase) {
	State := _TestHC_WindowControlState(), Control := State.Control
	State.WithdrawMessage := Phase == "message", State.WithdrawListen := Phase == "listen"
	AssertThrows(() => Control.Start())
	AssertFalse(Control.Active)
	AssertTrue(Control.Closed)
	AssertEqual(Phase == "message" ? 0 : 2, State.Listeners.Length,
		"A resolved message cannot register after its owner was already retired.")
	AssertFalse(Control.Listening)
	AssertEqual(0, Control.OnMessage(202, 303, State.Message, 101))
	Control.Stop()
}
for _HCControlStartPhase in ["message", "listen"]
	Test("Diagnostics control fences " . _HCControlStartPhase . " startup withdrawal (diagnostics-control)",
		_TestHC_WindowControlStartWithdrawal.Bind(_HCControlStartPhase))

_TestHC_WindowControlUnboundRequest() {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	try {
		AssertEqual(0, Control.OnMessage(0, 0, State.Message, 101),
			"A recycled HWND cannot grant an unbound request to another receiver.")
		AssertEqual(0, State.Timers.Length)
		AssertEqual(0, State.Opened)
	} finally {
		Control.Stop()
	}
}
Test("Diagnostics control refuses an unbound request (diagnostics-control-unbound)", _TestHC_WindowControlUnboundRequest)

/** Receives the actual production timer collaborator, including native cancellation. */
_TestHC_ActualControlTimer(Scenario) {
	global _HealthCheckWindowControl
	AssertFalse(IsObject(_HealthCheckWindowControl), "the actual diagnostics endpoint must have no prior owner")
	Count := 0
	Callback := (*) => Count += 1
	HealthCheck_StartWindowControl()
	Control := _HealthCheckWindowControl
	try {
		if Scenario == "repeating" {
			AssertThrows(() => Control.TimerFn.Call(Callback, 100),
				"the production diagnostics control must refuse a repeating timer")
		} else if Scenario == "cancelled" {
			PreviousCritical := A_IsCritical
			Critical("On")
			try {
				Control.TimerFn.Call(Callback, -1)
				Control.TimerFn.Call(Callback, 0)
			} finally Critical(PreviousCritical)
			Sleep(100)
			AssertEqual(0, Count, "actual native cancellation must withdraw the exact callback")
		} else {
			AssertEqual("one-shot", Scenario, "the authored native scenario must be known")
			Control.TimerFn.Call(Callback, -1)
			Started := A_TickCount
			while Count == 0 && A_TickCount - Started < 2000
				Sleep(10)
			AssertEqual(1, Count, "the actual deferred callback must run")
			Sleep(100)
			AssertEqual(1, Count, "the actual callback must remain one-shot")
		}
	} finally {
		try Control.TimerFn.Call(Callback, 0)
		finally HealthCheck_StopWindowControl()
	}
	AssertFalse(IsObject(_HealthCheckWindowControl), "the actual production listener must retire")
}
Test("Diagnostics native timer: repeating periods are refused (diagnostics-control-native-timer)", _TestHC_ActualControlTimer.Bind("repeating"))
Test("Diagnostics native timer: actual one-shot executes once (diagnostics-control-native-timer)", _TestHC_ActualControlTimer.Bind("one-shot"))
Test("Diagnostics native timer: actual cancellation retires its callback (diagnostics-control-native-timer)", _TestHC_ActualControlTimer.Bind("cancelled"))
