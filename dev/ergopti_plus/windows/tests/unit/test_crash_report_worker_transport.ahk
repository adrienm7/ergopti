; tests/unit/test_crash_report_worker_transport.ahk

; ==============================================================================
; MODULE: Crash Report Worker Transport Tests
; DESCRIPTION:
; Exercises the production crash-report handoff with a payload larger than the
; cmd.exe command-line ceiling and verifies that the isolated worker preserves
; the canonical report schema. This prevents a child process from existing only
; on paper while the actual crash snapshot never reaches it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ Transport Integration Helpers =======
; ================================================
; ================================================

global _CRWT_TIMEOUT_MS := 10000
global _CRWT_FallbackSpawnState := 0
global _CRWT_PrimaryExitSpawnState := 0
global _CRWT_ShutdownSpawnState := 0

_CRWT_WaitUntil(Predicate, TimeoutMs := 10000) {
	StartedTick := A_TickCount
	while !Predicate.Call() {
		if TickExpired(StartedTick, TimeoutMs)
			return false
		Sleep(20)
	}
	return true
}

_CRWT_FirstJson(Path) {
	Loop Files Path . "\*.json", "F"
		return A_LoopFileFullPath
	return ""
}

_CRWT_RequiredKeys() {
	return [
		"version", "driver", "timestamp", "error_type", "error_msg",
		"error_extra", "error_what", "error_file", "error_line", "stack_trace",
		"os_name", "os_build", "os_arch", "ahk_version", "ahk_bitness",
		"cpu_name", "cpu_cores", "ram_total_gb", "ram_free_gb",
		"screen_resolution", "dpi", "dpi_scale", "locale", "script_dir",
		"git_hash", "username_hash", "uptime_sec", "active_window_title",
		"active_window_process", "stuck_modifiers", "adapters_ok",
		"adapters_failed", "session_warnings", "session_errors",
		"keylogger_initialized", "config_dir", "log_tail"
	]
}

_CRWT_RecordDone(State, ExitCode, Stdout, Stderr) {
	State["called"] := true
	State["tick"] := A_TickCount
	State["exit_code"] := ExitCode
	State["stdout"] := Stdout
	State["stderr"] := Stderr
}

_CRWT_StartAndWait(Snapshot, Options := 0, SpawnFn := 0) {
	global _VendorDir, _CRWT_TIMEOUT_MS
	State := Map("called", false, "tick", 0, "exit_code", -1, "stdout", "", "stderr", "")
	Done := _CRWT_RecordDone.Bind(State)
	ResolvedOptions := Options is Map ? Options : Map()
	ResolvedSpawn := IsObject(SpawnFn) ? SpawnFn : ShellRunner_Spawn
	Owner := CrashReportWorker_Start(_CrashReport_ToJson(Snapshot), Done,
		ResolvedSpawn, _VendorDir . "\ergopti_crash_worker.ps1", ResolvedOptions)
	Assert(IsObject(Owner), "the crash worker must publish an exact retained owner")
	Assert(_CRWT_WaitUntil(() => State["called"], _CRWT_TIMEOUT_MS),
		"the isolated crash worker must finish within the integration deadline")
	AssertEqual(0, State["exit_code"], "the isolated crash worker must exit successfully: " . State["stderr"])
	Assert(RegExMatch(State["stdout"], "m)^OK:(.+)$", &Match),
		"the isolated crash worker must return its exact artifact path")
	Artifact := Trim(Match[1])
	Assert(FileExist(Artifact), "the isolated crash worker artifact must exist")
	return Map("state", State, "owner", Owner, "artifact", Artifact,
		"report", JsonParse(FileRead(Artifact, "UTF-8")))
}

_CRWT_FallbackSpawn(Executable, Args, Done) {
	global _CRWT_FallbackSpawnState
	_CRWT_FallbackSpawnState["calls"] += 1
	if _CRWT_FallbackSpawnState["calls"] = 1 {
		return {
			start: (*) => false,
			terminate: (*) => true
		}
	}
	return ShellRunner_Spawn(Executable, Args, Done)
}

_CRWT_PrimaryExitSpawn(Executable, Args, Done) {
	global _CRWT_PrimaryExitSpawnState
	_CRWT_PrimaryExitSpawnState["calls"] += 1
	if _CRWT_PrimaryExitSpawnState["calls"] = 1 {
		_CRWT_PrimaryExitSpawnState["primary_done"] := Done
		return {
			start: (*) => true,
			terminate: (*) => true
		}
	}
	return ShellRunner_Spawn(Executable, Args, Done)
}

_CRWT_ShutdownTerminate(State, *) {
	State["terminate_calls"] += 1
	return true
}

_CRWT_ShutdownSpawn(Executable, Args, Done) {
	global _CRWT_ShutdownSpawnState
	return {
		start: (*) => true,
		terminate: _CRWT_ShutdownTerminate.Bind(_CRWT_ShutdownSpawnState)
	}
}





; =====================================================
; =====================================================
; ======= 2/ Large Snapshot Reaches Real Worker =======
; =====================================================
; =====================================================

_CRWT_LargeSnapshotCrossesProcessBoundary() {
	global _ConfigDir, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
	global _CrashReportWorkerOwners, _CRWT_TIMEOUT_MS

	OldConfigDir := _ConfigDir
	OldRing := LOGGER_RING_BUFFER
	OldCursor := LOGGER_RING_CURSOR
	TestDir := A_Temp . "\ergopti_crash_worker_" . A_TickCount . "_" . DllCall("GetCurrentProcessId")
	ReportDir := TestDir . "\autohotkey\crash_reports"
	ReleaseCount := 0
	ReleaseDedup(*) => ReleaseCount += 1

	try {
		DirCreate(TestDir)
		_ConfigDir := TestDir . "\"
		LOGGER_RING_BUFFER := []
		Loop 200 {
			Marker := A_Index = 1 ? "FIRST_SENTINEL" : (A_Index = 200 ? "LAST_SENTINEL" : "MIDDLE")
			LOGGER_RING_BUFFER.Push(Marker . "_" . A_Index . "_" . Format("{:0120}", A_Index))
		}
		LOGGER_RING_CURSOR := LOGGER_RING_BUFFER.Length

		_ErgoptiDeferredCrashReport(Error("AHK-005 large payload"), ReleaseDedup)
		Finished := _CRWT_WaitUntil(() => _CrashReportWorkerOwners.Count = 0, _CRWT_TIMEOUT_MS)
		Assert(Finished, "crash worker must reach a terminal callback within the bounded integration deadline")

		Artifact := _CRWT_FirstJson(ReportDir)
		Assert(Artifact != "", "the production crash worker must write a report for a payload larger than cmd.exe's 8191-character ceiling")
		Raw := FileRead(Artifact, "UTF-8")
		Assert(InStr(Raw, "FIRST_SENTINEL") > 0, "the worker artifact must preserve the first large-payload sentinel")
		Assert(InStr(Raw, "LAST_SENTINEL") > 0, "the worker artifact must preserve the last large-payload sentinel")

		Report := JsonParse(Raw)
		Required := _CRWT_RequiredKeys()
		Assert(Required.Length >= 37, "the schema oracle must retain the established crash-report field floor")
		for _, Key in Required
			Assert(Report.Has(Key), "isolated crash report missing canonical field: " . Key)
		AssertEqual(0, ReleaseCount, "a successful worker write must retain the dedup claim")
	} finally {
		_ConfigDir := OldConfigDir
		LOGGER_RING_BUFFER := OldRing
		LOGGER_RING_CURSOR := OldCursor
		try DirDelete(TestDir, true)
	}
}

Test("error-net: large snapshot crosses the isolated worker with canonical schema (ahk-005-crash-worker-transport)",
	_CRWT_LargeSnapshotCrossesProcessBoundary)





; ==========================================================
; ==========================================================
; ======= 3/ Isolation, Degradation, and Teardown ==========
; ==========================================================
; ==========================================================

_CRWT_DelayedWorkerDoesNotBlockParent() {
	global _ConfigDir, _VendorDir
	OldConfigDir := _ConfigDir
	TestDir := A_Temp . "\ergopti_crash_delay_" . A_TickCount . "_" . DllCall("GetCurrentProcessId")
	try {
		DirCreate(TestDir)
		_ConfigDir := TestDir . "\"
		Snapshot := _CrashReport_CheapSnapshot(Error("delayed worker"))
		State := Map("called", false, "tick", 0, "exit_code", -1, "stdout", "", "stderr", "")
		Done := _CRWT_RecordDone.Bind(State)
		Owner := CrashReportWorker_Start(_CrashReport_ToJson(Snapshot), Done,
			ShellRunner_Spawn, _VendorDir . "\ergopti_crash_worker.ps1", Map("delay_ms", 500))
		Assert(IsObject(Owner), "the delayed crash worker must start")
		SecondCallbackTick := A_TickCount
		Assert(!State["called"], "a second parent callback must run before the delayed worker completes")
		Assert(_CRWT_WaitUntil(() => State["called"], 10000), "the delayed worker must eventually complete")
		Assert(SecondCallbackTick <= State["tick"], "the parent callback must precede the worker terminal callback")
		AssertEqual(0, State["exit_code"], "the delayed worker must still exit successfully")
	} finally {
		_ConfigDir := OldConfigDir
		try DirDelete(TestDir, true)
	}
}

_CRWT_IndependentEnrichmentFaultsStillWrite() {
	global _ConfigDir
	OldConfigDir := _ConfigDir
	TestDir := A_Temp . "\ergopti_crash_faults_" . A_TickCount . "_" . DllCall("GetCurrentProcessId")
	try {
		DirCreate(TestDir)
		_ConfigDir := TestDir . "\"
		for _, Fault in ["os", "cpu"] {
			Snapshot := _CrashReport_CheapSnapshot(Error("fault " . Fault))
			Result := _CRWT_StartAndWait(Snapshot, Map("faults", Fault))
			for _, Key in _CRWT_RequiredKeys()
				Assert(Result["report"].Has(Key), "fault '" . Fault . "' must preserve canonical field: " . Key)
			Assert(Result["report"].Has("enrichment_errors"),
				"each degraded enrichment must identify its failure in the artifact")
			Errors := _CrashReport_JoinArr(Result["report"]["enrichment_errors"])
			Assert(InStr(Errors, Fault . ":") > 0,
				"the artifact must name the independently failed enrichment: " . Fault)
		}
	} finally {
		_ConfigDir := OldConfigDir
		try DirDelete(TestDir, true)
	}
}

_CRWT_PrimaryStartRefusalUsesMinimalWorker() {
	global _ConfigDir, _CRWT_FallbackSpawnState
	OldConfigDir := _ConfigDir
	TestDir := A_Temp . "\ergopti_crash_fallback_" . A_TickCount . "_" . DllCall("GetCurrentProcessId")
	try {
		DirCreate(TestDir)
		_ConfigDir := TestDir . "\"
		_CRWT_FallbackSpawnState := Map("calls", 0)
		Result := _CRWT_StartAndWait(_CrashReport_CheapSnapshot(Error("fallback")),
			Map(), _CRWT_FallbackSpawn)
		AssertEqual(2, _CRWT_FallbackSpawnState["calls"],
			"a refused primary launch must make exactly one isolated fallback attempt")
		for _, Key in _CRWT_RequiredKeys()
			Assert(Result["report"].Has(Key), "the minimal fallback must preserve canonical field: " . Key)
	} finally {
		_ConfigDir := OldConfigDir
		_CRWT_FallbackSpawnState := 0
		try DirDelete(TestDir, true)
	}
}

_CRWT_PrimaryExitFailureUsesMinimalWorker() {
	global _ConfigDir, _VendorDir, _CRWT_PrimaryExitSpawnState, _CRWT_TIMEOUT_MS
	OldConfigDir := _ConfigDir
	TestDir := A_Temp . "\ergopti_crash_exit_fallback_" . A_TickCount . "_" . DllCall("GetCurrentProcessId")
	try {
		DirCreate(TestDir)
		_ConfigDir := TestDir . "\"
		_CRWT_PrimaryExitSpawnState := Map("calls", 0, "primary_done", 0)
		State := Map("called", false, "tick", 0, "exit_code", -1, "stdout", "", "stderr", "")
		Owner := CrashReportWorker_Start(
			_CrashReport_ToJson(_CrashReport_CheapSnapshot(Error("exit fallback"))),
			_CRWT_RecordDone.Bind(State), _CRWT_PrimaryExitSpawn,
			_VendorDir . "\ergopti_crash_worker.ps1")
		Assert(IsObject(Owner), "the retained primary worker must start before its terminal failure")
		Assert(HasMethod(_CRWT_PrimaryExitSpawnState["primary_done"], "Call"),
			"the fake primary process must retain its real terminal callback")
		_CRWT_PrimaryExitSpawnState["primary_done"].Call(7, "", "injected primary failure")
		Assert(_CRWT_WaitUntil(() => State["called"], _CRWT_TIMEOUT_MS),
			"a failed primary process must reach the isolated fallback terminal callback")
		AssertEqual(2, _CRWT_PrimaryExitSpawnState["calls"],
			"a failed primary process must make exactly one isolated fallback attempt")
		AssertEqual(0, State["exit_code"],
			"a primary runtime failure must still preserve a minimal crash artifact: " . State["stderr"])
		Assert(RegExMatch(State["stdout"], "m)^OK:(.+)$", &Match),
			"the fallback after a primary runtime failure must return its exact artifact path")
		Report := JsonParse(FileRead(Trim(Match[1]), "UTF-8"))
		for _, Key in _CRWT_RequiredKeys()
			Assert(Report.Has(Key), "the runtime-failure fallback must preserve canonical field: " . Key)
	} finally {
		_ConfigDir := OldConfigDir
		_CRWT_PrimaryExitSpawnState := 0
		try DirDelete(TestDir, true)
	}
}

_CRWT_ShutdownClosesExactMappingOnce() {
	global _CrashReportWorkerOwners, _CRWT_ShutdownSpawnState
	CrashReportWorker_StopAll()
	_CRWT_ShutdownSpawnState := Map("terminate_calls", 0)
	Snapshot := _CrashReport_CheapSnapshot(Error("shutdown"))
	Owner := CrashReportWorker_Start(_CrashReport_ToJson(Snapshot), (*) => 0,
		_CRWT_ShutdownSpawn, "ignored.ps1")
	Assert(IsObject(Owner), "the fake retained worker must start")
	AssertEqual(1, _CrashReportWorkerOwners.Count, "the worker registry must retain the in-flight mapping")
	Mapping := Owner["mapping"]
	Assert(!Mapping["closed"], "the in-flight mapping must remain open before shutdown")
	Assert(CrashReportWorker_StopAll(), "shutdown cleanup must complete")
	AssertEqual(0, _CrashReportWorkerOwners.Count, "shutdown must retire every worker owner")
	Assert(Mapping["closed"], "shutdown must close the exact retained mapping")
	AssertEqual(1, _CRWT_ShutdownSpawnState["terminate_calls"], "shutdown must terminate the exact worker once")
	Assert(!_CrashReportWorkerCloseMapping(Mapping), "a second mapping cleanup must be an idempotent no-op")
	_CRWT_ShutdownSpawnState := 0
}

Test("error-net: delayed worker leaves the parent callback responsive (ahk-005-crash-worker-isolation)",
	_CRWT_DelayedWorkerDoesNotBlockParent)
Test("error-net: independent CIM failures retain a minimal report (ahk-005-crash-worker-degradation)",
	_CRWT_IndependentEnrichmentFaultsStillWrite)
Test("error-net: primary start refusal uses the isolated minimal fallback (ahk-005-crash-worker-fallback)",
	_CRWT_PrimaryStartRefusalUsesMinimalWorker)
Test("error-net: primary runtime failure uses the isolated minimal fallback (ahk-005-crash-worker-exit-fallback)",
	_CRWT_PrimaryExitFailureUsesMinimalWorker)
Test("error-net: shutdown closes each retained mapping exactly once (ahk-005-crash-worker-shutdown)",
	_CRWT_ShutdownClosesExactMappingOnce)
