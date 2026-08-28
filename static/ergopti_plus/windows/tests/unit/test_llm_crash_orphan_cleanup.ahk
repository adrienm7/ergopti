; static/ergopti_plus/windows/tests/unit/test_llm_crash_orphan_cleanup.ahk

_LCOC_WriteOld(Path) {
	FileAppend("owned", Path, "UTF-8-RAW")
	FileSetTime("20200101000000", Path, "M")
}

_LCOC_AllArtifactsAreReapedWithoutTouchingCurrentInstance() {
	Root := A_Temp . "\ergopti_test_ahk2_03_" . A_TickCount . "_"
		. DllCall("GetCurrentProcessId")
	DeadDir := Root . "\ergopti_llm_111111"
	ActiveDir := Root . "\ergopti_llm_222222"
	DirCreate(DeadDir)
	DirCreate(ActiveDir)

	DeadNames := [
		"ergopti_ollama_1.json",
		"ergopti_ollama_1.out",
		"ergopti_ollama_1.out.status",
		"ergopti_ollama_1.out.exit",
		"ergopti_remote_1.json",
		"ergopti_remote_1.out",
		"ergopti_remote_1.out.status",
		"ergopti_remote_1.out.exit",
		"ergopti_remote_1.conf"
	]
	ActiveNames := [
		"ergopti_ollama_active.json",
		"ergopti_ollama_active.out.status",
		"ergopti_remote_active.conf",
		"ergopti_remote_active.out.exit"
	]

	try {
		for Name in DeadNames
			_LCOC_WriteOld(DeadDir . "\" . Name)
		for Name in ActiveNames
			_LCOC_WriteOld(ActiveDir . "\" . Name)

		_LLM_Ollama_StreamCleanupOrphans(Root, ActiveDir)

		for Name in DeadNames
			AssertEqual("", FileExist(DeadDir . "\" . Name),
				"(ahk2-03-crash-orphan-cleanup) every dead Ollama/remote payload, token, body, status and exit artifact must be reaped: " . Name)
		AssertEqual("", FileExist(DeadDir),
			"(ahk2-03-crash-orphan-cleanup) an empty dead-instance directory must be removed")
		for Name in ActiveNames
			Assert(FileExist(ActiveDir . "\" . Name) != "",
				"(ahk2-03-crash-orphan-cleanup) the current instance must retain its owned artifact: " . Name)
	} finally {
		try DirDelete(Root, true)
	}
}
Test("LLM curl artifacts: crash reaper owns every family but not the current instance (ahk2-03-crash-orphan-cleanup)",
	_LCOC_AllArtifactsAreReapedWithoutTouchingCurrentInstance)

_LCOC_InstanceDirectorySurvivesPidReuse() {
	Root := "C:\temp"
	Pid := 4242
	First := _LLM_Ollama_BuildTempDir(Root, Pid,
		"11111111111111111111111111111111")
	Second := _LLM_Ollama_BuildTempDir(Root, Pid,
		"22222222222222222222222222222222")
	AssertFalse(First == Second,
		"two script instances with the same recycled PID need distinct ownership directories")
	AssertContains(First, "ergopti_llm_4242_11111111111111111111111111111111")
	LiveDir := _LLM_Ollama_TempDir()
	Assert(RegExMatch(LiveDir, "i)\\ergopti_llm_\d+_[0-9a-f]{32}$") > 0,
		"the live directory must combine PID with a per-process GUID nonce")
	AssertEqual(LiveDir, _LLM_Ollama_TempDir(),
		"the nonce must remain stable for every artifact owned by this process")
}
Test("LLM curl artifacts: instance nonce prevents PID-reuse adoption (AHK-073)",
	_LCOC_InstanceDirectorySurvivesPidReuse)

_LCOC_RecordSweep(State, *) {
	State["sweeps"] += 1
}

_LCOC_RunCurl(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	Pid := 6262
	ProcessOwner := Map("pid", Pid, "handle", 9262, "released", false)
}

_LCOC_RemoteTransportSchedulesTheCommonReaper() {
	global _LLM_Remote_Async
	ReqId := "ahk2_03_remote_sweep"
	State := Map("sweeps", 0)
	Port := Map(
		"file_exists", (*) => true,
		"temp_dir", (*) => A_Temp,
		"write", (*) => true,
		"delete", (*) => true,
		"run", _LCOC_RunCurl.Bind(State),
		"poll", (*) => true,
		"tick", (*) => 6203,
		"schedule_orphan_sweep", _LCOC_RecordSweep.Bind(State))
	Resolved := Map("Format", "openai", "Token", "secret", "Model", "model")
	try {
		AssertTrue(_LLMRemote_DispatchCurl(ReqId, Resolved,
			"https://safe.invalid/v1", '{"input":"private"}', (*) => 0,
			(*) => 0, 1000, Port))
		AssertEqual(1, State["sweeps"],
			"(ahk2-03-remote-sweep) remote-only curl use must schedule the common crash-artifact reaper exactly once")
	} finally {
		if _LLM_Remote_Async.Has(ReqId)
			_LLM_Remote_Async.Delete(ReqId)
	}
}
Test("LLM curl artifacts: remote-only dispatch schedules common cleanup (ahk2-03-remote-sweep)",
	_LCOC_RemoteTransportSchedulesTheCommonReaper)
