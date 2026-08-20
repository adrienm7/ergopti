; static/ergopti_plus/windows/tests/unit/test_llm_profiles.ahk

; ==============================================================================
; MODULE: LLM Profiles Tests
; DESCRIPTION:
; Unit-tests for the purely logical functions in modules/llm/profiles.ahk:
; LLM_ParseProfilesJSON, LLM_ParseProfileObject, LLM_GetActiveProfile,
; LLM_ResolveSystemPrompt, and LLM_GetBasicPrompt.
; No network calls are made — all JSON is supplied inline as string literals.
; ==============================================================================




; =============================================
; =============================================
; ======= 1/ LLM_ParseProfileObject ==========
; =============================================
; =============================================

_LLMP_ParseObjectExtractsId() {
	obj := '{"id": "basic", "label": "Basic", "system_single": "You are {language}", "batch": false}'
	m := LLM_ParseProfileObject(obj)
	AssertEqual("basic", m["id"])
}
Test("LLM_ParseProfileObject: extracts id field", _LLMP_ParseObjectExtractsId)


_LLMP_ParseObjectExtractsLabel() {
	obj := '{"id": "basic", "label": "Basic Completion", "system_single": "", "batch": false}'
	m := LLM_ParseProfileObject(obj)
	AssertEqual("Basic Completion", m["label"])
}
Test("LLM_ParseProfileObject: extracts label field", _LLMP_ParseObjectExtractsLabel)


; Encore plus: pause guard for LLM profiles (project_suspend_pause_invariant)
; A profile is data. Parsing one must never reach the network or the engine —
; the gate that decides whether to predict lives in the engine, and a profile
; module that fired a request on parse would bypass it entirely.
TestLLMProfiles_PauseNoPredict() {
	Parse := _DriverFuncBody("LLM_ParseProfileObject")
	for Forbidden in ["WinHttp", "ComObject", "SetTimer", "LLM_Engine_"] {
		Assert(InStr(Parse, Forbidden) == 0,
			"LLM_ParseProfileObject() must not reference " . Forbidden . " — parsing a profile is "
			. "data handling, and any request fired here would bypass the engine's own gate")
	}

	Resolve := _DriverFuncBody("LLM_ResolveSystemPrompt")
	for Forbidden in ["WinHttp", "ComObject", "SetTimer"] {
		Assert(InStr(Resolve, Forbidden) == 0,
			"LLM_ResolveSystemPrompt() must not reference " . Forbidden . " — it builds a string")
	}
}
Test("LLM profiles: pause must block all profile-driven predictions", TestLLMProfiles_PauseNoPredict)

; Error paths: bad JSON or missing fields must not crash
TestLLMProfiles_BadJSONGraceful() {
	m := LLM_ParseProfileObject('{"bad": "json"')
	AssertTrue(m is Map, "bad JSON must still return a Map (resilient defaults)")
	AssertEqual("", m["id"])
	AssertFalse(m["batch"])
}
Test("LLM profiles: bad JSON handled gracefully without crash", TestLLMProfiles_BadJSONGraceful)

; Resolve under pause: must fallback safely
; The resolver must always return a usable prompt, whatever it is handed. An
; empty prompt is not a safe degradation: the model receives no instructions at
; all and completes freely into the user's document.
TestLLMProfiles_PauseFallback() {
	Basic := LLM_GetBasicPrompt()
	Assert(Basic != "", "the basic prompt must not itself be empty — it is the floor for every fallback")
	Head := SubStr(Basic, 1, 40)

	; A non-object profile falls back to the basic prompt. Compared on its head
	; rather than whole, because the resolver substitutes {min_words} / {max_words}
	; / {language} on the way out — which is itself asserted just below.
	Missing := LLM_ResolveSystemPrompt("", 1, 1, 15)
	Assert(Missing != "", "a missing profile must never resolve to an empty prompt")
	AssertTrue(InStr(Missing, Head) > 0,
		"a missing profile must fall back to the basic prompt, not to something else")

	; A profile with no usable field falls back the same way.
	NoField := LLM_ResolveSystemPrompt(Map(), 1, 1, 15)
	AssertTrue(InStr(NoField, Head) > 0,
		"a profile carrying no prompt field must fall back to the basic prompt")

	; The runtime placeholders must be substituted, or the model is handed the
	; literal text "{max_words}" as an instruction.
	WithVars := LLM_ResolveSystemPrompt(Map("system_single", "up to {max_words} words in {language}"), 1, 1, 7, "fr")
	AssertTrue(InStr(WithVars, "7") > 0, "{max_words} must be substituted")
	AssertTrue(InStr(WithVars, "fr") > 0, "{language} must be substituted")
	Assert(InStr(WithVars, "{max_words}") == 0, "no placeholder may survive into the prompt")

	; And a real one is used verbatim, so the fallbacks above are fallbacks and
	; not the only path.
	Real := Map("system_single", "SPECIFIC")
	AssertTrue(InStr(LLM_ResolveSystemPrompt(Real, 1, 1, 15), "SPECIFIC") > 0,
		"a profile that supplies a prompt must have it used")
}
Test("LLM profiles: system prompt resolve must be pause-safe", TestLLMProfiles_PauseFallback)


_LLMP_ParseObjectExtractsBooleanTrue() {
	obj := '{"id": "batch_adv", "label": "Batch", "system_single": "", "batch": true}'
	m := LLM_ParseProfileObject(obj)
	AssertTrue(m["batch"])
}
Test("LLM_ParseProfileObject: extracts batch=true as boolean true", _LLMP_ParseObjectExtractsBooleanTrue)


_LLMP_ParseObjectExtractsBooleanFalse() {
	obj := '{"id": "basic", "label": "Basic", "system_single": "", "batch": false}'
	m := LLM_ParseProfileObject(obj)
	AssertFalse(m["batch"])
}
Test("LLM_ParseProfileObject: extracts batch=false as boolean false", _LLMP_ParseObjectExtractsBooleanFalse)


_LLMP_ParseObjectMissingFieldsReturnEmpty() {
	obj := '{"id": "min"}'
	m := LLM_ParseProfileObject(obj)
	AssertEqual("min", m["id"])
	AssertEqual("",   m["label"])
	AssertEqual("",   m["system_single"])
	AssertFalse(m["batch"])
}
Test("LLM_ParseProfileObject: missing optional fields return empty/false defaults", _LLMP_ParseObjectMissingFieldsReturnEmpty)


_LLMP_ParseObjectExtractsStopSequences() {
	; Three backticks via Chr(96) — backtick is AHK's escape char so it cannot
	; appear literally in either a double-quoted or single-quoted AHK string.
	; Build the JSON programmatically to avoid any AHK string-escape processing.
	ThreeBackticks := Chr(96) . Chr(96) . Chr(96)
	obj := '{"id": "code", "label": "Code", "system_single": "", "batch": false, "stop_sequences": ["'
		. ThreeBackticks . '", "\n\n"]}'
	m := LLM_ParseProfileObject(obj)
	AssertEqual(2, m["stop_sequences"].Length)
	AssertEqual(ThreeBackticks, m["stop_sequences"][1])
}
Test("LLM_ParseProfileObject: extracts stop_sequences array", _LLMP_ParseObjectExtractsStopSequences)


_LLMP_ParseObjectStopSequencesEmptyWhenAbsent() {
	obj := '{"id": "basic", "label": "Basic", "system_single": "", "batch": false}'
	m := LLM_ParseProfileObject(obj)
	AssertEqual(0, m["stop_sequences"].Length)
}
Test("LLM_ParseProfileObject: stop_sequences is empty array when field absent", _LLMP_ParseObjectStopSequencesEmptyWhenAbsent)




; =============================================
; =============================================
; ======= 2/ LLM_ParseProfilesJSON ============
; =============================================
; =============================================

_LLMP_ParseJSONSingleProfile() {
	json := '[{"id":"basic","label":"Basic","system_single":"hello","batch":false}]'
	result := LLM_ParseProfilesJSON(json)
	AssertEqual(1, result.Length)
	AssertEqual("basic", result[1]["id"])
}
Test("LLM_ParseProfilesJSON: parses single-profile JSON array", _LLMP_ParseJSONSingleProfile)


_LLMP_ParseJSONTwoProfiles() {
	json := '[{"id":"basic","label":"Basic","system_single":"A","batch":false},{"id":"adv","label":"Advanced","system_single":"B","batch":true}]'
	result := LLM_ParseProfilesJSON(json)
	AssertEqual(2, result.Length)
	AssertEqual("basic", result[1]["id"])
	AssertEqual("adv",   result[2]["id"])
}
Test("LLM_ParseProfilesJSON: parses two-profile JSON array", _LLMP_ParseJSONTwoProfiles)


_LLMP_ParseJSONEmptyArray() {
	json := "[]"
	result := LLM_ParseProfilesJSON(json)
	AssertEqual(0, result.Length)
}
Test("LLM_ParseProfilesJSON: empty array returns empty result", _LLMP_ParseJSONEmptyArray)




; =============================================
; =============================================
; ======= 3/ LLM_GetActiveProfile =============
; =============================================
; =============================================

_LLMP_GetActiveReturnsMatchedProfile() {
	profiles := [
		Map("id", "basic",   "label", "Basic",    "system_single", "Basic prompt",   "batch", false, "stop_sequences", []),
		Map("id", "advanced","label", "Advanced",  "system_single", "Advanced prompt","batch", false, "stop_sequences", []),
	]
	result := LLM_GetActiveProfile("advanced", profiles)
	AssertEqual("advanced", result["id"])
}
Test("LLM_GetActiveProfile: returns correct profile when id matches", _LLMP_GetActiveReturnsMatchedProfile)


_LLMP_GetActiveFallsBackToBasic() {
	profiles := [
		Map("id", "basic", "label", "Basic", "system_single", "Basic prompt", "batch", false, "stop_sequences", []),
	]
	result := LLM_GetActiveProfile("nonexistent_id_xyz", profiles)
	AssertEqual("basic", result["id"])
}
Test("LLM_GetActiveProfile: falls back to basic when id not found", _LLMP_GetActiveFallsBackToBasic)


_LLMP_GetActiveLegacyAliasParallel() {
	profiles := [
		Map("id", "basic", "label", "Basic", "system_single", "Basic prompt", "batch", false, "stop_sequences", []),
	]
	; "parallel" is a legacy alias for "basic"
	result := LLM_GetActiveProfile("parallel", profiles)
	AssertEqual("basic", result["id"])
}
Test("LLM_GetActiveProfile: legacy alias 'parallel' resolves to 'basic'", _LLMP_GetActiveLegacyAliasParallel)


_LLMP_GetActiveLegacyAliasBatch() {
	profiles := [
		Map("id", "batch_advanced", "label", "Batch Adv", "system_single", "X", "batch", true, "stop_sequences", []),
	]
	; "batch" is a legacy alias for "batch_advanced"
	result := LLM_GetActiveProfile("batch", profiles)
	AssertEqual("batch_advanced", result["id"])
}
Test("LLM_GetActiveProfile: legacy alias 'batch' resolves to 'batch_advanced'", _LLMP_GetActiveLegacyAliasBatch)




; =============================================
; =============================================
; ======= 4/ LLM_ResolveSystemPrompt ==========
; =============================================
; =============================================

_LLMP_ResolveSingleModeUsesSystemSingle() {
	profile := Map("id", "p", "system_single", "Prompt for {language}", "batch", false, "stop_sequences", [], "raw_prompt", "")
	result := LLM_ResolveSystemPrompt(profile, 1, 2, 5, "fr")
	Assert(InStr(result, "fr") > 0, "Expected 'fr' injected into prompt, got: " . result)
}
Test("LLM_ResolveSystemPrompt: single mode uses system_single with language injected", _LLMP_ResolveSingleModeUsesSystemSingle)


_LLMP_ResolveInjectsMinWords() {
	profile := Map("id", "p", "system_single", "min:{min_words}", "batch", false, "stop_sequences", [], "raw_prompt", "")
	result := LLM_ResolveSystemPrompt(profile, 1, 3, 10)
	Assert(InStr(result, "3") > 0, "Expected min_words=3 injected, got: " . result)
}
Test("LLM_ResolveSystemPrompt: injects {min_words} into prompt", _LLMP_ResolveInjectsMinWords)


_LLMP_ResolveInjectsMaxWords() {
	profile := Map("id", "p", "system_single", "max:{max_words}", "batch", false, "stop_sequences", [], "raw_prompt", "")
	result := LLM_ResolveSystemPrompt(profile, 1, 1, 7)
	Assert(InStr(result, "7") > 0, "Expected max_words=7 injected, got: " . result)
}
Test("LLM_ResolveSystemPrompt: injects {max_words} into prompt", _LLMP_ResolveInjectsMaxWords)


_LLMP_ResolveMaxWordsZeroBecomesUnlimited() {
	profile := Map("id", "p", "system_single", "max:{max_words}", "batch", false, "stop_sequences", [], "raw_prompt", "")
	result := LLM_ResolveSystemPrompt(profile, 1, 1, 0)
	Assert(InStr(result, "unlimited") > 0, "Expected 'unlimited' when max_words=0, got: " . result)
}
Test("LLM_ResolveSystemPrompt: max_words=0 resolves to 'unlimited'", _LLMP_ResolveMaxWordsZeroBecomesUnlimited)


_LLMP_ResolveRawPromptTakesPrecedence() {
	profile := Map("id", "p", "system_single", "should not appear", "batch", false, "stop_sequences", [], "raw_prompt", "raw override {language}")
	result := LLM_ResolveSystemPrompt(profile, 1, 1, 5, "de")
	Assert(InStr(result, "raw override") > 0, "Expected raw_prompt to take precedence")
}
Test("LLM_ResolveSystemPrompt: raw_prompt field takes precedence over system_single", _LLMP_ResolveRawPromptTakesPrecedence)


_LLMP_ResolveNonObjectProfileFallsBack() {
	; Passing a non-object should use the built-in basic prompt fallback
	result := LLM_ResolveSystemPrompt("not_an_object", 1, 1, 5, "en")
	Assert(StrLen(result) > 0, "Expected non-empty fallback prompt")
}
Test("LLM_ResolveSystemPrompt: non-object profile falls back to basic prompt", _LLMP_ResolveNonObjectProfileFallsBack)




; =============================================
; =============================================
; ======= 5/ LLM_GetBasicPrompt ===============
; =============================================
; =============================================

_LLMP_GetBasicPromptIsNonEmpty() {
	result := LLM_GetBasicPrompt()
	Assert(StrLen(result) > 0, "Basic prompt must be non-empty")
}
Test("LLM_GetBasicPrompt: returns non-empty fallback prompt", _LLMP_GetBasicPromptIsNonEmpty)


_LLMP_GetBasicPromptContainsMinWords() {
	result := LLM_GetBasicPrompt()
	Assert(InStr(result, "{min_words}") > 0, "Basic prompt must contain {min_words} placeholder")
}
Test("LLM_GetBasicPrompt: contains {min_words} placeholder", _LLMP_GetBasicPromptContainsMinWords)


_LLMP_GetBasicPromptContainsLanguage() {
	result := LLM_GetBasicPrompt()
	Assert(InStr(result, "{language}") > 0, "Basic prompt must contain {language} placeholder")
}
Test("LLM_GetBasicPrompt: contains {language} placeholder", _LLMP_GetBasicPromptContainsLanguage)




; =============================================
; =============================================
; ======= 6/ LLM_LoadProfilesJSON =============
; =============================================
; =============================================

; Coverage + regression guard for the FileSystem-adapter routing of the profiles
; loader. LLM_LoadProfilesJSON was previously the ONLY profiles function with no
; test — every other case feeds inline JSON to LLM_ParseProfilesJSON and never
; touches the file-read path. After routing its read from a direct FileRead to
; FSRead (the FileSystem adapter, matching _LLM_LoadPresets for models.json), this
; exercises the real read+parse path against a temp file written through the same
; adapter, so a future break in the adapter routing is caught.
_LLMP_LoadProfilesReadsFileViaAdapter() {
	tmp := A_Temp . "\ergopti_test_profiles_load.json"
	try FSDelete(tmp)
	FSWrite(tmp, '[{"id":"basic","label":"Basic","system_single":"hi","batch":false},{"id":"adv","label":"Adv","system_single":"yo","batch":true}]')
	profiles := LLM_LoadProfilesJSON(tmp)
	try FSDelete(tmp)
	Assert(profiles is Array, "LLM_LoadProfilesJSON must return an Array")
	AssertEqual(2, profiles.Length)
	AssertEqual("basic", profiles[1]["id"])
	AssertEqual("adv",   profiles[2]["id"])
}
Test("LLM_LoadProfilesJSON: reads a real file through the FileSystem adapter (FSRead) and parses it", _LLMP_LoadProfilesReadsFileViaAdapter)


; A missing file must degrade to an empty array, never throw — the graceful-empty
; contract preserved when moving from try/FileRead to FSRead's false-on-error return.
_LLMP_LoadProfilesMissingFileReturnsEmpty() {
	missing := A_Temp . "\ergopti_test_profiles_does_not_exist_zzz.json"
	try FSDelete(missing)
	profiles := LLM_LoadProfilesJSON(missing)
	Assert(profiles is Array, "missing file must still yield an Array")
	AssertEqual(0, profiles.Length)
}
Test("LLM_LoadProfilesJSON: missing file degrades to empty array (no throw)", _LLMP_LoadProfilesMissingFileReturnsEmpty)
