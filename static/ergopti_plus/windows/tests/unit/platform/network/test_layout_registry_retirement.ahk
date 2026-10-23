; tests/unit/platform/network/test_layout_registry_retirement.ahk

; ==============================================================================
; MODULE: Layout Registry Terminal Cleanup Controls
; DESCRIPTION:
; Uses the real managed facade, registry timeout and catalogue consumer with
; a controlled process Job. Late response bytes and all partial/cache cleanup
; are native files. A logical refusal/ACK is not a native OS process claim.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRR_Factory(State) {
	Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(State)))
	State["request"] := Request
	return Request
}

_LRR_Schedule(Queue, Callback, Delay) {
	global LAYOUT_REGISTRY_POLL_MS
	AssertTrue(Delay is Integer && Delay >= 0, "the normal scheduling boundary receives a delay without imposing elapsed timing")
	Queue.Push(Callback)
}

_LRR_Done(Results, RaiseFailure, Outcome) {
	Results.Push(Outcome)
	if RaiseFailure
		throw Error("Expected layout registry subscriber failure.")
}

_LRR_Poll(Queue) {
	AssertTrue(Queue.Length > 0, "the actual registry poll must be retained")
	Callback := Queue.RemoveAt(1)
	Callback.Call()
	return Callback
}

_LRR_Drain(Queue) {
	Loop 64 {
		if Queue.Length == 0
			return
		_LRR_Poll(Queue)
	}
	throw Error("The exact terminal registry cleanup did not settle.")
}

_LRR_Terminal(State, Success) {
	Job := State["job"]
	State["retire"] := true
	Ack := Job.terminate()
	AssertTrue(Ack is Integer && Ack == 1, "only the exact controlled Job ACK admits its terminal callback")
	State["callback"].Call(Success ? 0 : -1,
		'{"schema_version":1,"ok":' . (Success ? "true" : "false")
			. ',"status":' . (Success ? 200 : 0) . ',"child_quiesced":true,"receipt":{}}', "")
}

_LRR_Exercise(Mode, Dir, State, Queue, Results) {
	global _HTTP_CURL_ABORT_DEBTS, LAYOUT_REGISTRY_POLL_MS, LAYOUT_REGISTRY_POLL_GRACE
	State["retire"] := Mode != "abort-refused"
	Transport := Map("managed", true, "request", _LRR_Factory.Bind(State),
		"schedule", _LRR_Schedule.Bind(Queue))
	LayoutCatalogue_Refresh(Dir, _LRR_Done.Bind(Results, Mode == "callback-throw"), Transport, 0, false)
	Request := State["request"]
	AssertEqual(1, State["spawns"], "the public refresh must dispatch the real managed facade")
	AssertEqual(1, State["starts"])
	AssertTrue(Request.ManagedTransport && Request.SendStarted && !Request.Completed)
	AssertTrue(IsObject(Request.ManagedAdmissionFn))
	SetTimer(Request.ManagedAdmissionFn, 0)
	_ManagedCurlControlAck(State)
	Request._PollManagedAdmission()
	AssertTrue(Request.ManagedPayloadPublished, "the real private admission must publish the exact request input")
	AssertTrue(Request.Handle == State["job"], "the facade retains that exact logical Job")
	SplitPath(Request.OutputPath,, &OutputDirectory)
	AssertEqual(0, StrCompare(FSResolveDirectoryPath(OutputDirectory), FSResolveDirectoryPath(Dir), false),
		"the real consumer selected its output in the exclusive directory, including canonical aliases")
	Golden := '{"layouts":[],"witness":"owned-terminal"}'
	if Mode == "success" || Mode == "callback-throw" {
		_LCR_Write(Request.OutputPath, Golden)
		_LCR_Write(Request.HeaderPath, 'HTTP/1.1 200 OK`r`nETag: "owned"`r`n`r`n')
		_LRR_Terminal(State, true)
		AssertTrue(Request.Completed && !IsObject(Request.Handle))
		Failure := 0, Delivery := Queue[1]
		try _LRR_Poll(Queue)
		catch as Err
			Failure := Err
		if Mode == "callback-throw" {
			AssertTrue(IsObject(Failure))
			AssertContains(Failure.Message, "Expected layout registry subscriber failure")
		} else
			AssertFalse(IsObject(Failure))
		; Re-deliver the exact old bound poll, not a copied settle function.
		Delivery.Call()
		_LRR_Drain(Queue)
		AssertEqual(1, Results.Length, "the actual registry can settle the public refresh only once")
		AssertEqual(0, Results[1]["error"])
		AssertEqual(Golden, FileRead(Dir . "index.json", "UTF-8-RAW"))
		AssertEqual('"owned"', FileRead(Dir . "index.etag", "UTF-8-RAW"))
	} else {
		_LCR_Write(Request.OutputPath, "partial-before-timeout")
		Steps := Ceil(Request.DeadlineTimeout / LAYOUT_REGISTRY_POLL_MS) + LAYOUT_REGISTRY_POLL_GRACE + 4
		Loop Steps {
			if State["terminates"].Length > 0
				break
			_LRR_Poll(Queue)
		}
		AssertTrue(State["terminates"].Length > 0, "the real registry timeout must ask its request to retire")
		AssertTrue(Request.Aborted, "the real Curl Abort must revoke the actual facade")
		if Mode == "abort-refused" {
			AssertFalse(Request.Completed, "a refused controlled Job must remain physically unknown")
			AssertTrue(Request.Handle == State["job"])
			AssertTrue(_HTTP_CURL_ABORT_DEBTS.Get(Request.CleanupDebtId, 0) == Request,
				"the facade must retain only its own exact abort debt")
			; The native worker writes this caller-owned path directly. Its Job
			; has not acknowledged retirement, so this controlled late write is
			; before the explicit terminal ACK, never after a successful Abort.
			_LCR_Write(Request.OutputPath, Golden)
			_LRR_Terminal(State, false)
		} else {
			AssertEqual("abort-acknowledged", Mode)
			AssertTrue(Request.Completed && !IsObject(Request.Handle), "an acknowledged abort may finish immediately")
		}
		AssertTrue(Request.Completed && !IsObject(Request.Handle))
		AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId))
		_LRR_Drain(Queue)
		AssertEqual(1, Results.Length, "physical settlement must eventually complete the public refresh once")
		AssertTrue(Results[1]["error"] is Map)
		AssertFalse(FileExist(Dir . "index.json"), "a failed transfer cannot publish an index")
		FileAppend("RECEIPT layout-registry-retirement mode=" . Mode . " callbacks=" . Results.Length
			. " completed=" . Request.Completed . " abort_debt=" . _HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId)
			. " terminates=" . State["terminates"].Length . " partial_exists=" . (FileExist(Request.OutputPath) ? 1 : 0) . "`n", "*")
	}
	AssertFalse(FileExist(Request.OutputPath), "a failed or consumed registry response must not leave an orphan partial after its exact terminal ACK")
}

_LRR_Case(Mode) {
	global _LayoutRegistryDefaults, _LayoutRegistryGithub, _LayoutCatalogueLast
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	global _HTTP_CURL_ABORT_TIMER, _HTTP_CURL_CLEANUP_TIMER, _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_CLEANUP_DEBTS
	PreviousCritical := Critical("On")
	SavedDefaults := _LayoutRegistryDefaults, SavedGithub := _LayoutRegistryGithub, SavedLast := _LayoutCatalogueLast
	SavedAbortTimer := _HTTP_CURL_ABORT_TIMER, SavedCleanupTimer := _HTTP_CURL_CLEANUP_TIMER
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Dir := "", State := _ManagedCurlControlState(), Queue := [], Results := [], Primary := 0, CleanupError := 0
	try {
		AssertFalse(SavedLogger.FlushActive, "no foreign logger flush may be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Dir := _LCR_Directory()
		_LRR_Exercise(Mode, Dir, State, Queue, Results)
	} catch as Err {
		Primary := Err
	} finally {
		try {
			State["retire"] := true
			if State.Has("request") {
				Request := State["request"]
				Ack := Request.Abort()
				AssertTrue(Ack is Integer && Ack == 1, "the exact controlled request must acknowledge cleanup")
				_LRR_Drain(Queue)
				AssertFalse(IsObject(Request.Handle) || IsObject(Request.ManagedCapture) || Request.CleanupPending)
				AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId))
				AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId))
				for Path in [Request.ConfigPath, Request.BodyPath, Request.HeaderPath]
					AssertFalse(FileExist(Path), "every internal request artifact must retire")
			}
			if State.Has("directory")
				AssertFalse(DirExist(State["directory"]), "the exact private capture directory must retire")
		} catch as Err {
			CleanupError := Err
		} finally {
			try {
				Queue.Length := 0
				_ManagedCurlControlRelease(State)
				if Dir != "" && !IsObject(CleanupError)
					DirDelete(Dir, true)
			} catch as Err {
				if !IsObject(CleanupError)
					CleanupError := Err
			} finally {
				if !IsObject(SavedAbortTimer) && IsObject(_HTTP_CURL_ABORT_TIMER)
					SetTimer(_HTTP_CURL_ABORT_TIMER, 0)
				if !IsObject(SavedCleanupTimer) && IsObject(_HTTP_CURL_CLEANUP_TIMER)
					SetTimer(_HTTP_CURL_CLEANUP_TIMER, 0)
				_HTTP_CURL_ABORT_TIMER := SavedAbortTimer, _HTTP_CURL_CLEANUP_TIMER := SavedCleanupTimer
				_LayoutRegistryDefaults := SavedDefaults, _LayoutRegistryGithub := SavedGithub, _LayoutCatalogueLast := SavedLast
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

for _LRR_Mode in ["success", "abort-acknowledged", "abort-refused", "callback-throw"]
	Test("layout-registry-retirement: terminal cleanup retains exact ownership across " . _LRR_Mode, _LRR_Case.Bind(_LRR_Mode))
