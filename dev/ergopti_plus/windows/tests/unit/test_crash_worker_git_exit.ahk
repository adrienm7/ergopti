; tests/unit/test_crash_worker_git_exit.ahk

; ==============================================================================
; MODULE: Crash Worker Native Git Exit Tests
; DESCRIPTION:
; A real command can fail without stderr or a PowerShell exception. The crash
; artifact must retain that failure instead of silently blessing missing data.
; ==============================================================================

#Requires AutoHotkey v2.0

_CRWG_NativeGitRefusalIsReported() {
	global _ConfigDir
	OldConfigDir := _ConfigDir
	Scope := _CRWF_Fixture("git-exit")
	Failure := 0
	try {
		_ConfigDir := Scope.Directory . "\"
		Snapshot := _CrashReport_CheapSnapshot(Error("native Git refusal"))
		Snapshot["git_hash"] := "PREEXISTING_HASH"
		State := Map("called", false, "tick", 0, "exit_code", -1, "stdout", "", "stderr", "")
		Owner := Scope.Start(_CrashReport_ToWorkerJson(Snapshot), _CRWT_RecordDone.Bind(State),
			_CrashReportWorkerSpawnOwned, A_ScriptDir . "\support\crash_git_refusal.ps1",
			Map("faults", "os,cpu"))
		AssertTrue(IsObject(Owner), "the fixture must launch an owned production worker")
		AssertTrue(_CRWT_WaitUntil(() => State["called"], _CRWT_TIMEOUT_MS),
			"the Git refusal must still produce a terminal report")
		AssertEqual(0, State["exit_code"], State["stderr"])
		AssertEqual("primary", Owner["phase"], "a minimal fallback cannot prove enrichment handling")
		AssertEqual(1, Scope.Tasks.Count, "only the primary worker must have run")
		AssertTrue(Owner["mapping"]["closed"], "completion must release the snapshot mapping")
		AssertTrue(RegExMatch(State["stdout"], "m)^OK:(.+)$", &Match),
			"the production worker must publish its exact artifact receipt")
		Report := JsonParse(FileRead(Trim(Match[1]), "UTF-8"))
		for Key in _CRWT_RequiredKeys()
			AssertTrue(Report.Has(Key), "a Git refusal must preserve canonical field: " . Key)
		AssertEqual("PREEXISTING_HASH", Report["git_hash"], "failed output must not replace snapshot data")
		Errors := _CrashReport_JoinArr(Report["enrichment_errors"])
		AssertContains(Errors, "git: Git enrichment exited with code 128.",
			"native Git failure without stderr must remain diagnosable; observed: " . Errors)
	} catch Error as Caught {
		Failure := Caught
		throw Caught
	} finally {
		_ConfigDir := OldConfigDir
		Scope.Finish(Failure)
	}
}
Test("crash worker: native Git refusal is retained in the report (crash-native-git-exit)",
	_CRWG_NativeGitRefusalIsReported)
