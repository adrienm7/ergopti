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
global _CRWT_ReentrantSpawnState := 0

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

_CRWT_PrivacyCanariesAreRedactedFromCanonicalJson() {
	Canary := "AuditCanary-AHK-008-raw-PII"
	Report := Map()
	for _, Key in _CRWT_RequiredKeys()
		Report[Key] := "safe"
	for _, Key in [
		"error_msg", "error_extra", "error_what", "error_file", "stack_trace",
		"script_dir", "active_window_title", "active_window_process",
		"config_dir", "log_tail"
	]
		Report[Key] := "prefix " . Canary . " suffix"

	Raw := _CrashReport_ToJson(Report)
	AssertFalse(InStr(Raw, Canary) > 0,
		"the canonical crash artifact must never serialize raw diagnostic PII")
	Parsed := JsonParse(Raw)
	for _, Key in _CRWT_RequiredKeys()
		AssertTrue(Parsed.Has(Key),
			"privacy redaction must retain canonical field: " . Key)
}

Test("crash report: canonical JSON redacts every free-text privacy source "
	. "(audit-ahk-008)",
	_CRWT_PrivacyCanariesAreRedactedFromCanonicalJson)

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
	if IsObject(SpawnFn)
		Owner := CrashReportWorker_Start(_CrashReport_ToWorkerJson(Snapshot), Done,
			SpawnFn, _VendorDir . "\ergopti_crash_worker.ps1", ResolvedOptions)
	else
		Owner := CrashReportWorker_Start(_CrashReport_ToWorkerJson(Snapshot), Done,
			, _VendorDir . "\ergopti_crash_worker.ps1", ResolvedOptions)
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
	return State["terminate_result"]
}

_CRWT_ReentrantShutdownSpawn(Executable, Args, Done) {
	global _CrashReportWorkerOwners, _CRWT_ReentrantSpawnState
	for _, Owner in _CrashReportWorkerOwners {
		_CRWT_ReentrantSpawnState["mapping"] := Owner["mapping"]
		break
	}
	_CRWT_ReentrantSpawnState["stop_result"] := CrashReportWorker_StopAll()
	return {
		start: (*) => true,
		terminate: _CRWT_ShutdownTerminate.Bind(_CRWT_ReentrantSpawnState)
	}
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

	OldConfigDir := _ConfigDir
	OldRing := LOGGER_RING_BUFFER
	OldCursor := LOGGER_RING_CURSOR
	Canary := "AuditCanary-AHK-008-worker-PII"
	TestDir := A_Temp . "\" . Canary . "_" . A_TickCount
		. "_" . DllCall("GetCurrentProcessId")

	try {
		DirCreate(TestDir)
		_ConfigDir := TestDir . "\"
		LOGGER_RING_BUFFER := []
		Loop 200
			LOGGER_RING_BUFFER.Push(Canary . "_log_" . A_Index)
		LOGGER_RING_CURSOR := LOGGER_RING_BUFFER.Length

		Snapshot := _CrashReport_CheapSnapshot(Error(Canary . " error"))
		SafeLargeField := "FIRST_SAFE_TRANSPORT_SENTINEL"
		Loop 200
			SafeLargeField .= "_adapter_" . Format("{:0120}", A_Index)
		SafeLargeField .= "_LAST_SAFE_TRANSPORT_SENTINEL"
		Snapshot["adapters_ok"] := SafeLargeField
		Payload := _CrashReport_ToWorkerJson(Snapshot)
		Assert(StrPut(Payload, "UTF-8") - 1 > 8191,
			"the worker regression must still cross the cmd.exe payload ceiling")

		Result := _CRWT_StartAndWait(Snapshot)
		Raw := FileRead(Result["artifact"], "UTF-8")
		AssertContains(Raw, "FIRST_SAFE_TRANSPORT_SENTINEL")
		AssertContains(Raw, "LAST_SAFE_TRANSPORT_SENTINEL")
		AssertFalse(InStr(Raw, Canary) > 0,
			"the isolated worker must remove path, error, and log privacy canaries")

		Report := JsonParse(Raw)
		Required := _CRWT_RequiredKeys()
		Assert(Required.Length >= 37, "the schema oracle must retain the established crash-report field floor")
		for _, Key in Required
			Assert(Report.Has(Key), "isolated crash report missing canonical field: " . Key)
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
		Owner := CrashReportWorker_Start(_CrashReport_ToWorkerJson(Snapshot), Done,
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
	Canary := "AuditCanary-AHK-008-fallback-PII"
	TestDir := A_Temp . "\" . Canary . "_" . A_TickCount
		. "_" . DllCall("GetCurrentProcessId")
	try {
		DirCreate(TestDir)
		_ConfigDir := TestDir . "\"
		_CRWT_FallbackSpawnState := Map("calls", 0)
		Result := _CRWT_StartAndWait(_CrashReport_CheapSnapshot(Error(Canary)),
			Map(), _CRWT_FallbackSpawn)
		AssertEqual(2, _CRWT_FallbackSpawnState["calls"],
			"a refused primary launch must make exactly one isolated fallback attempt")
		AssertFalse(InStr(FileRead(Result["artifact"], "UTF-8"), Canary) > 0,
			"the minimal fallback must remove path and error privacy canaries")
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
			_CrashReport_ToWorkerJson(_CrashReport_CheapSnapshot(Error("exit fallback"))),
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
	_CRWT_ShutdownSpawnState := Map("terminate_calls", 0,
		"terminate_result", false)
	Snapshot := _CrashReport_CheapSnapshot(Error("shutdown"))
	Owner := CrashReportWorker_Start(_CrashReport_ToWorkerJson(Snapshot), (*) => 0,
		_CRWT_ShutdownSpawn, "ignored.ps1")
	Assert(IsObject(Owner), "the fake retained worker must start")
	AssertEqual(1, _CrashReportWorkerOwners.Count, "the worker registry must retain the in-flight mapping")
	Mapping := Owner["mapping"]
	Assert(!Mapping["closed"], "the in-flight mapping must remain open before shutdown")
	AssertFalse(CrashReportWorker_StopAll(),
		"shutdown must refuse an unconfirmed process-tree termination")
	AssertEqual(1, _CrashReportWorkerOwners.Count,
		"failed termination must retain the exact worker and mapping")
	Assert(!Mapping["closed"],
		"failed termination must not close the worker's transport")
	_CRWT_ShutdownSpawnState["terminate_result"] := true
	Assert(CrashReportWorker_StopAll(), "confirmed shutdown cleanup must complete")
	AssertEqual(0, _CrashReportWorkerOwners.Count, "shutdown must retire every worker owner")
	Assert(Mapping["closed"], "shutdown must close the exact retained mapping")
	AssertEqual(2, _CRWT_ShutdownSpawnState["terminate_calls"],
		"shutdown must retry the same exact worker after an unconfirmed receipt")
	Assert(!_CrashReportWorkerCloseMapping(Mapping), "a second mapping cleanup must be an idempotent no-op")
	_CRWT_ShutdownSpawnState := 0
}

_CRWT_ShutdownDuringSpawnCannotOrphanWorker() {
	global _CrashReportWorkerOwners, _CRWT_ReentrantSpawnState
	CrashReportWorker_StopAll()
	_CRWT_ReentrantSpawnState := Map("terminate_calls", 0,
		"terminate_result", true, "stop_result", true, "mapping", 0)
	Snapshot := _CrashReport_CheapSnapshot(Error("spawn race"))
	Owner := CrashReportWorker_Start(_CrashReport_ToWorkerJson(Snapshot), (*) => 0,
		_CRWT_ReentrantShutdownSpawn, "ignored.ps1")
	AssertEqual(0, Owner,
		"a spawn cancelled before publication must not return a live owner")
	AssertFalse(_CRWT_ReentrantSpawnState["stop_result"],
		"shutdown must refuse while spawn still owns an unpublished task")
	AssertEqual(1, _CRWT_ReentrantSpawnState["terminate_calls"],
		"the resumed spawn must quiesce its exact task once cancellation is visible")
	AssertEqual(0, _CrashReportWorkerOwners.Count,
		"the cancelled spawn must retire its registry owner")
	Assert(_CRWT_ReentrantSpawnState["mapping"]["closed"],
		"the cancelled spawn must close its exact mapping after quiescence")
	_CRWT_ReentrantSpawnState := 0
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
Test("error-net: shutdown during spawn cannot orphan a worker (AHK-093)",
	_CRWT_ShutdownDuringSpawnCannotOrphanWorker)





class _CRWT_MappingNative {
	static Events := []
	static FailAt := ""

	static Reset(FailAt := "") {
		this.Events := []
		this.FailAt := FailAt
	}

	static UnmapView(View) {
		this.Events.Push("unmap:" . View)
		return this.FailAt != "unmap"
	}

	static CloseHandle(Handle) {
		this.Events.Push("close:" . Handle)
		return this.FailAt != "close"
	}
}

_CRWT_WithMappingDebtIsolated(TestFn) {
	global _CrashReportWorkerMappingCleanupDebt
	OriginalDebt := _CrashReportWorkerMappingCleanupDebt
	_CrashReportWorkerMappingCleanupDebt := []
	try TestFn.Call()
	finally _CrashReportWorkerMappingCleanupDebt := OriginalDebt
}

_CRWT_TestMapping(View := 0) {
	return Map("name", "Local\test", "handle", 1301, "view", View,
		"bytes", 8, "closed", false, "cleanup_queued", false)
}

_CRWT_JoinMappingEvents() {
	Output := ""
	for Event in _CRWT_MappingNative.Events
		Output .= (Output == "" ? "" : ",") . Event
	return Output
}

_CRWT_CloseRefusalRetainsTheExactHandle() {
	global _CrashReportWorkerMappingCleanupDebt
	_CRWT_MappingNative.Reset("close")
	Mapping := _CRWT_TestMapping()
	AssertFalse(_CrashReportWorkerCloseMapping(Mapping,
		_CRWT_MappingNative))
	AssertFalse(Mapping["closed"],
		"a refused CloseHandle must not publish a false closed state")
	AssertEqual(1301, Mapping["handle"],
		"the exact refused handle must remain owned")
	AssertEqual(1, _CrashReportWorkerMappingCleanupDebt.Length)
	AssertFalse(_CrashReportWorkerCloseMapping(Mapping,
		_CRWT_MappingNative))
	AssertEqual(1, _CrashReportWorkerMappingCleanupDebt.Length,
		"a repeated close must not enqueue the same receipt twice")
	_CRWT_MappingNative.FailAt := ""
	AssertTrue(_CrashReportWorkerDrainMappingDebt(_CRWT_MappingNative))
	AssertTrue(Mapping["closed"])
	AssertEqual(0, Mapping["handle"])
}
Test("crash mapping ownership: refused close retains one exact debt receipt (crash-mapping-cleanup-ownership)",
	_CRWT_WithMappingDebtIsolated.Bind(_CRWT_CloseRefusalRetainsTheExactHandle))

_CRWT_ViewMustUnmapBeforeTheHandleCloses() {
	_CRWT_MappingNative.Reset("unmap")
	Mapping := _CRWT_TestMapping(1302)
	AssertFalse(_CrashReportWorkerCloseMapping(Mapping,
		_CRWT_MappingNative))
	AssertEqual("unmap:1302", _CRWT_JoinMappingEvents(),
		"a live view must block its mapping handle cleanup")
	AssertEqual(1302, Mapping["view"])
	AssertEqual(1301, Mapping["handle"])
	_CRWT_MappingNative.FailAt := ""
	AssertTrue(_CrashReportWorkerDrainMappingDebt(_CRWT_MappingNative))
	AssertEqual("unmap:1302,unmap:1302,close:1301",
		_CRWT_JoinMappingEvents(),
		"retry must unmap the view before closing its dependent handle")
}
Test("crash mapping ownership: view cleanup precedes handle cleanup (crash-mapping-cleanup-ownership)",
	_CRWT_WithMappingDebtIsolated.Bind(_CRWT_ViewMustUnmapBeforeTheHandleCloses))

_CRWT_NewMappingsAndShutdownDrainOldDebt() {
	CreateBody := _DriverFuncBody("_CrashReportWorkerCreateMapping")
	StopBody := _DriverFuncBody("CrashReportWorker_StopAll")
	Assert(InStr(CreateBody, "_CrashReportWorkerDrainMappingDebt") > 0,
		"a new mapping must not allocate while old cleanup debt remains")
	Assert(InStr(StopBody, "_CrashReportWorkerDrainMappingDebt") > 0,
		"terminal teardown must retry retained mapping debt")
}
Test("crash mapping ownership: admission and shutdown drain cleanup debt (crash-mapping-cleanup-ownership)",
	_CRWT_NewMappingsAndShutdownDrainOldDebt)
