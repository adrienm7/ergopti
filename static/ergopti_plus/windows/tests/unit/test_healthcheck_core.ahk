; tests/unit/test_healthcheck_core.ahk

; ==============================================================================
; MODULE: HealthCheck Core Behavioral Tests
; DESCRIPTION:
; Exercises the counter functions and HealthCheck_Run() from
; ui/healthcheck/core.ahk with real assertions. Replaces the 9 no-op
; AssertTrue(true) placeholder tests that previously lived in test_logger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0


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
