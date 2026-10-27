; tests/unit/infra/lifecycle/test_llm_persistence_runner.ahk

; The main registry can resolve dependencies accidentally omitted by the smaller
; entry. Execute that entry in a separate native process, with its whole registry
; and a private UTF-8 TAP receipt, so parse aborts cannot masquerade as coverage.
#Include ../../../support/llm_persistence_runner_contract.ahk

_LPR_RunCanonicalEntry() {
	global TEST_REGISTRY, LLM_PERSISTENCE_RUNNER_TIMEOUT_MS
	Expected := Map()
	for Entry in TEST_REGISTRY {
		SplitPath(Entry.file, &FileName)
		if FileName == "test_llm_menu_persistence.ahk" || FileName == "test_llm_menu_regressions.ahk"
			Expected[Entry.name] := true
	}
	AssertTrue(Expected.Count > 0, "the real isolated source registries must be registered")
	Path := A_Temp . "\ergopti_llm_runner_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . ".tap"
	Receipt := { Calls: 0, Code: -1, Output: "", Errors: "" }
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", A_ScriptDir . "\run_llm_menu_persistence.ahk"], OnDone)
	try {
		; Native creation captures the environment synchronously. Restore the parent
		; receipt before yielding to any timer or callback in the main runner.
		PreviousCritical := Critical("On")
		PreviousPath := EnvGet("ERGOPTI_AHK_RESULTS_FILE")
		try {
			EnvSet("ERGOPTI_AHK_RESULTS_FILE", Path)
			AssertTrue(Handle.start(), "the real isolated AI persistence entry must start")
		} finally {
			EnvSet("ERGOPTI_AHK_RESULTS_FILE", PreviousPath)
			Critical(PreviousCritical)
		}
		Started := A_TickCount
		while !Receipt.Calls && TickElapsed64(Started, A_TickCount) < LLM_PERSISTENCE_RUNNER_TIMEOUT_MS {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipt.Calls, "the actual isolated entry must settle once before its deadline")
		AssertEqual(0, Receipt.Code, "isolated startup and every callback must succeed: " . Receipt.Output . Receipt.Errors)
		AssertEqual("", Receipt.Errors, "isolated startup must not hide a native error")
		Text := StrReplace(FileRead(Path, "UTF-8"), "`r")
		Seen := Map(), PlanCount := -1
		for Line in StrSplit(Text, "`n") {
			if RegExMatch(Line, "^1\.\.([0-9]+)$", &Match)
				PlanCount := Integer(Match[1])
			if !RegExMatch(Line, "^ok ([0-9]+) - (.*)$", &Match)
				continue
			AssertEqual(Seen.Count + 1, Integer(Match[1]), "every isolated callback must publish in order")
			AssertTrue(Expected.Has(Match[2]), "the receipt must identify an actual isolated callback: " . Match[2])
			AssertFalse(Seen.Has(Match[2]), "an isolated callback must not be duplicated")
			Seen[Match[2]] := true
		}
		AssertEqual(Expected.Count, PlanCount, "the full isolated registry must be planned")
		AssertEqual(Expected.Count, Seen.Count, "every real isolated callback must execute successfully")
		AssertTrue(InStr(Text, "# " . Expected.Count . " passed, 0 failed."), "the complete isolated footer must be successful")
	} finally {
		AssertTrue(Handle.terminate(), "the isolated process tree must retire")
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("AI persistence dedicated runner: the full native registry completes (llm-persistence-runner)",
	_LPR_RunCanonicalEntry)
