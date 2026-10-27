; tests/unit/modules/llm/api/test_llm_api_ollama_native_enable_retirement.ahk

; ==============================================================================
; MODULE: Native Tray Enable Request Retirement Tests
; DESCRIPTION:
; Executes the shipped tray toggle, default native version probe and actual
; borrowed config writer. The existing tray fixture supplies lifecycle and UI
; ports; native HTTP and persistence execute. A passive witness observes the
; original production request.
; ==============================================================================

#Requires AutoHotkey v2.0

_OllamaNativeEnable_ObserveRun(State, Self, Command, WorkingDir, Options, &Pid, &ProcessOwner, TreeFactoryFn := unset) {
	global _LLM_Menu_EnableAdmission
	Self.DeleteProp("Call")
	Result := Self.Call(Command, WorkingDir, Options, &Pid, &ProcessOwner, TreeFactoryFn?)
	AssertTrue(ProcessOwner is Map, "the native observation must retain the genuine returned process owner")
	Request := _LLM_Menu_EnableAdmission
	AssertTrue(Request is Map && Request["active"], "the actual tray request must own this native dispatch")
	Request["test_retirement_witness"] := _LLM_TestRetirementWitness(State["counter"])
	State["launches"] += 1
	State["native_owner"] := ProcessOwner
	return Result
}

_OllamaNativeEnable_Body(Status, Counter, State) {
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_CurlCleanupDebt
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL, _LLM_Menu_EnableAdmission, ConfigurationFile
	SavedBootstrap := _LLM_ManagedBootstrap, SavedOrigin := LLM_OLLAMA_BASE_URL
	PreviousCritical := Critical("Off")
	Directory := A_Temp . "\ergopti_native_enable_" . A_TickCount . "_" . Random(1, 1000000)
	ReadyPath := Directory . "\port.txt", TranscriptPath := Directory . "\receipt.jsonl"
	PeerOwner := 0, ProcessOwner := 0
	NativeState := Map("launches", 0, "native_owner", 0, "counter", Counter)
	RunFn := _LLM_CurlArtifactRun
	HadRunCall := RunFn.HasOwnProp("Call")
	SavedRunCall := HadRunCall ? RunFn.GetOwnPropDesc("Call") : 0
	ObservedRun := false
	try {
		DirCreate(Directory)
		SplitPath(A_LineFile, , &TestDirectory)
		PeerScript := TestDirectory . "\..\..\..\..\fixtures\ollama_stream_http_peer.ahk"
		AssertTrue(FileExist(PeerScript), "the genuine loopback service source must exist")
		Command := _SR_BuildDirectCommandLine(A_AhkPath,
			["/ErrorStdOut", PeerScript, ReadyPath, TranscriptPath, String(Status), "ping"])
		PeerPid := 0
		_LLM_CurlArtifactRun(Command, Directory, "Hide", &PeerPid, &PeerOwner)
		Started := A_TickCount
		while !FileExist(ReadyPath) && !_LLM_CurlProcessExited(PeerOwner) && TickElapsed(Started) < 5000
			Sleep(10)
		AssertTrue(FileExist(ReadyPath), "the actual native service must publish its ephemeral listener")
		Ready := FileRead(ReadyPath, "UTF-8-RAW")
		AssertTrue(RegExMatch(Ready, "^[0-9]{1,5}`n\z"), "the actual ready receipt keeps decimal/LF grammar")
		Port := Integer(SubStr(Ready, 1, -1))
		AssertTrue(Port > 0 && Port <= 65535)
		AssertEqual(0, _LLM_AuxOwners.Count, "the existing tray fixture must start with no pending native owner")
		_LLM_ManagedBootstrap := 0
		LLM_OLLAMA_BASE_URL := "http://127.0.0.1:" . Port
		Before := FileRead(ConfigurationFile, "UTF-8")
		State["port"].Delete("probe")
		AssertFalse(HadRunCall, "the native launch observer must start from the genuine production boundary")
		RunFn.DefineProp("Call", {Call: _OllamaNativeEnable_ObserveRun.Bind(NativeState)})
		ObservedRun := true
		AssertTrue(LLM_Menu_OnToggle(State["port"]), "the shipped tray toggle must enter actual version admission")
		ProcessOwner := NativeState["native_owner"]
		AssertTrue(ProcessOwner is Map, "the actual tray path must acquire a genuine native curl Job")
		AssertEqual(1, NativeState["launches"], "one genuine native health request owns the tray action")
		AssertEqual(0, State["probes"], "the old fixture probe cannot synthesize transport or callback delivery")
		Started := A_TickCount
		while (_LLM_Menu_EnableAdmission is Map || !_LLM_CurlProcessExited(PeerOwner)) && TickElapsed(Started) < 10000
			Sleep(10)
		AssertTrue(_LLM_CurlProcessExited(PeerOwner), "the genuine service must complete its health exchange")
		PeerExit := 0, Diagnostic := ""
		AssertTrue(_SR_TreeReadExitCode(PeerOwner["handle"], &PeerExit, &Diagnostic))
		AssertEqual(0, PeerExit, "the real service successfully sends its complete response")
		Records := []
		for Line in StrSplit(FileRead(TranscriptPath, "UTF-8-RAW"), "`n", "`r")
			if Line != ""
				Records.Push(JsonParse(Line))
		AssertEqual(1, Records.Length, "the real tray version probe sends exactly one HTTP request")
		AssertEqual("GET", Records[1]["method"])
		AssertEqual(LLM_EnableVersionPath(), Records[1]["path"], "the actual health request uses the canonical endpoint")
		AssertEqual(Status, Records[1]["status"], "the native service emits the declared HTTP control")
		AssertTrue(ProcessOwner.Get("released", false), "the exact native curl Job must acknowledge retirement")
		AssertTrue(ProcessOwner.Get("terminal", 0) is Map)
		AssertEqual(0, ProcessOwner["terminal"]["exit"], "HTTP refusal remains independent of actual transport exit")
		AssertEqual(0, _LLM_Menu_EnableAdmission, "the actual tray action must retire its published request")
		AssertEqual(0, _LLM_AuxOwners.Count, "native version admission must retire its exact auxiliary slot")
		AssertEqual(0, _LLM_AuxCleanupDebt.Count, "the real action cannot hide auxiliary cleanup debt")
		AssertEqual(0, _LLM_CurlCleanupDebt.Count, "the real action cannot hide process or private-artifact cleanup debt")
		AssertEqual(Status == 200 ? 1 : 0, State["writes"], "only successful native readiness may reach the actual borrowed writer")
		AssertEqual(Status == 200 ? 1 : 0, State["applies"], "backend application follows acknowledged persistence")
		AssertEqual(Status == 200 ? 0 : 1, State["notices"], "only actual HTTP refusal reaches the modal UI boundary")
		if Status == 200 {
			AssertFalse(State["enabled_at_write"], "the real writer sees the old disabled preference")
			AssertTrue(State["lease_at_write"], "the actual terminal lease owns the durable config write")
			AssertTrue(State["enabled_at_apply"], "activation observes the successfully published preference")
			AssertContains(State["disk_at_apply"], "enabled = true", "physical config persistence precedes activation")
			AssertContains(State["disk_at_apply"], 'value = "keep"', "the original foreign source remains owned")
		} else
			AssertTrue(FSUtf8ExactMatches(ConfigurationFile, Before), "an actual HTTP refusal preserves the exact disabled config source")
		AssertEqual(0, State["callback"], "the fixture never retains the production request callback")
		AssertEqual(0, State["owner"], "the fixture never retains the production auxiliary owner")
	} finally {
		if ObservedRun && RunFn.HasOwnProp("Call")
			RunFn.DeleteProp("Call")
		if HadRunCall
			RunFn.DefineProp("Call", SavedRunCall)
		try {
			LLM_Menu_CancelEnableAdmission()
			for NativeOwner in [ProcessOwner, PeerOwner] {
				if !(NativeOwner is Map)
					continue
				Released := _LLM_CurlReleaseProcess(NativeOwner, true), Started := A_TickCount
				while !Released && TickElapsed(Started) < 5000 {
					Sleep(10)
					Released := _LLM_CurlReleaseProcess(NativeOwner, true)
				}
				AssertTrue(Released, "the native fixture cannot abandon a real process owner")
			}
			AssertTrue(LLM_AuxRetryCleanupDebt() && LLM_CurlRetryCleanupDebt(), "the existing fixture must retain any genuine cleanup refusal")
		} finally {
			_LLM_ManagedBootstrap := SavedBootstrap, LLM_OLLAMA_BASE_URL := SavedOrigin
			if DirExist(Directory)
				DirDelete(Directory, true)
			Critical(PreviousCritical)
		}
	}
}

_OllamaNativeEnable_Retirement(Status) {
	Counter := Map("deleted", 0)
	_LLM_TestReleaseIndependentWitness(Counter)
	AssertEqual(1, Counter["deleted"], "an independent witness proves actual object destruction")
	Counter["deleted"] := 0
	_LEA_WithFixture(_OllamaNativeEnable_Body.Bind(Status, Counter))
	AssertEqual(1, Counter["deleted"], "the completed shipped tray request must release its native receipt callback closure")
}

for _OllamaNativeEnableStatus in [200, 500]
	Test("Ollama native tray enable: HTTP" . _OllamaNativeEnableStatus . " releases its request (ollama-native-tray-retirement)",
		_OllamaStream_WithBootTimings.Bind(_OllamaNativeEnable_Retirement.Bind(_OllamaNativeEnableStatus)))
