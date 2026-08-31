; tests/unit/test_network_dispatch_nonblocking.ahk
;
; ==============================================================================
; MODULE: Network Dispatch Non-Blocking Regression Tests
; DESCRIPTION:
; Holds a real loopback HTTP response while proving that the shared Windows curl
; transport returns promptly and continues pumping AHK timers. Also ratchets every
; production network entrypoint implicated by AHK-027 onto a child transport.
; ==============================================================================

_NDB_Delete(Path) {
	try FileDelete(Path)
}

_NDB_WaitForReadyPort(Path, &Port, TimeoutMs := 5000) {
	Started := A_TickCount
	loop {
		ReadyText := ""
		try ReadyText := Trim(FileRead(Path, "UTF-8-RAW"))
		if RegExMatch(ReadyText, "^\d+$") {
			Candidate := Integer(ReadyText)
			if Candidate >= 1 and Candidate <= 65535 {
				Port := Candidate
				return true
			}
		}
		if ((A_TickCount - Started) & 0xFFFFFFFF) >= TimeoutMs
			return false
		Sleep(10)
	}
}

_NDB_ReadyPortWaitsForPublishedContent() {
	Path := A_Temp . "\ergopti_http_empty_ready_"
		. DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	Port := 0
	PublishPort(*) {
		FSWrite(Path, "54321")
	}
	try {
		AssertTrue(FSWrite(Path, ""),
			"the readiness-race fixture must start as an existing empty file")
		SetTimer(PublishPort, -50)
		AssertTrue(_NDB_WaitForReadyPort(Path, &Port, 1000),
			"readiness must wait for valid port content, not mere file existence")
		AssertEqual(54321, Port,
			"the readiness helper must publish the fully parsed port")
	} finally {
		SetTimer(PublishPort, 0)
		_NDB_Delete(Path)
	}
}
Test("HTTP transport fixture: readiness waits for complete port content (AHK-172)",
	_NDB_ReadyPortWaitsForPublishedContent)

_NDB_ChildTransportPumpsHeartbeat() {
	Nonce := DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_" . A_TickCount
	ScriptPath := A_Temp . "\ergopti_http_listener_" . Nonce . ".ps1"
	ReadyPath := A_Temp . "\ergopti_http_listener_" . Nonce . ".ready"
	Script := "param([string]$ReadyPath)" . "`n"
		. "$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)" . "`n"
		. "$listener.Start()" . "`n"
		. "[System.IO.File]::WriteAllText($ReadyPath, [string]$listener.LocalEndpoint.Port)" . "`n"
		. "$client = $listener.AcceptTcpClient()" . "`n"
		. "Start-Sleep -Milliseconds 900" . "`n"
		. "$stream = $client.GetStream()" . "`n"
		. "$text = 'HTTP/1.1 200 OK' + [char]13 + [char]10 + 'Content-Length: 2' + [char]13 + [char]10 + 'Connection: close' + [char]13 + [char]10 + [char]13 + [char]10 + 'OK'" . "`n"
		. "$bytes = [System.Text.Encoding]::ASCII.GetBytes($text)" . "`n"
		. "$stream.Write($bytes, 0, $bytes.Length)" . "`n"
		. "$stream.Dispose()" . "`n"
		. "$client.Dispose()" . "`n"
		. "$listener.Stop()" . "`n"
	Server := 0
	Req := 0
	Beats := 0
	Beat(*) {
		Beats += 1
	}
	try {
		_NDB_Delete(ScriptPath)
		_NDB_Delete(ReadyPath)
		AssertTrue(FSWrite(ScriptPath, Script),
			"the delayed loopback listener fixture must be staged")
		Server := ShellRunner_SpawnTreeOwned("powershell.exe", [
			"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
			"-ExecutionPolicy", "Bypass", "-File", ScriptPath, ReadyPath
		], (*) => 0)
		AssertTrue(Server.start(), "the delayed loopback listener must start")
		AssertTrue(_NDB_WaitForReadyPort(ReadyPath, &Port),
			"the delayed loopback listener must publish a complete valid port")

		SetTimer(Beat, 10)
		Req := CurlAsyncRequest()
		Req.Open("GET", "http://127.0.0.1:" . Port . "/held", true)
		Req.SetTimeouts(500, 500, 500, 2500)
		DispatchStarted := A_TickCount
		AssertTrue(Req.Send())
		DispatchMs := (A_TickCount - DispatchStarted) & 0xFFFFFFFF
		WaitStarted := A_TickCount
		while !Req.WaitForResponse(0) {
			if (((A_TickCount - WaitStarted) & 0xFFFFFFFF) >= 5000)
				break
			Sleep(10)
		}
		WaitMs := (A_TickCount - WaitStarted) & 0xFFFFFFFF
		SetTimer(Beat, 0)

		AssertTrue(DispatchMs < 750,
			"network dispatch must return before the held response (ms="
			. DispatchMs . ")")
		AssertTrue(Req.WaitForResponse(0),
			"the delayed loopback response must complete within its hard deadline")
		AssertTrue(WaitMs >= 700,
			"positive control: the server must actually withhold the response")
		AssertTrue(Beats >= 20,
			"AHK timers must keep advancing while the child waits (beats="
			. Beats . ")")
		AssertEqual(200, Req.Status)
		AssertEqual("OK", Req.ResponseText)
		for Path in [Req.ConfigPath, Req.BodyPath, Req.HeaderPath]
			AssertFalse(FileExist(Path),
				"terminal HTTP cleanup must remove private transport artifacts")
	} finally {
		SetTimer(Beat, 0)
		if IsObject(Req) && !Req.WaitForResponse(0)
			Req.Abort()
		if IsObject(Server)
			try Server.terminate()
		_NDB_Delete(ScriptPath)
		_NDB_Delete(ReadyPath)
	}
}
Test("HTTP transport: held response never stalls the AHK heartbeat (network-dispatch-nonblocking)",
	_NDB_ChildTransportPumpsHeartbeat)

_NDB_CancelDuringStagingPreventsChildLaunch() {
	State := Map("checkpoint", 0, "spawn", 0, "start", 0, "terminate", 0)
	Req := 0
	AbortBeforeLaunch(Request) {
		State["checkpoint"] += 1
		Request.Abort()
	}
	FakeStart(*) {
		State["start"] += 1
		return true
	}
	FakeTerminate(*) {
		State["terminate"] += 1
		return true
	}
	FakeSpawn(*) {
		State["spawn"] += 1
		return {start: FakeStart, terminate: FakeTerminate}
	}
	try {
		Req := CurlAsyncRequest(Map(
			"before_launch", AbortBeforeLaunch,
			"spawn", FakeSpawn))
		Req.Open("GET", "https://example.invalid/never-dispatched", true)
		AssertFalse(Req.Send(),
			"a cancellation reached while staging must refuse child dispatch")
		AssertEqual(1, State["checkpoint"],
			"the deterministic staging boundary must run exactly once")
		AssertEqual(0, State["spawn"],
			"a canceled transport must not construct a curl child (AHK-155)")
		AssertEqual(0, State["start"],
			"a canceled transport must not start a curl child (AHK-155)")
		AssertTrue(Req.Aborted and Req.Completed,
			"the request must retain its terminal cancellation state")
	} finally {
		if IsObject(Req)
			Req.Abort()
	}
}
Test("HTTP transport: cancellation during staging prevents curl launch (AHK-155)",
	_NDB_CancelDuringStagingPreventsChildLaunch)

_NDB_CancelDuringStartReportsDispatchRefusal() {
	State := Map("start", 0, "terminate", 0)
	Req := 0
	FakeTerminate(*) {
		State["terminate"] += 1
		return true
	}
	FakeStart(*) {
		State["start"] += 1
		Req.Abort()
		return true
	}
	FakeSpawn(*) => {start: FakeStart, terminate: FakeTerminate}
	try {
		Req := CurlAsyncRequest(Map("spawn", FakeSpawn))
		Req.Open("GET", "https://example.invalid/canceled-start", true)
		AssertFalse(Req.Send(),
			"Send must not report a launched request after reentrant start cancellation")
		AssertEqual(1, State["start"])
		AssertEqual(1, State["terminate"],
			"the exact starting handle must be terminated once")
		AssertTrue(Req.Aborted and Req.Completed,
			"the request must retain its terminal cancellation state")
		AssertEqual(0, Req.Handle,
			"the resumed Send stack must not republish the canceled handle")
		for Path in [Req.ConfigPath, Req.BodyPath, Req.HeaderPath]
			AssertFalse(FileExist(Path),
				"start cancellation must leave no private curl artifact behind")
	} finally {
		if IsObject(Req)
			Req.Abort()
	}
}
Test("HTTP transport: cancellation during handle start is reported (curl-start-cancel-verdict)",
	_NDB_CancelDuringStartReportsDispatchRefusal)

_NDB_CancelDuringCompletionCannotPublishResponse() {
	State := Map("checkpoint", 0)
	Req := 0
	AbortBeforePublish(Request) {
		State["checkpoint"] += 1
		Request.Abort()
	}
	try {
		Req := CurlAsyncRequest(Map(
			"before_response_publish", AbortBeforePublish))
		AssertTrue(FSWrite(Req.HeaderPath,
			"HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
		Req._OnDone(0, '{"ok":true}', "")
		AssertEqual(1, State["checkpoint"],
			"the terminal seam must interrupt after header work and before publication")
		AssertTrue(Req.Aborted and Req.Completed)
		AssertEqual(0, Req.Status,
			"an aborted completion must not publish its parsed status")
		AssertEqual("", Req.ResponseText,
			"an aborted completion must not publish its response body")
		AssertEqual(0, Req.ResponseHeaders.Count,
			"an aborted completion must not publish response headers")
	} finally {
		if IsObject(Req)
			Req.Abort()
	}
}
Test("HTTP transport: completion cannot publish after reentrant Abort (curl-completion-abort-fence)",
	_NDB_CancelDuringCompletionCannotPublishResponse)

_NDB_AbortRefusalRetainsExactChildForRetry() {
	global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_ABORT_TIMER
	SavedDebts := IsSet(_HTTP_CURL_ABORT_DEBTS) ? _HTTP_CURL_ABORT_DEBTS : 0
	SavedTimer := IsSet(_HTTP_CURL_ABORT_TIMER) ? _HTTP_CURL_ABORT_TIMER : 0
	_HTTP_CURL_ABORT_DEBTS := Map()
	; Prevent the real one-shot retry from racing these synchronous assertions.
	_HTTP_CURL_ABORT_TIMER := {}
	State := Map("terminate", 0)
	FakeTerminate(*) {
		State["terminate"] += 1
		return State["terminate"] > 1
	}
	Req := CurlAsyncRequest()
	Handle := { terminate: FakeTerminate }
	Req.Handle := Handle
	try {
		AssertFalse(Req.Abort(),
			"a refused curl child termination must be reported")
		AssertTrue(Req.Aborted and !Req.Completed,
			"a refused curl termination must remain non-terminal")
		AssertTrue(Req.Handle == Handle,
			"a refused curl termination must retain the exact child handle")
		AssertTrue(_HTTP_CURL_ABORT_DEBTS.Has(Req.CleanupDebtId)
			and _HTTP_CURL_ABORT_DEBTS[Req.CleanupDebtId] == Req,
			"a refused curl termination must remain globally owned for retry")

		AssertTrue(Req.Abort(),
			"the retained curl child must accept a later termination retry")
		AssertTrue(Req.Completed and Req.Handle == 0,
			"the curl request may become terminal only after termination succeeds")
		AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Req.CleanupDebtId),
			"proved termination must release the global abort debt")
		AssertEqual(2, State["terminate"],
			"the retry must target the original curl child handle")
	} finally {
		_HTTP_CURL_ABORT_DEBTS := SavedDebts
		_HTTP_CURL_ABORT_TIMER := SavedTimer
	}
}
Test("HTTP transport: Abort refusal retains the exact child for retry (AHK-171)",
	_NDB_AbortRefusalRetainsExactChildForRetry)

_NDB_AbortedChildNaturalCompletionSettlesDebt() {
	global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_ABORT_TIMER
	SavedDebts := _HTTP_CURL_ABORT_DEBTS
	SavedTimer := _HTTP_CURL_ABORT_TIMER
	_HTTP_CURL_ABORT_DEBTS := Map()
	_HTTP_CURL_ABORT_TIMER := {}
	FakeTerminate(*) => false
	Req := CurlAsyncRequest()
	Req.Handle := { terminate: FakeTerminate }
	try {
		AssertFalse(Req.Abort(),
			"the natural-completion fixture must first retain termination debt")
		Req._OnDone(0, "discarded response", "")
		AssertTrue(Req.Completed and Req.Handle == 0,
			"natural child completion must prove an aborted request terminal")
		AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Req.CleanupDebtId),
			"natural child completion must release retained abort ownership")
		AssertEqual(0, Req.Status)
		AssertEqual("", Req.ResponseText,
			"an aborted child completion must never publish its response")
	} finally {
		_HTTP_CURL_ABORT_DEBTS := SavedDebts
		_HTTP_CURL_ABORT_TIMER := SavedTimer
	}
}
Test("HTTP transport: natural completion settles retained Abort debt (AHK-171)",
	_NDB_AbortedChildNaturalCompletionSettlesDebt)

_NDB_CancelDuringSpawnRetainsRefusedChild() {
	global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_ABORT_TIMER
	SavedDebts := _HTTP_CURL_ABORT_DEBTS
	SavedTimer := _HTTP_CURL_ABORT_TIMER
	_HTTP_CURL_ABORT_DEBTS := Map()
	_HTTP_CURL_ABORT_TIMER := {}
	State := Map("start", 0, "terminate", 0)
	Req := 0
	FakeStart(*) {
		State["start"] += 1
		return true
	}
	FakeTerminate(*) {
		State["terminate"] += 1
		return State["terminate"] > 1
	}
	Handle := { start: FakeStart, terminate: FakeTerminate }
	FakeSpawn(*) {
		Req.Abort()
		return Handle
	}
	try {
		Req := CurlAsyncRequest(Map("spawn", FakeSpawn))
		Req.Open("GET", "https://example.invalid/cancel-during-spawn", true)
		AssertFalse(Req.Send(),
			"a cancellation pumped inside spawn must refuse child dispatch")
		AssertTrue(Req.Aborted and !Req.Completed,
			"a refused post-spawn termination must remain non-terminal")
		AssertTrue(Req.Handle == Handle,
			"the handle returned after cancellation must remain exactly owned")
		AssertEqual(0, State["start"],
			"a handle returned after cancellation must never start")
		AssertTrue(_HTTP_CURL_ABORT_DEBTS.Has(Req.CleanupDebtId),
			"post-spawn termination refusal must remain globally retryable")
		AssertTrue(Req.Abort(),
			"the retained post-spawn handle must accept a later retry")
	} finally {
		_HTTP_CURL_ABORT_DEBTS := SavedDebts
		_HTTP_CURL_ABORT_TIMER := SavedTimer
	}
}
Test("HTTP transport: spawn-time cancel retains a refused child (AHK-173)",
	_NDB_CancelDuringSpawnRetainsRefusedChild)

_NDB_PartialStartFailureRetainsRefusedChild() {
	global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_ABORT_TIMER
	SavedDebts := _HTTP_CURL_ABORT_DEBTS
	SavedTimer := _HTTP_CURL_ABORT_TIMER
	_HTTP_CURL_ABORT_DEBTS := Map()
	_HTTP_CURL_ABORT_TIMER := {}
	State := Map("start", 0, "terminate", 0)
	FakeStart(*) {
		State["start"] += 1
		throw Error("injected partial curl start failure")
	}
	FakeTerminate(*) {
		State["terminate"] += 1
		return State["terminate"] > 1
	}
	Handle := { start: FakeStart, terminate: FakeTerminate }
	FakeSpawn(*) => Handle
	Req := CurlAsyncRequest(Map("spawn", FakeSpawn))
	DidThrow := false
	try {
		Req.Open("GET", "https://example.invalid/partial-start", true)
		try Req.Send()
		catch {
			DidThrow := true
		}
		AssertTrue(DidThrow,
			"the injected partial start failure must reach its caller")
		AssertTrue(Req.Aborted and !Req.Completed,
			"a refused partial-start rollback must remain non-terminal")
		AssertTrue(Req.Handle == Handle,
			"partial-start rollback refusal must retain the exact handle")
		AssertTrue(_HTTP_CURL_ABORT_DEBTS.Has(Req.CleanupDebtId),
			"partial-start rollback refusal must remain globally retryable")
		AssertTrue(Req.Abort(),
			"the retained partial-start handle must accept a later retry")
	} finally {
		_HTTP_CURL_ABORT_DEBTS := SavedDebts
		_HTTP_CURL_ABORT_TIMER := SavedTimer
	}
}
Test("HTTP transport: partial Start rollback retains a refused child (AHK-173)",
	_NDB_PartialStartFailureRetainsRefusedChild)

_NDB_FalseStartVerdictRetainsRefusedChild() {
	global _HTTP_CURL_ABORT_DEBTS, _HTTP_CURL_ABORT_TIMER
	SavedDebts := _HTTP_CURL_ABORT_DEBTS
	SavedTimer := _HTTP_CURL_ABORT_TIMER
	_HTTP_CURL_ABORT_DEBTS := Map()
	_HTTP_CURL_ABORT_TIMER := {}
	State := Map("terminate", 0)
	FakeStart(*) => false
	FakeTerminate(*) {
		State["terminate"] += 1
		return State["terminate"] > 1
	}
	Handle := { start: FakeStart, terminate: FakeTerminate }
	FakeSpawn(*) => Handle
	Req := CurlAsyncRequest(Map("spawn", FakeSpawn))
	DidThrow := false
	try {
		Req.Open("GET", "https://example.invalid/false-start", true)
		try Req.Send()
		catch {
			DidThrow := true
		}
		AssertTrue(DidThrow,
			"a false child Start receipt must reject dispatch")
		AssertTrue(Req.Aborted and !Req.Completed and Req.Handle == Handle,
			"a false Start rollback refusal must retain the exact non-terminal child")
		AssertTrue(_HTTP_CURL_ABORT_DEBTS.Has(Req.CleanupDebtId),
			"a false Start rollback refusal must remain globally retryable")
		AssertTrue(Req.Abort(),
			"the retained false-Start child must accept a later retry")
	} finally {
		_HTTP_CURL_ABORT_DEBTS := SavedDebts
		_HTTP_CURL_ABORT_TIMER := SavedTimer
	}
}
Test("HTTP transport: false Start rollback retains a refused child (AHK-173)",
	_NDB_FalseStartVerdictRetainsRefusedChild)

_NDB_CancelledStagingRetriesLockedArtifactCleanup() {
	State := Map("checkpoint", 0, "spawn", 0, "lock", 0)
	Req := 0
	LockAndAbortBeforeLaunch(Request) {
		State["checkpoint"] += 1
		; The temporary request body can be held briefly by a scanner or backup
		; agent. Deny delete access deterministically while cancellation races the
		; staging boundary, then release it before asserting the retained owner
		; retries cleanup.
		State["lock"] := FileOpen(Request.BodyPath, "r-d", "UTF-8-RAW")
		Request.Abort()
	}
	FakeSpawn(*) {
		State["spawn"] += 1
		return 0
	}
	try {
		Req := CurlAsyncRequest(Map(
			"before_launch", LockAndAbortBeforeLaunch,
			"spawn", FakeSpawn))
		Req.Open("POST", "https://example.invalid/canceled-staging", true)
		Req.SetRequestHeader("Authorization", "Bearer audit-secret")
		AssertFalse(Req.Send("sensitive staged request body"),
			"a cancellation reached while staging must refuse child dispatch")
		AssertEqual(1, State["checkpoint"],
			"the deterministic staging cancellation boundary must run exactly once")
		AssertEqual(0, State["spawn"],
			"a canceled staging request must not construct a curl child")
		AssertTrue(FileExist(Req.BodyPath),
			"the deny-delete fixture must hold the staged body until cleanup can be retried")
		State["lock"].Close()
		State["lock"] := 0
		CleanupStarted := A_TickCount
		while FileExist(Req.BodyPath) {
			if ((A_TickCount - CleanupStarted) & 0xFFFFFFFF) >= 1000
				break
			Sleep(10)
		}
		AssertFalse(FileExist(Req.BodyPath),
			"a canceled request must retain cleanup ownership until a transient body lock releases")
	} finally {
		if IsObject(State["lock"])
			try State["lock"].Close()
		if IsObject(Req) {
			for Path in [Req.ConfigPath, Req.BodyPath, Req.HeaderPath]
				try FileDelete(Path)
		}
	}
}
Test("HTTP transport: canceled staging retries locked artifact cleanup (AHK-157)",
	_NDB_CancelledStagingRetriesLockedArtifactCleanup)

_NDB_EveryProductionEntrypointUsesChildTransport() {
	for FunctionName in [
		"_Updater_PrepareLatestAsyncTransport",
		"_Updater_PrepareReleasesListAsyncTransport",
		"_CLW_DoFetch",
		"LLM_RemoteIsReady_Async",
		"LLM_OllamaWarmup"
	] {
		Body := _DriverFuncBody(FunctionName)
		Assert(InStr(Body, "CurlAsyncRequest()") > 0,
			FunctionName . " must construct the tree-owned curl transport")
		Assert(!InStr(Body, "ComObject(") and !InStr(Body, "WinHttp"),
			FunctionName . " must not construct WinHTTP on the AHK thread")
	}
	for FunctionName in [
		"LLM_OllamaIsRunning_Async",
		"LLM_OllamaListModels_Async",
		"_LLMRemote_DispatchCurl"
	] {
		Body := _DriverFuncBody(FunctionName)
		Assert(InStr(Body, "curl") > 0,
			FunctionName . " must dispatch its established curl child")
		Assert(!InStr(Body, "ComObject("),
			FunctionName . " must not construct WinHTTP")
	}
	GenerateBody := _DriverFuncBody("LLM_RemoteGenerate_Async")
	Assert(!InStr(GenerateBody, "_LLMRemote_DispatchWinHttp("),
		"remote generation must fail closed if curl is unavailable")
	EnsureBody := _DriverFuncBody("LLM_Menu_EnsureModelReady")
	Assert(!InStr(EnsureBody, "Sync")
		and InStr(EnsureBody, "LLM_InstalledTagsCacheReady()") > 0,
		"model readiness must wait for its async cache instead of probing inline")
}
Test("HTTP transport: every production entrypoint owns a child transport (network-dispatch-nonblocking)",
	_NDB_EveryProductionEntrypointUsesChildTransport)
