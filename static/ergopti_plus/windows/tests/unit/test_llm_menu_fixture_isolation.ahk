; tests/unit/test_llm_menu_fixture_isolation.ahk

; ==============================================================================
; MODULE: LLM Menu Fixture Isolation Tests
; DESCRIPTION:
; Fixture installation owns callback counters and event storage until restore.
; Independent sentinels detect omitted fields without trusting snapshot helpers.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMFI_Roundtrip(Api) {
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	global _LMT_ConfigPath, _LMT_ApiPath, _LMT_ApiRefused
	global _LMT_PrepareResult, _LMT_PrepareCalls, _LMT_PublishCalls, _LMT_Events
	Sentinels := Map("_LMT_WriterResult", false, "_LMT_WriterCalls", 11,
		"_LMT_ApplyCalls", 17, "_LMT_WriterCritical", 23,
		"_LMT_ApplyCritical", 31, "_LMT_LiveAtWrite", "outer-live",
		"_LMT_ConfigPath", "outer-config", "_LMT_ApiPath", "outer-api",
		"_LMT_ApiRefused", true, "_LMT_PrepareResult", false,
		"_LMT_PrepareCalls", 41, "_LMT_PublishCalls", 47,
		"_LMT_Events", ["outer-event"])
	Outer := Map()
	for Name, Sentinel in Sentinels {
		Outer[Name] := %Name%
		%Name% := Sentinel
	}
	Installed := false
	try {
		try {
			Previous := Api ? _LMT_InstallApiFixture() : _LMT_InstallFixture()
			Installed := true
			AssertFalse(_LMT_Events == Sentinels["_LMT_Events"],
				"each fixture must own its event journal before a callback can append")
			AssertEqual(0, _LMT_Events.Length)
			AssertEqual(0, _LMT_ApplyCalls)
			AssertEqual(-1, _LMT_ApplyCritical)
			if Api {
				AssertTrue(FileExist(_LMT_ApiPath) != "")
				AssertFalse(_LMT_ApiRefused)
			}
			AssertTrue(_LMT_Apply(Map()))
			AssertEqual(1, _LMT_ApplyCalls)
			AssertEqual("apply", _LMT_Events[1])
		} finally {
			if Installed {
				if Api
					_LMT_RestoreApiFixture(Previous)
				else
					_LMT_RestoreFixture(Previous)
			}
		}
		for Name, Sentinel in Sentinels {
			AssertEqual(Type(Sentinel), Type(%Name%), Name . " must recover its type")
			AssertTrue(%Name% == Sentinel, Name . " must recover its value or object identity")
		}
		AssertEqual(1, _LMT_Events.Length)
		AssertEqual("outer-event", _LMT_Events[1], "the outer journal must remain untouched")
		if Api
			AssertFalse(DirExist(Previous["dir"]) != "", "the fixture must release its own directory")
	} finally {
		for Name, Value in Outer
			%Name% := Value
	}
}
Test("LLM fixture: menu callbacks restore isolated state (llm-fixture-isolation)",
	_LMFI_Roundtrip.Bind(false))
Test("LLM fixture: API callbacks restore isolated state (llm-fixture-isolation)",
	_LMFI_Roundtrip.Bind(true))

_LMFI_RejectOccupiedDirectory() {
	global ConfigurationFile, _LMT_ApiPath, Features, _LLM_Menu
	First := _LMT_InstallApiFixture()
	try {
		ConfigPath := ConfigurationFile
		ApiPath := _LMT_ApiPath
		ConfigBytes := FSReadUtf8Exact(ConfigPath)
		ApiBytes := FSReadUtf8Exact(ApiPath)
		OuterFeatures := Features
		OuterMenu := _LLM_Menu
		Rejected := false
		Second := 0
		try Second := _LMT_InstallApiFixture(First["dir"])
		catch Error
			Rejected := true
		finally {
			if Second is Map
				_LMT_RestoreApiFixture(Second)
		}
		AssertTrue(Rejected, "an occupied directory must not become a second fixture's property")
		AssertTrue(Features == OuterFeatures)
		AssertTrue(_LLM_Menu == OuterMenu)
		AssertEqual(ConfigPath, ConfigurationFile)
		AssertEqual(ApiPath, _LMT_ApiPath)
		AssertEqual(ConfigBytes, FSReadUtf8Exact(ConfigPath))
		AssertEqual(ApiBytes, FSReadUtf8Exact(ApiPath))
	} finally _LMT_RestoreApiFixture(First)
}
Test("LLM fixture: reject an occupied directory without taking ownership (llm-fixture-directory)",
	_LMFI_RejectOccupiedDirectory)

_LMFI_NestedDirectoriesAreIndependent() {
	First := _LMT_InstallApiFixture()
	try {
		Second := _LMT_InstallApiFixture()
		try {
			AssertFalse(First["dir"] == Second["dir"])
			AssertTrue(DirExist(First["dir"]) != "")
			AssertTrue(DirExist(Second["dir"]) != "")
		} finally _LMT_RestoreApiFixture(Second)
		AssertFalse(DirExist(Second["dir"]) != "")
		AssertTrue(DirExist(First["dir"]) != "")
	} finally _LMT_RestoreApiFixture(First)
	AssertFalse(DirExist(First["dir"]) != "")
}
Test("LLM fixture: nested directories retain independent lifetimes (llm-fixture-directory)",
	_LMFI_NestedDirectoriesAreIndependent)
