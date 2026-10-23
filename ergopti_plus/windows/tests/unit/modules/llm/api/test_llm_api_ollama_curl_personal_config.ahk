; tests/unit/modules/llm/api/test_llm_api_ollama_curl_personal_config.ahk

; ==============================================================================
; MODULE: Ollama curl Personal Configuration Isolation Tests
; DESCRIPTION:
; curl reads the user's personal .curlrc (from CURL_HOME, APPDATA or the home
; folder) unless --disable is its first argument. The managed transport already
; passed --disable, but both Ollama command lines did not: an inherited .curlrc
; could add headers, redirect output, change TLS verification or, as measured
; here, write a full request trace. Each production Ollama launch is driven for
; real against a closed loopback port with a private CURL_HOME whose .curlrc
; asks for a trace file; the trace must never appear. A control launch without
; --disable proves the same .curlrc is honoured on this machine.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../support/filesystem_write_lock.ahk

; The discard port has no listener on a default Windows install, so curl reads
; its configuration, then fails to connect immediately.
global _OCPC_CLOSED_ORIGIN := "http://127.0.0.1:9"

_OCPC_Fixture() {
	Root := _FSWL_Path() . ".curlrc"
	DirCreate(Root)
	Trace := Root . "\trace.txt"
	Config := 'trace-ascii = "' . StrReplace(Trace, "\", "\\") . '"' . "`n"
	FileAppend(Config, Root . "\.curlrc", "UTF-8-RAW")
	return Map("root", Root, "trace", Trace, "saved_home", EnvGet("CURL_HOME"))
}

_OCPC_Release(Fixture) {
	EnvSet("CURL_HOME", Fixture["saved_home"])
	if DirExist(Fixture["root"])
		DirDelete(Fixture["root"], true)
}

; Launches the production command for real, then waits natively for its
; wrapper to exit. Production calls this inside Critical, where no timer can
; run, so the wait cannot let a stream poll retire curl before it reads its
; configuration.
_OCPC_RecordRun(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	static SYNCHRONIZE := 0x00100000, PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
	State["commands"].Push(Command)
	_LLM_CurlArtifactRun(Command, WorkingDir, Options, &Pid, &ProcessOwner)
	State["owner"] := ProcessOwner
	Handle := DllCall("Kernel32\OpenProcess", "UInt", SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
		"Int", false, "UInt", Pid, "Ptr")
	AssertTrue(Handle != 0, "the fixture must observe the exact launched wrapper")
	try {
		AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Handle, "UInt", 10000, "UInt"),
			"the launched curl wrapper must exit against the closed port")
		ExitCode := -1
		AssertTrue(DllCall("Kernel32\GetExitCodeProcess", "Ptr", Handle, "UInt*", &ExitCode, "Int"))
		; The wrapper exits with curl's status; 7 (connection refused) proves the
		; request got past its configuration to the closed loopback port.
		State["exit"] := ExitCode
	} finally DllCall("Kernel32\CloseHandle", "Ptr", Handle)
}

; Waits outside the production Critical section, where the tree poller runs.
_OCPC_AwaitExit(Owner) {
	AssertTrue(Owner is Map, "the production launch must hand back its exact process owner")
	Begin := A_TickCount
	while !_LLM_CurlProcessExited(Owner) && TickElapsed(Begin) < 10000
		Sleep(10)
	AssertTrue(_LLM_CurlProcessExited(Owner), "the actual curl child must finish against the closed port")
	Retired := _LLM_CurlReleaseProcess(Owner, true)
	Begin := A_TickCount
	while !Retired && TickElapsed(Begin) < 5000 {
		Sleep(10)
		Retired := _LLM_CurlReleaseProcess(Owner, true)
	}
	AssertTrue(Retired, "the fixture must receive native retirement before deleting its files")
}

; Proves the oracle: the same CURL_HOME is honoured by a curl run without --disable.
_OCPC_ControlHonoursPersonalConfig() {
	Fixture := _OCPC_Fixture()
	try {
		EnvSet("CURL_HOME", Fixture["root"])
		Root := Fixture["root"]
		Command := _Q(A_WinDir . "\System32\curl.exe") . " -s -S -m 5 " . _Q(_OCPC_CLOSED_ORIGIN . "/api/chat")
		State := Map("commands", [], "owner", 0)
		_OCPC_RecordRun(State, _LLM_CurlOwnedCommand(Command, Root . "\control.status", Root . "\control.exit"),
			"", "Hide", &Pid, &Owner)
		_OCPC_AwaitExit(State["owner"])
		AssertEqual(7, State["exit"], "the actual curl must get past its configuration to the closed port")
		AssertTrue(FileExist(Fixture["trace"]) != "",
			"control: curl without --disable must honour the private .curlrc on this machine")
	} finally _OCPC_Release(Fixture)
}
Test("Ollama curl: control proves an inherited .curlrc is honoured without --disable (ollama-curl-personal-config)",
	_OCPC_ControlHonoursPersonalConfig)

_OCPC_DeferredSpawnIgnoresPersonalConfig() {
	global _LLM_Ollama_Async, _LLM_Ollama_ActiveStreams, _LLM_Ollama_Pending
	Fixture := _OCPC_Fixture()
	SavedAsync := _LLM_Ollama_Async, SavedStreams := _LLM_Ollama_ActiveStreams, SavedPending := _LLM_Ollama_Pending
	ReqId := 99961
	try {
		EnvSet("CURL_HOME", Fixture["root"])
		Root := Fixture["root"]
		State := Map("commands", [], "owner", 0, "polls", 0, "failed", 0)
		Port := Map("run", _OCPC_RecordRun.Bind(State), "poll", (Id) => State["polls"] += 1)
		_LLM_Ollama_Async := Map()
		_LLM_Ollama_ActiveStreams := []
		_LLM_Ollama_Pending := ""
		Job := Map("on_success", (*) => 0, "on_fail", (*) => State["failed"] += 1)
		_LLM_Ollama_Async[ReqId] := Map("pid", 0, "process_owner", 0, "base_url", _OCPC_CLOSED_ORIGIN,
			"tmp_payload", Root . "\request.json", "tmp_stdout", Root . "\request.out",
			"tmp_status", Root . "\request.status", "tmp_exit", Root . "\request.exit",
			"on_success", Job["on_success"], "on_fail", Job["on_fail"], "cancelled", false,
			"start_tick", A_TickCount, "timeout_ms", 5000, "payload_snip", "")
		_LLM_Ollama_DoSpawn(ReqId, '{"model":"m"}', Root . "\request.json", Root . "\request.out", Job, Port)
		AssertEqual(1, State["commands"].Length, "the deferred spawn must launch exactly one curl")
		_OCPC_AwaitExit(State["owner"])
		AssertEqual(7, State["exit"], "the actual curl must get past its configuration to the closed port")
		AssertFalse(FileExist(Fixture["trace"]) != "",
			"the deferred Ollama request must ignore the user's personal .curlrc")
	} finally {
		_LLM_Ollama_Async := SavedAsync
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_Pending := SavedPending
		_OCPC_Release(Fixture)
	}
}
Test("Ollama curl: the deferred request ignores an inherited .curlrc (ollama-curl-personal-config)",
	_OCPC_DeferredSpawnIgnoresPersonalConfig)

_OCPC_StreamingIgnoresPersonalConfig() {
	global _LLM_Ollama_ActiveStreams, LLM_OLLAMA_BASE_URL
	Fixture := _OCPC_Fixture()
	SavedStreams := _LLM_Ollama_ActiveStreams, SavedOrigin := LLM_OLLAMA_BASE_URL
	try {
		EnvSet("CURL_HOME", Fixture["root"])
		Root := Fixture["root"]
		State := Map("commands", [], "owner", 0, "failed", 0)
		Port := Map("temp_dir", (*) => Root, "run", _OCPC_RecordRun.Bind(State))
		_LLM_Ollama_ActiveStreams := []
		LLM_OLLAMA_BASE_URL := _OCPC_CLOSED_ORIGIN
		Handle := LLM_OllamaGenerate_Streaming("m", "s", "private text", 0.1,
			(*) => 0, (*) => 0, (*) => State["failed"] += 1, "", "", false, "", Port)
		AssertFalse(Handle.Cancelled, "the streaming request must reach its curl launch")
		AssertEqual(1, State["commands"].Length, "the streaming request must launch exactly one curl")
		_OCPC_AwaitExit(State["owner"])
		AssertEqual(7, State["exit"], "the actual curl must get past its configuration to the closed port")
		AssertFalse(FileExist(Fixture["trace"]) != "",
			"the streaming Ollama request must ignore the user's personal .curlrc")
	} finally {
		LLM_OllamaCancelStreams()
		_LLM_Ollama_ActiveStreams := SavedStreams
		LLM_OLLAMA_BASE_URL := SavedOrigin
		_OCPC_Release(Fixture)
	}
}
Test("Ollama curl: the streaming request ignores an inherited .curlrc (ollama-curl-personal-config)",
	_OCPC_StreamingIgnoresPersonalConfig)
