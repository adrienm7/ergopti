; tests/unit/test_llm_semantic_config_budget.ahk

; ==============================================================================
; MODULE: LLM Semantic Configuration Budget Tests
; DESCRIPTION:
; Proves that untrusted option graphs are bounded before publication and that
; unchanged prediction fires never rebuild the complete canonical graph.
; ==============================================================================

#Requires AutoHotkey v2.0

_LSCB_Repeat(Text, Count) {
	Out := ""
	Loop Count
		Out .= Text
	return Out
}

_LSCB_NumberedStrings(Count, PayloadChars := 0) {
	Out := []
	Payload := _LSCB_Repeat("x", PayloadChars)
	Loop Count
		Out.Push(A_Index . Payload)
	return Out
}

_LSCB_UserProfiles(Count, PayloadChars := 0) {
	Out := []
	Payload := _LSCB_Repeat("p", PayloadChars)
	Loop Count
		Out.Push(Map(
			"id", "profile-" . A_Index,
			"label", "Profile " . A_Index,
			"raw_prompt", Payload,
			"batch", false))
	return Out
}

_LSCB_ApiEntries(Count, PayloadChars := 0) {
	Out := []
	Payload := _LSCB_Repeat("t", PayloadChars)
	Loop Count
		Out.Push(Map(
			"Id", "entry-" . A_Index,
			"Name", "Entry " . A_Index,
			"Provider", "openai",
			"BaseUrl", "https://example.invalid/v1",
			"Token", Payload,
			"Model", "model"))
	return Out
}

_LSCB_Overrides(Count, PayloadChars := 0) {
	Out := Map()
	Payload := _LSCB_Repeat("a", PayloadChars)
	Loop Count
		Out["app-" . A_Index . Payload] := "basic"
	return Out
}

_LSCB_DocumentedBudgetsRejectOversizeValues() {
	global LLM_OPTION_MAX_SCALAR_CHARS, LLM_OPTION_MAX_COLLECTION_ITEMS,
		LLM_OPTION_MAX_PROFILE_ITEMS, LLM_OPTION_MAX_API_ENTRIES,
		LLM_OPTION_MAX_RECORD_FIELDS, LLM_OPTION_MAX_STOP_SEQUENCES,
		LLM_OPTION_MAX_AGGREGATE_CHARS
	AssertEqual(65536, LLM_OPTION_MAX_SCALAR_CHARS)
	AssertEqual(512, LLM_OPTION_MAX_COLLECTION_ITEMS)
	AssertEqual(64, LLM_OPTION_MAX_PROFILE_ITEMS)
	AssertEqual(64, LLM_OPTION_MAX_API_ENTRIES)
	AssertEqual(32, LLM_OPTION_MAX_RECORD_FIELDS)
	AssertEqual(64, LLM_OPTION_MAX_STOP_SEQUENCES)
	AssertEqual(1048576, LLM_OPTION_MAX_AGGREGATE_CHARS)

	Cases := [
		["model", _LSCB_Repeat("m", LLM_OPTION_MAX_SCALAR_CHARS + 1)],
		["disabled_apps", _LSCB_NumberedStrings(LLM_OPTION_MAX_COLLECTION_ITEMS + 1)],
		["disabled_apps", _LSCB_NumberedStrings(18, 60000)],
		["user_profiles", _LSCB_UserProfiles(LLM_OPTION_MAX_PROFILE_ITEMS + 1)],
		["user_profiles", _LSCB_UserProfiles(17, LLM_OPTION_MAX_SCALAR_CHARS)],
		["api_entries", _LSCB_ApiEntries(LLM_OPTION_MAX_API_ENTRIES + 1)],
		["api_entries", _LSCB_ApiEntries(17, LLM_OPTION_MAX_SCALAR_CHARS)],
		["app_profile_overrides", _LSCB_Overrides(LLM_OPTION_MAX_COLLECTION_ITEMS + 1)],
		["app_profile_overrides", _LSCB_Overrides(18, 60000)]
	]
	for Entry in Cases {
		Normalized := "sentinel"
		AssertFalse(LLM_Option_TryNormalize(Entry[1], Entry[2], &Normalized),
			"(ahk2-18-semantic-config-budget) oversized option must fail: " . Entry[1])
		AssertEqual(false, Normalized)
	}

	TooManyStops := []
	Loop LLM_OPTION_MAX_STOP_SEQUENCES + 1
		TooManyStops.Push("stop-" . A_Index)
	AssertFalse(LLM_Option_TryNormalize("user_profiles", [Map(
		"id", "profile", "raw_prompt", "prompt", "batch", false,
		"stop_sequences", TooManyStops)], &Normalized),
		"stop-sequence arrays need their own count boundary")

	ProfileWithTooManyFields := Map("id", "profile")
	ApiWithTooManyFields := Map("Id", "entry")
	Loop LLM_OPTION_MAX_RECORD_FIELDS {
		ProfileWithTooManyFields["field-" . A_Index] := "value"
		ApiWithTooManyFields["Field-" . A_Index] := "value"
	}
	AssertFalse(LLM_Option_TryNormalize(
		"user_profiles", [ProfileWithTooManyFields], &Normalized),
		"custom-profile records need a field-count boundary")
	AssertFalse(LLM_Option_TryNormalize(
		"api_entries", [ApiWithTooManyFields], &Normalized),
		"API-entry records need a field-count boundary")
}
Test("AHK2-18 semantic config: documented budgets reject every oversized graph family "
	. "(ahk2-18-semantic-config-budget)",
	_LSCB_DocumentedBudgetsRejectOversizeValues)

_LSCB_ValidBoundaryControlsRemainAccepted() {
	global LLM_OPTION_MAX_SCALAR_CHARS, LLM_OPTION_MAX_COLLECTION_ITEMS,
		LLM_OPTION_MAX_PROFILE_ITEMS, LLM_OPTION_MAX_API_ENTRIES
	Cases := [
		["model", _LSCB_Repeat("m", LLM_OPTION_MAX_SCALAR_CHARS)],
		["disabled_apps", _LSCB_NumberedStrings(LLM_OPTION_MAX_COLLECTION_ITEMS)],
		["user_profiles", _LSCB_UserProfiles(LLM_OPTION_MAX_PROFILE_ITEMS)],
		["api_entries", _LSCB_ApiEntries(LLM_OPTION_MAX_API_ENTRIES)],
		["app_profile_overrides", _LSCB_Overrides(LLM_OPTION_MAX_COLLECTION_ITEMS)]
	]
	for Entry in Cases
		AssertTrue(LLM_Option_TryNormalize(Entry[1], Entry[2], &Normalized),
			"(ahk2-18-semantic-config-budget) exact boundary must remain accepted: " . Entry[1])
}
Test("AHK2-18 semantic config: exact count and string boundaries remain accepted "
	. "(ahk2-18-semantic-config-budget)",
	_LSCB_ValidBoundaryControlsRemainAccepted)

_LSCB_UserProfilesCannotShadowBuiltinIds() {
	for Id in ["raw", "basic", "advanced", "batch_advanced"] {
		Profiles := [Map(
			"id", Id, "label", "Shadow",
			"raw_prompt", "prompt", "batch", false)]
		AssertFalse(LLM_Option_TryNormalize(
			"user_profiles", Profiles, &Normalized),
			"a custom profile must not shadow built-in id '" . Id . "'")
	}
	AssertTrue(LLM_Option_TryNormalize("user_profiles", [Map(
		"id", "custom", "label", "Custom",
		"raw_prompt", "prompt", "batch", false)], &Normalized),
		"a distinct custom profile id must remain accepted")
}

Test("LLM profile ids: custom profiles cannot shadow built-ins (ahk-029)",
	_LSCB_UserProfilesCannotShadowBuiltinIds)

_LSCB_OversizeNeverPublishesThroughRestoreOrEngine() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Engine,
		LLM_OPTION_MAX_SCALAR_CHARS, LLM_OPTION_MAX_COLLECTION_ITEMS,
		LLM_OPTION_MAX_PROFILE_ITEMS, LLM_OPTION_MAX_API_ENTRIES
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedEngine := _LLM_Engine
	Baselines := Map(
		"model", "safe-model",
		"disabled_apps", [],
		"user_profiles", [],
		"api_entries", [],
		"app_profile_overrides", Map())
	Cases := [
		["model", _LSCB_Repeat("m", LLM_OPTION_MAX_SCALAR_CHARS + 1)],
		["disabled_apps", _LSCB_NumberedStrings(LLM_OPTION_MAX_COLLECTION_ITEMS + 1)],
		["user_profiles", _LSCB_UserProfiles(LLM_OPTION_MAX_PROFILE_ITEMS + 1)],
		["api_entries", _LSCB_ApiEntries(LLM_OPTION_MAX_API_ENTRIES + 1)],
		["app_profile_overrides", _LSCB_Overrides(LLM_OPTION_MAX_COLLECTION_ITEMS + 1)]
	]
	try {
		for Entry in Cases {
			Key := Entry[1]
			_LLM_Menu := LLM_Menu_DeepClone(SavedMenu)
			Baseline := LLM_Menu_DeepClone(Baselines[Key])
			_LLM_Menu[Key] := LLM_Menu_DeepClone(Baseline)
			_LLM_Menu_Loaded := false
			AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(Map(Key, Entry[2])))
			AssertEqual(_LLM_Engine_EncodeSemanticValue(Baseline),
				_LLM_Engine_EncodeSemanticValue(_LLM_Menu[Key]),
				"(ahk2-18-semantic-config-budget) restore must retain baseline: " . Key)

			_LLM_Engine := SavedEngine.Clone()
			_LLM_Engine["enabled"] := false
			_LLM_Engine["language"] := "safe-language"
			Thrown := false
			try LLM_Engine_Init(Map("language", "must-not-publish", Key, Entry[2]))
			catch as Err {
				Thrown := true
				AssertTrue(Err is TypeError)
			}
			AssertTrue(Thrown,
				"engine must reject oversized option atomically: " . Key)
			AssertFalse(_LLM_Engine["enabled"])
			AssertEqual("safe-language", _LLM_Engine["language"])
		}
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		_LLM_Engine := SavedEngine
	}
}
Test("AHK2-18 semantic config: restore and engine never publish oversized graphs "
	. "(ahk2-18-semantic-config-budget)",
	_LSCB_OversizeNeverPublishesThroughRestoreOrEngine)
