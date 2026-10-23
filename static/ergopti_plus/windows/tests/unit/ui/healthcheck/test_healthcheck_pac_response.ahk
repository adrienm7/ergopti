; tests/unit/ui/healthcheck/test_healthcheck_pac_response.ahk

; ==============================================================================
; MODULE: Diagnostics PAC Response Contract Tests
; DESCRIPTION:
; A private native HTTP peer first calls the actual managed PAC source fetcher.
; The real diagnostics transport then receives the same bytes through curl and
; its actual poll/interpreter. Only the existing settings reader and timer arm
; ports are supplied; no decoder, Request, native process or result is replaced.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCPR_Complete(State, Code, Output, ErrorText) {
	State.Completed += 1
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_HCPR_Publish(State, Epoch, Id, Result, Sections) {
	State.Answers.Push({Epoch: Epoch, Id: Id, Result: Result, Sections: Sections})
}

_HCPR_Settings() => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")

; Preserve the real poll and its native timer boundary while retaining each exact
; callback for cleanup. Re-arms use the existing ArmPollFn argument, not a new seam.
_HCPR_Arm(State, Run, Id, Request, Interpret, Started, TimeoutMs) {
	global HC_PROBE_POLL_MS
	Callback := _HCPR_Poll.Bind(State, Run, Id, Request, Interpret, Started, TimeoutMs)
	State.Timers.Push(Callback)
	SetTimer(Callback, -HC_PROBE_POLL_MS)
}

_HCPR_Poll(State, Run, Id, Request, Interpret, Started, TimeoutMs) {
	State.PollCalls += 1, State.InFlight += 1
	try _HC_ProbePoll(Run, Id, Request, Interpret, Started, TimeoutMs, , State.Arm)
	catch as Failure {
		if !IsObject(State.Failure)
			State.Failure := Failure
	} finally State.InFlight -= 1
}

_HCPR_Case(Mode) {
	global _DriverDir, _VendorDir, _SharedDir, _HC_ProbeRun
	global HC_PROBE_USER_AGENT
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED
	global _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_SUB_PATHS, _LOGGER_SUB_PENDING, LOGGER_SUB_FILES
	global _ED_Busy, _ED_PendingRecord, _ED_Policy
	global _HealthCheckWarnCount, _HealthCheckErrCount, _HealthCheckLastError
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired native PAC fixture cannot be replaced")
	AssertFalse(IsObject(_HC_ProbeRun), "A foreign diagnostics run cannot be adopted")
	AssertFalse(_LOGGER_FLUSH_ACTIVE || _ED_Busy || IsObject(_ED_PendingRecord),
		"Foreign diagnostic UI or log work must remain untouched")
	AssertFalse(A_IsSuspended, "The real managed transport requires an active driver")
	Directory := A_Temp . "\ergopti_pac_probe_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := {Completed: 0, Code: -1, Output: "", ErrorText: "", Answers: [], Timers: [],
		Arm: 0, PollCalls: 0, InFlight: 0, Failure: 0}
	State.Arm := _HCPR_Arm.Bind(State)
	Run := {Epoch: 7194, Cancelled: false, Requests: [], Publish: _HCPR_Publish.Bind(State)}
	Handle := 0, Primary := 0, PeerRetired := false, RequestsRetired := true
	LoggerState := _TLOG_CaptureLoggerState()
	Extra := {Sink: _LOGGER_TEST_SINK, Repeat: _LOGGER_REPEAT_ENABLED, Clock: _LOGGER_CLOCK_FN,
		Stamp: _LOGGER_STAMP_FN, Policy: _ED_Policy, Warn: _HealthCheckWarnCount,
		Errors: _HealthCheckErrCount, LastError: _HealthCheckLastError}
	SavedRun := _HC_ProbeRun
	PreviousCritical := Critical("Off")
	try {
		_ResetLogger()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		_LOGGER_SUB_PATHS := Map(), _LOGGER_SUB_PENDING := Map(), LOGGER_SUB_FILES := []
		_ED_Policy := 0
		_HC_ProbeRun := Run
		Handle := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\healthcheck_pac_response_peer.ps1", "-Mode", Mode,
				"-Directory", Directory, "-WorkerPath", _VendorDir . "\ergopti_network_pac.ps1",
				"-PolicyPath", _SharedDir . "\modules\network\proxy_policy.json"], _HCPR_Complete.Bind(State))
		AssertTrue(Handle.start(), "The private PAC source/HTTP owner must start")
		Started := A_TickCount
		while !FSStrictExists(Directory . "\ready.json") && State.Completed == 0 && TickElapsed(Started) < 20000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertTrue(FSStrictExists(Directory . "\ready.json"), "The actual PAC fetcher must finish its source contract before diagnostics")
		Ready := JsonParse(FSReadUtf8Exact(Directory . "\ready.json"))
		Raw := FSReadBytesStrict(Directory . "\response.bin")
		AssertEqual(Mode, Ready["mode"])
		AssertEqual(Raw.Size, Ready["raw_bytes"])
		AssertEqual(CryptoSha256Bytes(Raw), Ready["raw_sha256"], "The independent source owner and diagnostic peer share exact raw bytes")
		AssertEqual(1, Ready["source_requests"], "The actual PAC fetcher must perform its native HTTP acquisition")
		ExpectedState := Mode == "ascii" || Mode == "replacement" ? "ok" : "error"
		AssertEqual(ExpectedState == "ok", Ready["source_allowed"], "The actual worker is the independent source-acceptance oracle")
		if Mode == "overbytes" {
			AssertTrue(Raw.Size > 1048576 && Raw.Size < 8 * 1024 * 1024)
			AssertEqual("byte_limit", Ready["source_error"])
		} else if Mode == "malformed"
			AssertEqual("invalid_utf8", Ready["source_error"])
		else
			AssertEqual(Raw.Size, Ready["normalized_bytes"])
		AssertTrue(Ready["port"] is Integer && Ready["port"] > 0 && Ready["port"] <= 65535)
		Url := "http://127.0.0.1:" . Ready["port"] . "/proxy.pac"
		; Loopback is a canonical direct route. This exercises the actual managed
		; request without changing system proxy settings or claiming WPAD coverage.
		Port := Map("managed_settings", _HCPR_Settings, "arm_poll", State.Arm)
		_HC_ProbeSend(Run, "proxy_pac", Url, Map("User-Agent", HC_PROBE_USER_AGENT),
			20000, _HC_PacAnswer, A_TickCount, Port)
		Started := A_TickCount
		while State.Answers.Length == 0 && !IsObject(State.Failure) && TickElapsed(Started) < 22000 {
			_SR_TreePoll()
			Sleep(10)
		}
		if IsObject(State.Failure)
			throw State.Failure
		AssertEqual(1, Run.Requests.Length)
		Request := Run.Requests[1]
		AssertTrue(Request is CurlAsyncRequest && Request.ManagedTransport, "The real managed downloader must produce the diagnostic response")
		AssertEqual(200, Request.Status, "A routing or native prerequisite failure cannot substitute for PAC interpretation")
		AssertEqual(Mode != "malformed", Request.ResponseEncodingValid, "The actual transport retains strict raw UTF-8 validity")
		if Ready["utf8_valid"]
			AssertEqual(Ready["raw_sha256"], CryptoSha256(Request.ResponseText),
				"The actual diagnostic transport must preserve the exact valid UTF-8 source image")
		AssertTrue(State.PollCalls > 0 && State.InFlight == 0, "An observed native timer must deliver the genuine poll")
		AssertEqual(1, State.Answers.Length)
		AssertEqual(Run.Epoch, State.Answers[1].Epoch)
		AssertEqual("proxy_pac", State.Answers[1].Id)
		if Mode == "replacement"
			AssertTrue(InStr(Request.ResponseText, Chr(0xFFFD)) > 0, "The valid EF BF BD scalar must reach the actual interpreter unchanged")
		if Mode == "overbytes"
			AssertTrue(StrLen(Request.ResponseText) < 1048576, "The raw byte limit must be independent of the smaller UTF-16 character count")
		_TestPrint("# PAC_RESPONSE mode=" . Mode . " raw_bytes=" . Raw.Size
			. " utf16_units=" . StrLen(Request.ResponseText) . " source_error=" . Ready["source_error"]
			. " utf8_valid=" . Request.ResponseEncodingValid . " source_allowed=" . Ready["source_allowed"]
			. " status=" . Request.Status . " diagnostic_state=" . State.Answers[1].Result["state"]
			. " polls=" . State.PollCalls . " bytes_sha256=" . Ready["raw_sha256"])
		AssertEqual(ExpectedState, State.Answers[1].Result["state"],
			"PAC diagnostics must agree with the actual bounded strict source fetcher on the same bytes")
		if ExpectedState == "ok"
			AssertTrue(State.Answers[1].Sections["network"].Has("proxy_pac"))
	} catch as Failure {
		Primary := Failure
	} finally {
		Run.Cancelled := true
		for Callback in State.Timers {
			try SetTimer(Callback, 0)
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		for Request in Run.Requests {
			try {
				RequestReceipt := Request.Abort()
				if !(RequestReceipt is Integer) || RequestReceipt != 1 || Request.CleanupPending
					throw Error("The exact diagnostic request retained native cleanup debt.")
			} catch as Failure {
				RequestsRetired := false
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			if !FSWriteCreateDurable(Directory . "\stop", "stop")
				throw Error("The exact private PAC peer stop could not be published.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try {
			Started := A_TickCount
			while State.Completed == 0 && TickElapsed(Started) < 5000 {
				_SR_TreePoll()
				Sleep(10)
			}
			if IsObject(Handle) && State.Completed == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			PeerRetired := Receipt is Integer && Receipt == 1
			if !PeerRetired
				throw Error("The exact private PAC peer tree did not acknowledge retirement.")
			AssertEqual(1, State.Completed)
			AssertEqual(0, State.Code, State.Output)
			AssertEqual("", State.ErrorText, State.Output)
			AssertContains(State.Output, "PAC_PROBE_PEER mode=" . Mode)
			AssertContains(State.Output, "retired=true")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		if RequestsRetired && PeerRetired && State.InFlight == 0 {
			try DirDelete(Directory, true)
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		} else
			RetirementDebt := {Handle: Handle, Run: Run, Directory: Directory, State: State}
		_HC_ProbeRun := SavedRun
		_TLOG_RestoreLoggerState(LoggerState)
		_LOGGER_TEST_SINK := Extra.Sink, _LOGGER_REPEAT_ENABLED := Extra.Repeat
		_LOGGER_CLOCK_FN := Extra.Clock, _LOGGER_STAMP_FN := Extra.Stamp
		_ED_Policy := Extra.Policy
		_HealthCheckWarnCount := Extra.Warn, _HealthCheckErrCount := Extra.Errors, _HealthCheckLastError := Extra.LastError
		if !IsObject(RetirementDebt) {
			Run.Publish := 0, Run.Requests := []
			State.Arm := 0, State.Timers := []
		}
		Critical(PreviousCritical)
	}
	ExportFailure := 0
	try _TestPrint("# PAC_RESPONSE_RETIRE mode=" . Mode . " peer_completed=" . State.Completed
		. " peer_exit=" . State.Code . " peer_retired=" . PeerRetired . " requests_retired=" . RequestsRetired)
	catch as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("PAC diagnostics: legitimate UTF-8 replacement scalar remains usable (diagnostics-pac-response)", _HCPR_Case.Bind("replacement"))
Test("PAC diagnostics: oversized UTF-8 body respects actual worker byte limit (diagnostics-pac-response)", _HCPR_Case.Bind("overbytes"))
Test("PAC diagnostics: current ASCII source remains usable (diagnostics-pac-response)", _HCPR_Case.Bind("ascii"))
Test("PAC diagnostics: malformed UTF-8 remains refused (diagnostics-pac-response)", _HCPR_Case.Bind("malformed"))
