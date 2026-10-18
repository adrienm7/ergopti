; tests/unit/modules/llm/menu/test_llm_menu_privacy.ahk

; ==============================================================================
; MODULE: LLM Menu Privacy Settings
; DESCRIPTION:
; The privacy booleans publish through the exact native source lease and
; refuse stale masters, pause and malformed intents.
; ==============================================================================

#Requires AutoHotkey v2.0





/** Reads independently authored privacy states and native identities. */
_LMT_PrivacyCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\privacy_trigger_controls.json"))
}

_LMT_PrivacyFixture(States, Body) {
	global _LLM_Menu, _LLM_Engine, Features, ConfigurationFile
	PreviousEngine := _LLM_Engine
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	Dir := A_Temp . "\ergopti_privacy_" . A_TickCount . "_" . Random(10000, 99999)
	DirCreate(Dir)
	try {
		Suspend(false)
		ConfigurationFile := Dir . "\config.toml"
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		_LLM_Menu["disable_url_bars"] := States[1]
		_LLM_Menu["disable_password_fields"] := States[2]
		Features["llm"]["trigger"]["url_bar_filter_enabled"] := States[1]
		Features["llm"]["trigger"]["secure_filter_enabled"] := States[2]
		_LLM_Engine := Map("enabled", true, "backend", "ollama",
			"disable_url_bars", States[1], "disable_password_fields", States[2])
		Image := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n# independent native privacy fixture`n[llm]`nenabled = true`n[llm.models]`n"
			. 'selected = "ollama"' . "`n[llm.trigger]`nurl_bar_filter_enabled = "
			. (States[1] ? "true" : "false") . "`nsecure_filter_enabled = "
			. (States[2] ? "true" : "false") . "`n[foreign]`n"
			. 'future = "keep exact" # retained neighbour' . "`n"
		FileAppend(Image, ConfigurationFile, "UTF-8-RAW")
		AssertEqual("current", ConfigMigrateBoot(ConfigurationFile)["status"], "the actual current privacy fixture constructs before native writes")
		Body.Call()
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		_LMT_RestoreFixture(Previous)
		DirDelete(Dir, true)
	}
}

_LMT_PrivacyPhysicalWrite(Expected, Path, Updates, Content, Presence) {
	global _LMT_WriterResult, _LMT_WriterCalls
	_LMT_WriterCalls += 1
	if _LMT_WriterResult is String && _LMT_WriterResult == "source race" {
		Foreign := StrReplace(Content, '"keep exact"', '"foreign preserved"')
		Expected["observation"]["source_race_changed"] := Foreign != Content
		FileDelete(Path)
		FileAppend(Foreign, Path, "UTF-8-RAW")
	} else if !((_LMT_WriterResult is Integer) && _LMT_WriterResult == 1) {
		return _LMT_WriterResult
	}
	return TOML_ConfigBatchWrite(Path, Updates, [], 0, Content, Presence)
}

_LMT_PrivacyLeaseWrite(Expected, Key, Path, Updates) {
	return _LLM_Menu_PrivacyWrite(Expected, Key, Path, Updates, _LMT_PrivacyPhysicalWrite.Bind(Expected))
}

_LMT_PrivacyApply(Candidate) {
	global _LLM_Engine
	_LLM_Engine["disable_url_bars"] := Candidate["disable_url_bars"]
	_LLM_Engine["disable_password_fields"] := Candidate["disable_password_fields"]
	return _LMT_Apply(Candidate)
}

_LMT_PrivacyCollect(Key, CandidateFeatures, CandidateMenu) {
	NativeKey := Key == "disable_url_bars" ? "url_bar_filter_enabled" : "secure_filter_enabled"
	Owned := ManifestValuesEqual(CandidateMenu[Key], ManifestDefaultFor("llm.trigger." . NativeKey))
		? {Section: "llm.trigger", Key: NativeKey, Delete: true}
		: {Section: "llm.trigger", Key: NativeKey, Value: TOML_Bool(CandidateMenu[Key])}
	return [Owned, {Section: "foreign", Key: "future", Value: "must not publish"}]
}

_LMT_PrivacyRequest(Observed, Key, Value, Expected) {
	Expected["observation"] := Observed
	return LLM_Menu_CommitMutation("the native privacy fixture",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, Key, Value),
		_LMT_PrivacyApply, _LMT_PrivacyLeaseWrite.Bind(Expected, Key), _LMT_Notify,
		_LMT_Acquire, _LMT_Settle, _LMT_PrivacyCollect.Bind(Key))
}

_LMT_PrivacyBuilder(Observed := 0) {
	Observed := Observed is Map ? Observed : Map()
	Command := _LMT_PrivacyRequest.Bind(Observed)
	return LLM_Menu_BuildTriggerMenu(_LMT_TriggerToggle.Bind("instant_on_word_end"),
		_LMT_TriggerToggle.Bind("after_hotstring"), Map("disable_url_bars", Command,
			"disable_password_fields", Command))
}

_LMT_PrivacyReplayBody(Expected, Selected, Neighbor, NeighborSelected) {
	global _LLM_Menu, _LLM_Engine, _LMT_WriterCalls, _LMT_ApplyCalls, ConfigurationFile
	Built := _LMT_PrivacyBuilder()
	try {
		Position := _LMT_ShowAllPosition(Built, t(Expected["i18n"]))
		AssertEqual(Selected, _CTC_IsChecked(Built, Position))
		Callback := _LMT_InfoBarCallback(Built, Position)
		AssertTrue(Callback.Call())
		AssertEqual(!Selected, _LLM_Menu[Expected["ahk"]])
		AssertEqual(!Selected, _LLM_Engine[Expected["ahk"]])
		AssertEqual(NeighborSelected, _LLM_Menu[Neighbor["ahk"]])
		Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		Actual := _TOML_DocumentLookup(Document, StrSplit(Expected["path"], "."))
		if (!Selected) == Expected["neutral"] {
			AssertFalse(Actual["found"])
		} else {
			AssertTrue(Actual["value"] is TOML_Bool)
			AssertEqual(!Selected, Actual["value"].Value)
		}
		AssertContains(FSReadUtf8Exact(ConfigurationFile), 'future = "keep exact" # retained neighbour')
		AssertEqual(1, _LMT_WriterCalls)
		AssertEqual(1, _LMT_ApplyCalls)
		AssertFalse(Callback.Call())
		AssertEqual(1, _LMT_WriterCalls)
	} finally _CTC_ReleaseMenu(Built)
}

_LMT_SharedPrivacyReplay() {
	Corpus := _LMT_PrivacyCorpus()
	AssertEqual(4, Corpus["states"].Length)
	for States in Corpus["states"] {
		for Index, Expected in Corpus["rows"] {
			Other := Index == 1 ? 2 : 1
			_LMT_PrivacyFixture(States, _LMT_PrivacyReplayBody.Bind(Expected, States[Index], Corpus["rows"][Other], States[Other]))
		}
	}
}
Test("LLM privacy: shared independent bools publish through exact native source lease", _LMT_SharedPrivacyReplay)

_LMT_PrivacyRefusalBody(Expected, Condition) {
	global _LLM_Menu, _LLM_Engine, _LMT_WriterCalls, _LMT_ApplyCalls, _LMT_WriterResult, ConfigurationFile
	Observed := Map()
	Built := _LMT_PrivacyBuilder(Observed)
	try {
		Position := _LMT_ShowAllPosition(Built, t(Expected["i18n"]))
		Callback := _LMT_InfoBarCallback(Built, Position)
		Before := FSReadUtf8Exact(ConfigurationFile)
		if Condition == "paused"
			Suspend(true)
		if Condition == "master withdrawn" {
			_LLM_Menu["enabled"] := false
			_LLM_Engine["enabled"] := false
		}
		if Condition == "missing runtime" {
			_LLM_Engine := Map()
		}
		if Condition == "runtime disagreement"
			_LLM_Engine[Expected["ahk"]] := true
		if Condition == "foreign source" {
			FileAppend("# independently retained foreign edit`n", ConfigurationFile, "UTF-8-RAW")
			Before := FSReadUtf8Exact(ConfigurationFile)
		}
		if Condition == "writer refused"
			_LMT_WriterResult := false
		if Condition == "writer source race"
			_LMT_WriterResult := "source race"
		AssertFalse(Callback.Call())
		AssertEqual(false, _LLM_Menu[Expected["ahk"]])
		if Condition == "writer source race" {
			AssertTrue(Observed.Get("source_race_changed", false),
				"the actual terminal writer must create a real different source before canonical reading")
			AssertEqual(StrReplace(Before, '"keep exact"', '"foreign preserved"'), FSReadUtf8Exact(ConfigurationFile))
		} else {
			AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile))
		}
		AssertEqual(Condition == "writer refused" || Condition == "writer source race" ? 1 : 0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally _CTC_ReleaseMenu(Built)
}

_LMT_SharedPrivacyRefusal() {
	for Expected in _LMT_PrivacyCorpus()["rows"] {
		for Condition in ["paused", "master withdrawn", "missing runtime", "runtime disagreement", "foreign source", "writer refused", "writer source race"]
			_LMT_PrivacyFixture([false, false], _LMT_PrivacyRefusalBody.Bind(Expected, Condition))
	}
}
Test("LLM privacy: retained callbacks refuse stale masters pause source runtime and native writer", _LMT_SharedPrivacyRefusal)


_LMT_SharedPrivacyPolicy() {
	Corpus := _LMT_PrivacyCorpus()
	for Vector in Corpus["vectors"] {
		Expected := Corpus["snapshot"].Clone()
		Expected["owner"] := Map()
		Current := Expected.Clone()
		for Key, Value in Vector.Get("current", Map())
			Current[Key] := Value
		for Key in Vector.Get("missing", [])
			Current.Delete(Key)
		if Vector.Get("new_owner", false)
			Current["owner"] := Map()
		Actual := LLM_TriggerPrivacyIntent(Expected, Current)
		AssertEqual(Vector["admitted"], Actual["admitted"], Vector["name"])
		if Vector.Has("value")
			AssertEqual(Vector["value"], Actual["value"], Vector["name"])
		else
			AssertFalse(Actual.Has("value"), Vector["name"])
	}
}
Test("LLM privacy: shared strict source intent rejects malformed booleans and identities", _LMT_SharedPrivacyPolicy)
