; tests/unit/modules/llm/servers/test_local_server_record_lifetime.ahk

; ==============================================================================
; MODULE: Local Server Record Lifetime Tests
; DESCRIPTION:
; Actual native-domain owners settle through their existing controlled request
; and timer ports. A destructor sentinel observes object lifetime after every
; fixture-held reference is cut. No network, process, sleep or GC is requested.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Lifetime Observation =======
; =======================================
; =======================================

class _LSRL_Sentinel {
	__New(Ledger, Key) {
		this.Ledger := Ledger
		this.Key := Key
	}

	__Delete() {
		this.Ledger[this.Key] += 1
	}
}

_LSRL_OrdinaryLifetime(Ledger) {
	Sentinel := _LSRL_Sentinel(Ledger, "ordinary")
}

; Dispose restores real globals and settles owned resources first. Removing
; fixture edges then prevents retained Requests, ports or result arrays from
; answering the lifetime question for a genuine retired production record.
; Only fixture-owned properties are changed, never fields of the SUT record.
_LSRL_ReleaseFixtureReferences(Fixture) {
	Names := []
	for Name, Value in Fixture.OwnProps()
		if IsObject(Value)
			Names.Push(Name)
	for Name in Names
		Fixture.%Name% := 0
}

_LSRL_Models(Ledger) {
	Fixture := _LSM_Fixture()
	try {
		AssertTrue(Fixture.Probe())
		Record := Fixture.Owner.Records["lmstudio"]
		Record["__lifetime_probe"] := _LSRL_Sentinel(Ledger, "retired")
		AssertTrue(Record["request"] == Fixture.Requests[1])
		AssertTrue(Fixture.Timers.Has(ObjPtr(Record["timer"])))
		AssertEqual(0, Ledger["retired"], "An admitted active request must retain its observation.")
		Ledger["active_retained"] := 1
		Fixture.Complete(1, 200, '{"data":[{"id":"lifetime-positive"}]}')
		AssertEqual(1, Fixture.Results.Length)
		AssertTrue(Fixture.Results[1]["ok"])
		AssertEqual("lifetime-positive", Fixture.Results[1]["models"][1])
		AssertTrue(Fixture.Requests[1].Completed)
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
		AssertEqual(0, Fixture.Timers.Count)
		Ledger["terminal_observed"] := 1
	} finally {
		try Fixture.Dispose()
		finally _LSRL_ReleaseFixtureReferences(Fixture)
	}
}

_LSRL_Queue(Ledger) {
	Fixture := _LSO_Fixture()
	try {
		; The earlier request's ticket does not reference the later queue job.
		; Keep that request logically pending so the actual new job cannot bind
		; its own ticket into a Models record and contaminate this observation.
		AssertTrue(Fixture.Probe())
		Fixture.Children[1].TerminateAllowed := false
		AssertTrue(Fixture.Native.Rescan())
		Job := Fixture.Native.Jobs["lmstudio"]
		AssertEqual("waiting", Job["phase"])
		AssertEqual(1, Fixture.Requests.Length)
		AssertTrue(Fixture.Transport.HasPending("lmstudio"))
		AssertTrue(Fixture.QueueTimers.Has(ObjPtr(Job["timer"])))
		Job["__lifetime_probe"] := _LSRL_Sentinel(Ledger, "retired")
		AssertEqual(0, Ledger["retired"], "An actual waiting queue job must retain its observation.")
		Ledger["active_retained"] := 1
		Fixture.Children[1].TerminateAllowed := true
		; Cancel can revisit an already-retired Models record in its snapshot.
		; Join through the real retry boundary rather than equating its boolean
		; with physical settlement of the exact earlier request.
		Fixture.Native.Cancel(true)
		AssertTrue(Fixture.Native.RetryPending(),
			"The genuine retry boundary must join cancelled jobs and their exact request debt.")
		Request := Fixture.Requests[1]
		AssertTrue(Request.Aborted && Request.WaitForResponse(0))
		AssertEqual(0, Request.Handle)
		AssertFalse(Request.CleanupPending)
		global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_CLEANUP_DEBTS
		AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId))
		AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId))
		AssertEqual(0, Fixture.Timers.Count)
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertEqual(0, Fixture.QueueTimers.Count)
		AssertFalse(Fixture.Transport.HasPending("lmstudio"))
		AssertTrue(Fixture.Children[1].Terminations > 1,
			"The exact earlier logical child must acknowledge a later termination attempt.")
		Ledger["terminal_observed"] := 1
	} finally {
		try Fixture.Dispose()
		finally _LSRL_ReleaseFixtureReferences(Fixture)
	}
}

_LSRL_Panel(Ledger) {
	Fixture := _LSPD_Fixture()
	try {
		Rows := Fixture.Panel.Rows()
		AssertTrue(Rows is Array && Rows.Length > 0)
		Record := Fixture.Panel.Preparation
		AssertTrue(Record is Map)
		AssertTrue(Fixture.Panel.RepairRecords.Get(ObjPtr(Record), 0) == Record)
		AssertTrue(Fixture.RepairTimers.Has(ObjPtr(Record["timer"])))
		AssertEqual(0, Fixture.RescanCalls)
		AssertEqual(0, Fixture.Requests.Length,
			"A queued view preparation must not borrow a model request's lifetime.")
		Record["__lifetime_probe"] := _LSRL_Sentinel(Ledger, "retired")
		AssertEqual(0, Ledger["retired"], "A real queued panel preparation must retain its observation.")
		Ledger["active_retained"] := 1
		AssertTrue(Fixture.Panel.Retire(false))
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.RepairTimers.Count)
		AssertFalse(Fixture.Panel.Preparation is Map)
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertEqual(0, Fixture.RescanCalls)
		Ledger["terminal_observed"] := 1
	} finally {
		try Fixture.Dispose()
		finally _LSRL_ReleaseFixtureReferences(Fixture)
	}
}

_LSRL_ExerciseCase(Mode) {
	Ledger := Map("ordinary", 0, "retired", 0, "active_retained", 0, "terminal_observed", 0)
	_LSRL_OrdinaryLifetime(Ledger)
	AssertEqual(1, Ledger["ordinary"], "The native destructor witness must release an ordinary acyclic object first.")
	switch Mode {
		case "models": _LSRL_Models(Ledger)
		case "queue": _LSRL_Queue(Ledger)
		case "panel": _LSRL_Panel(Ledger)
		default: throw ValueError("Unknown local-server lifetime mode.")
	}
	AssertEqual(1, Ledger["active_retained"])
	AssertEqual(1, Ledger["terminal_observed"])
	_TestPrint("# LIFETIME_RECEIPT mode=" . Mode . " ordinary=" . Ledger["ordinary"]
		. " active_retained=" . Ledger["active_retained"] . " terminal=" . Ledger["terminal_observed"]
		. " retired_deleted=" . Ledger["retired"] . " fixture_refs_released=1")
	AssertEqual(1, Ledger["retired"],
		"A genuinely retired local-server record must release its sentinel exactly once after all external fixture references leave scope.")
}

; The refused logical child emits a genuine warning. Park logger and health
; state rather than letting that observation contaminate another native test.
_LSRL_Case(Mode) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	try {
		AssertFalse(SavedLogger.FlushActive, "A foreign logger flush cannot be detached by a lifetime test.")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Critical("Off")
		_LSRL_ExerciseCase(Mode)
	} finally {
		Critical("On")
		try {
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			for Name, Saved in SavedOptional
				%Name% := Saved.Present ? Saved.Value : unset
		} finally Critical(PreviousCritical)
	}
}

Test("Local server lifetime: completed models record releases its sentinel (local-server-record-lifetime)", _LSRL_Case.Bind("models"))
Test("Local server lifetime: cancelled waiting queue releases its sentinel (local-server-record-lifetime)", _LSRL_Case.Bind("queue"))
Test("Local server lifetime: retired panel preparation releases its sentinel (local-server-record-lifetime)", _LSRL_Case.Bind("panel"))
