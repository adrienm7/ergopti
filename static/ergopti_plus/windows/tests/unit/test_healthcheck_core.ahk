; tests/unit/test_healthcheck_core.ahk

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
		AssertEqual("pending", Result["probes"][Id]["state"], Id . " must start pending")
}

Test("HealthCheck: Run returns a version 2 snapshot with its probes pending",
	_TestHC_RunIsVersion2)


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
		AssertEqual(520, Height)
	} finally {
		Window.Destroy()
	}
}
Test("HealthCheck: real browser failure retains schema-ordered native sections and separate logs",
	_TestHC_StructuredNativeFallback)

/** Replay the actual poll with a deterministic tick and a recording request. */
_TestHC_ProbeRollover(Started, Elapsed, Completed := false, Cancellation := "", AbortAllowed := true) {
	Now := Mod(Started + Elapsed, 0x100000000)
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
		AssertEqual(Elapsed, Published[1]["ms"], "published duration is exact across unsigned wrap")
	} else if !InitiallyCancelled && !Overdue {
		ProbeRun.Cancelled := true
		_HC_ProbePoll(ProbeRun, "clock-regression", Request, Interpret, Started, 2000, Now, Arm)
		AssertEqual(0, Published.Length, "later cancellation cannot publish the pending result")
		AssertEqual(1, Waits.Length, "the cancelled replay cannot touch its transport")
		AssertEqual(1, Arms.Length, "the cancelled replay cannot schedule more work")
	}
}

/** Every finish caller uses the same unsigned duration without changing its result. */
_TestHC_ProbeFinishRollover(Started) {
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
	_HC_ProbeFinish(ProbeRun, "clock-finish", Started, Result, Sections, Mod(Started + 80, 0x100000000))
	AssertEqual(1, Published.Length)
	AssertEqual(80, Result["ms"], "the shared finish owner counts elapsed time across wrap")
	AssertEqual("error", Result["state"], "an elapsed-time fix cannot convert failure into success")
	AssertEqual("literal-error", Result["detail"])
}

for _HCClockOrigin in [100, 0xFFFFFFF0] {
	_HCClockLabel := _HCClockOrigin == 100 ? "ordinary" : "wrapped"
	for _HCClockElapsed in [2999, 3000, 3001]
		Test("HealthCheck probe-clock-wrap: " . _HCClockLabel . " budget " . _HCClockElapsed,
			_TestHC_ProbeRollover.Bind(_HCClockOrigin, _HCClockElapsed))
	Test("HealthCheck probe-clock-wrap: " . _HCClockLabel . " observed completion wins",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, true))
	Test("HealthCheck probe-clock-wrap: " . _HCClockLabel . " cancelled run drops completion",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, true, "before"))
	Test("HealthCheck probe-clock-wrap: " . _HCClockLabel . " abort refusal remains timeout",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, false, "", false))
	Test("HealthCheck probe-clock-wrap: " . _HCClockLabel . " cancellation during abort drops result",
		_TestHC_ProbeRollover.Bind(_HCClockOrigin, 4000, false, "abort"))
	Test("HealthCheck probe-clock-wrap: " . _HCClockLabel . " shared finish retains failure",
		_TestHC_ProbeFinishRollover.Bind(_HCClockOrigin))
}
