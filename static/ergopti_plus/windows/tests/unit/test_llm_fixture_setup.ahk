; tests/unit/test_llm_fixture_setup.ahk

; ==============================================================================
; MODULE: LLM Fixture Setup Failure Tests
; DESCRIPTION:
; Failed initial file creation must not publish a usable fixture or leak its
; directory and globals. The other writes use the real durable file adapter.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMFS_Write(State, FailAt, Throws, Path, Content) {
	State["paths"].Push(Path)
	SplitPath(Path, , &Dir)
	State["dir"] := Dir
	if State["paths"].Length == FailAt {
		if FailAt == 2
			AssertEqual('[llm]`nenabled = false`napi_entry_id = "api_old"`n',
				FSReadUtf8Exact(State["paths"][1]))
		if Throws
			throw Error("Injected fixture write exception")
		return 0
	}
	return FSWriteCreateDurable(Path, Content)
}

_LMFS_FailedSetup(FailAt, Throws) {
	global Features, _LLM_Menu, ConfigurationFile, _PathsFile
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	global _LMT_ConfigPath, _LMT_ApiPath, _LMT_ApiRefused
	global _LMT_PrepareResult, _LMT_PrepareCalls, _LMT_PublishCalls, _LMT_Events
	Expected := Map("Features", Features, "_LLM_Menu", _LLM_Menu,
		"ConfigurationFile", ConfigurationFile, "_PathsFile", _PathsFile,
		"_LMT_WriterResult", false, "_LMT_WriterCalls", 11,
		"_LMT_ApplyCalls", 17, "_LMT_WriterCritical", 23,
		"_LMT_ApplyCritical", 31, "_LMT_LiveAtWrite", "outer-live",
		"_LMT_ConfigPath", "outer-config", "_LMT_ApiPath", "outer-api",
		"_LMT_ApiRefused", true, "_LMT_PrepareResult", false,
		"_LMT_PrepareCalls", 41, "_LMT_PublishCalls", 47,
		"_LMT_Events", ["outer-event"])
	Outer := Map()
	for Name, Sentinel in Expected {
		Outer[Name] := %Name%
		%Name% := Sentinel
	}
	State := Map("paths", [], "dir", "")
	Failure := ""
	try {
		try _LMT_InstallApiFixture("", _LMFS_Write.Bind(State, FailAt, Throws))
		catch Error as Err
			Failure := Err.Message
		AssertTrue(Failure != "", "a failed initial write must reject fixture installation")
		AssertEqual(FailAt, State["paths"].Length, "setup must stop at the failed write")
		if Throws
			AssertEqual("Injected fixture write exception", Failure)
		else
			AssertContains(Failure, State["paths"][FailAt])
		for Name, Sentinel in Expected {
			AssertEqual(Type(Sentinel), Type(%Name%), Name . " must recover its type")
			AssertTrue(%Name% == Sentinel, Name . " must recover its value or identity")
		}
		AssertEqual(1, _LMT_Events.Length)
		AssertEqual("outer-event", _LMT_Events[1])
		AssertTrue(State["dir"] != "", "the failure must follow real directory acquisition")
		AssertFalse(DirExist(State["dir"]) != "", "failed setup must release its owned directory")
	} finally {
		for Name, Value in Outer
			%Name% := Value
		; Baseline reproductions may leak only this freshly acquired test directory.
		if State["dir"] != "" && DirExist(State["dir"]) {
			AssertTrue(InStr(State["dir"], A_Temp . "\ergopti-llm-api-transaction-") == 1)
			DirDelete(State["dir"], true)
		}
	}
}
Test("LLM fixture setup: first write refusal rolls back (llm-fixture-setup)",
	_LMFS_FailedSetup.Bind(1, false))
Test("LLM fixture setup: second write refusal rolls back (llm-fixture-setup)",
	_LMFS_FailedSetup.Bind(2, false))
Test("LLM fixture setup: first write exception rolls back (llm-fixture-setup)",
	_LMFS_FailedSetup.Bind(1, true))
Test("LLM fixture setup: second write exception rolls back (llm-fixture-setup)",
	_LMFS_FailedSetup.Bind(2, true))
