; tests/unit/modules/llm/api/test_llm_curl_process_exit_ack.ahk

; ==============================================================================
; MODULE: Curl Exact Process Exit Acknowledgement Tests
; DESCRIPTION:
; Termination acceptance is not process exit. Existing process ports model those
; separate native receipts while the real release and retry owners execute. No
; synthetic process capability is ever passed to an OS operation.
; ==============================================================================

#Requires AutoHotkey v2.0

_OCEA_Handle(State, Handle) {
	if Handle == State["handle"]
		return true
	State["failure"] := Error("A process port received a foreign exact handle.")
	return false
}

_OCEA_Open(State, Pid) {
	if Pid != State["pid"] {
		State["failure"] := Error("Adoption must retain the requested process identity.")
		return 0
	}
	State["opens"] += 1
	return State["handle"]
}

_OCEA_Terminate(State, Handle) {
	if !_OCEA_Handle(State, Handle)
		return 0
	State["terminates"] += 1
	return State["terminate_result"]
}

_OCEA_Wait(State, Handle) {
	if !_OCEA_Handle(State, Handle)
		return 0xFFFFFFFF
	State["waits"] += 1
	return State["wait_result"]
}

_OCEA_Close(State, Handle) {
	if !_OCEA_Handle(State, Handle)
		return 0
	State["closes"] += 1
	State["closed_before_exit"] := State["wait_result"] != 0
	return 1
}

_OCEA_Observe(Mode, Owner, State, Released) {
	FileAppend("RECEIPT curl-process-exit-ack mode=" . Mode . " result=" . Released
		. " released=" . Owner["released"] . " handle=" . Owner["handle"]
		. " debt=" . Owner.Get("cleanup_debt_id", 0) . " opens=" . State["opens"]
		. " terminates=" . State["terminates"] . " waits=" . State["waits"]
		. " closes=" . State["closes"] . " wait_result=" . State["wait_result"]
		. " closed_before_exit=" . State["closed_before_exit"] . "`n", "*")
}

_OCEA_Exercise(Mode, Owner, Port, State) {
	global _LLM_CurlCleanupDebt
	Released := _LLM_CurlReleaseProcess(Owner, true, Port)
	if IsObject(State["failure"])
		throw State["failure"]
	AssertEqual(1, State["opens"], "the genuine adoption must retain exactly one capability")
	if Mode != "already-exited"
		AssertTrue(State["terminates"] > 0, "a pending process release must request termination")
	_OCEA_Observe(Mode, Owner, State, Released)
	if Mode == "already-exited" {
		AssertTrue(Released is Integer && Released == 1)
		AssertTrue(State["waits"] > 0, "failed termination must still recognize an already-exited process")
	} else {
		AssertFalse(Released, "termination acceptance cannot retire an exact process before its exit ACK")
		AssertFalse(Owner["released"])
		AssertEqual(State["handle"], Owner["handle"])
		AssertEqual(0, State["closes"], "the last exact process capability must remain open until exit")
		AssertFalse(_LLM_CurlProcessExited(Owner, Port), "a pending exit cannot become a terminal process receipt")
		DebtId := Owner.Get("cleanup_debt_id", 0)
		AssertTrue(DebtId > 0 && _LLM_CurlCleanupDebt.Has(DebtId))
		Debt := _LLM_CurlCleanupDebt[DebtId]
		AssertEqual("process", Debt["kind"])
		AssertTrue(Debt["owner"] == Owner && Debt["port"] == Port && Debt["terminate"],
			"retry must retain the exact owner, original ports and termination intent")
		State["wait_result"] := 0
		AssertTrue(LLM_CurlRetryCleanupDebt(), "the real retry must settle after WAIT_OBJECT_0")
		AssertFalse(_LLM_CurlCleanupDebt.Has(DebtId), "only the acknowledged exact debt may retire")
	}
	if IsObject(State["failure"])
		throw State["failure"]
	AssertTrue(Owner["released"])
	AssertEqual(0, Owner["handle"])
	AssertEqual(0, Owner.Get("cleanup_debt_id", 0))
	AssertEqual(1, State["closes"], "confirmed retirement closes the exact capability once")
	AssertFalse(State["closed_before_exit"])
	AssertTrue(_LLM_CurlProcessExited(Owner, Port))
	AssertTrue(_LLM_CurlReleaseProcess(Owner, true, Port))
	AssertEqual(1, State["closes"], "repeat release cannot close an already-retired capability")
	_OCEA_Observe(Mode . "-complete", Owner, State, true)
}

_OCEA_Case(Mode) {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "an unresolved old process port owner cannot be replaced")
	PreviousCritical := Critical("On")
	SavedDebt := _LLM_CurlCleanupDebt, SavedTimer := _LLM_CurlCleanupRetryTimer
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	State := Map("pid", 53123, "handle", 953123, "opens", 0, "terminates", 0, "waits", 0,
		"closes", 0, "closed_before_exit", false, "failure", 0,
		"terminate_result", Mode == "termination-pending" ? 1 : 0,
		"wait_result", Mode == "already-exited" ? 0 : 258)
	Port := Map("open_process", _OCEA_Open.Bind(State), "terminate_process", _OCEA_Terminate.Bind(State),
		"wait_process", _OCEA_Wait.Bind(State), "close_process", _OCEA_Close.Bind(State))
	Owner := 0, Primary := 0, CleanupError := 0
	try {
		AssertFalse(SavedLogger.FlushActive, "a foreign logger flush cannot be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		_LLM_CurlCleanupDebt := Map()
		; The real retry is called explicitly below. This parks only its OS timer
		; boundary while outer Critical prevents foreign singleton callbacks.
		_LLM_CurlCleanupRetryTimer := (*) => 0
		Owner := _LLM_CurlAdoptProcess(State["pid"], Port)
		_OCEA_Exercise(Mode, Owner, Port, State)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			State["terminate_result"] := 0, State["wait_result"] := 0
			if IsObject(Owner) {
				Receipt := _LLM_CurlReleaseProcess(Owner, true, Port)
				AssertTrue(Receipt is Integer && Receipt == 1, "cleanup requires the exact logical exit acknowledgement")
				AssertTrue(Owner["released"] && Owner["handle"] == 0 && Owner.Get("cleanup_debt_id", 0) == 0)
				for DebtId, Debt in _LLM_CurlCleanupDebt
					AssertFalse(Debt.Get("owner", 0) == Owner, "no exact fixture process debt may be silently detached")
			}
			if IsObject(State["failure"])
				throw State["failure"]
		} catch as Failure {
			CleanupError := Failure
			RetirementDebt := {Owner: Owner, Port: Port, Debt: _LLM_CurlCleanupDebt}
		} finally {
			try {
				if _LLM_CurlCleanupRetryTimer != SavedTimer && HasMethod(_LLM_CurlCleanupRetryTimer, "Call")
					SetTimer(_LLM_CurlCleanupRetryTimer, 0)
			} finally {
				_LLM_CurlCleanupDebt := SavedDebt, _LLM_CurlCleanupRetryTimer := SavedTimer
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Value in SavedExtra
					%Name% := Value
				for Name, Saved in SavedOptional
					%Name% := Saved.Present ? Saved.Value : unset
				Critical(PreviousCritical)
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

for _OCEA_Mode in ["termination-pending", "already-exited", "termination-refused"]
	Test("Ollama curl process exit: " . _OCEA_Mode . " retains its exact capability until exit (ollama-process-exit-ack)",
		_OCEA_Case.Bind(_OCEA_Mode))
