; tests/unit/ui/healthcheck/test_healthcheck_pac_boundaries.ahk

; ==============================================================================
; MODULE: Diagnostics PAC Source and Normalized Byte Bound Tests
; DESCRIPTION:
; The genuine Fetch admits an exact UTF8 source and independently refuses an
; oversized UTF16 source or its UTF8 normalization. The real diagnostics request
; receives those same private HTTP bytes and must agree, with its original
; transport, timers, RAW observer and exact retirement helpers unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCPB_Case(Mode) {
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
	Directory := A_Temp . "\ergopti_pac_boundaries_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := {Completed: 0, Code: -1, Output: "", ErrorText: "", Answers: [], Timers: [],
		Arm: 0, PollCalls: 0, InFlight: 0, Failure: 0, RawReads: 0, RawCount: -1, RawSha: ""}
	State.Arm := _HCPR_Arm.Bind(State)
	Run := {Epoch: 7196, Cancelled: false, Requests: [], Publish: _HCPR_Publish.Bind(State)}
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
				_DriverDir . "\tests\fixtures\healthcheck_pac_boundaries_peer.ps1", "-Mode", Mode,
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
		Valid := Mode == "utf8exact"
		ExpectedState := Valid ? "ok" : "error"
		Vectors := Map(
			"utf8exact", {RawBytes: 1048576, RawSha: "d5d7052b838c553eaa0ef6c900451bf3b7c5644b17597db8a7d6bc7755f5b2fe",
				NormalizedBytes: 1048576, NormalizedSha: "d5d7052b838c553eaa0ef6c900451bf3b7c5644b17597db8a7d6bc7755f5b2fe"},
			"utf16rawover", {RawBytes: 1048578, RawSha: "718bad81b4d4441425cb9140b5b27dcc50d9344ab19317735c9074af6eb8d7e1",
				NormalizedBytes: 524288, NormalizedSha: "308ece349fe17e5fd6245dbd2ddb809ea97a04a147856e392268a8c97fbd1ea8"},
			"utf16normalizedover", {RawBytes: 700112, RawSha: "85f220b45ab2e4401ae2f159bbedc3fea84d1910b8227e629d91822624bdbee1",
				NormalizedBytes: 1050055, NormalizedSha: "3ab82b4c03d0cddf896f658389f5cb7ef45f4f8506566e4dab3aa911b22d0777"}
		)
		Vector := Vectors[Mode]
		AssertEqual(Vector.RawBytes, Raw.Size, "The fixture must expose the exact independent raw boundary vector")
		AssertEqual(Vector.RawSha, Ready["raw_sha256"])
		AssertEqual(Vector.NormalizedBytes, Ready["expected_normalized_bytes"])
		AssertEqual(Vector.NormalizedSha, Ready["expected_normalized_sha256"])
		AssertEqual(Valid, Ready["source_allowed"], "The genuine Fetch owns source acceptance")
		AssertEqual(Valid, Ready["utf8_valid"], "Only the exact UTF8 vector is strict UTF8 source data")
		if Valid {
			AssertEqual(1048576, Raw.Size, "The inclusive boundary is an affirmative control, not a refusal")
			AssertEqual(1048576, Ready["normalized_bytes"])
			AssertEqual(Vector.NormalizedSha, Ready["normalized_sha256"])
			AssertEqual("none", Ready["source_error"])
		} else {
			AssertEqual(0xFF, NumGet(Raw, 0, "UChar"))
			AssertEqual(0xFE, NumGet(Raw, 1, "UChar"))
			AssertEqual(0, Mod(Raw.Size - 2, 2), "Refused UTF16 sources remain structurally complete")
			AssertEqual("byte_limit", Ready["source_error"])
			AssertEqual(0, Ready["normalized_bytes"], "The real Fetch must not return an oversized admitted image")
			if Mode == "utf16rawover" {
				AssertTrue(Raw.Size > 1048576 && Vector.NormalizedBytes < 1048576)
			} else
				AssertTrue(Raw.Size < 1048576 && Vector.NormalizedBytes > 1048576)
		}
		AssertTrue(Ready["port"] is Integer && Ready["port"] > 0 && Ready["port"] <= 65535)
		Url := "http://127.0.0.1:" . Ready["port"] . "/proxy.pac"
		; Loopback is a canonical direct route. This exercises the actual managed
		; request without changing system proxy settings or claiming WPAD coverage.
		Port := Map("managed_settings", _HCPR_Settings, "arm_poll", State.Arm,
			"create_http", _HCPE_CreateRequest.Bind(State))
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
		AssertEqual(Valid, Request.ResponseEncodingValid, "The generic flag must retain its original strict raw UTF8 meaning")
		AssertEqual(1, State.RawReads, "The real transport must expose its exact completed RAW body once before cleanup")
		AssertEqual(Raw.Size, State.RawCount)
		AssertEqual(Ready["raw_sha256"], State.RawSha, "Actual Curl and source Fetch must receive identical raw source bytes")
		AssertTrue(State.PollCalls > 0 && State.InFlight == 0, "An observed native timer must deliver the genuine poll")
		AssertEqual(1, State.Answers.Length)
		AssertEqual(Run.Epoch, State.Answers[1].Epoch)
		AssertEqual("proxy_pac", State.Answers[1].Id)
		_TestPrint("# PAC_BOUNDARY mode=" . Mode . " raw_bytes=" . Raw.Size
			. " expected_normalized_bytes=" . Vector.NormalizedBytes . " normalized_bytes=" . Ready["normalized_bytes"] . " source_error=" . Ready["source_error"]
			. " utf8_valid=" . Request.ResponseEncodingValid . " source_allowed=" . Ready["source_allowed"]
			. " status=" . Request.Status . " diagnostic_state=" . State.Answers[1].Result["state"]
			. " polls=" . State.PollCalls . " raw_reads=" . State.RawReads . " bytes_sha256=" . State.RawSha)
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
			AssertContains(State.Output, "PAC_BOUNDARY_PEER mode=" . Mode)
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
	try _TestPrint("# PAC_BOUNDARY_RETIRE mode=" . Mode . " peer_completed=" . State.Completed
		. " peer_exit=" . State.Code . " peer_retired=" . PeerRetired . " requests_retired=" . RequestsRetired)
	catch as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	if IsObject(ExportFailure)
		throw ExportFailure
}


Test("PAC boundary: exact one MiB UTF8 remains admitted by source and diagnostics (diagnostics-pac-byte-boundary)", _HCPB_Case.Bind("utf8exact"))
Test("PAC boundary: UTF16 source bytes include BOM in their limit (diagnostics-pac-byte-boundary)", _HCPB_Case.Bind("utf16rawover"))
Test("PAC boundary: UTF16 normalization has its own UTF8 byte limit (diagnostics-pac-byte-boundary)", _HCPB_Case.Bind("utf16normalizedover"))
