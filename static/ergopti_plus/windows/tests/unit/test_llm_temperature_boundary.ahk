; static/ergopti_plus/windows/tests/unit/test_llm_temperature_boundary.ahk

_LTB_CanonicalDecimalValuesNormalizeExactly() {
	Cases := [
		["0", "0.00"],
		["0.10", "0.10"],
		["1.5", "1.50"],
		["2", "2.00"],
		[0, "0.00"],
		[0.25, "0.25"],
		[2.0, "2.00"]
	]
	for Entry in Cases {
		Normalized := false
		AssertTrue(LLM_Option_TryNormalize("temperature", Entry[1], &Normalized),
			"(ahk2-11-temperature-boundary) canonical value must be accepted: " . String(Entry[1]))
		AssertEqual(Entry[2], Normalized,
			"(ahk2-11-temperature-boundary) accepted temperatures share one canonical two-decimal image")
	}
}
Test("LLM temperature: canonical decimal values normalize exactly (ahk2-11-temperature-boundary)",
	_LTB_CanonicalDecimalValuesNormalizeExactly)

_LTB_NonCanonicalAndOutOfDomainValuesFailClosed() {
	Rejected := [
		"0x10", "1e0", "1E+0", "+1", "-0", " 1", "1 ",
		".5", "2.", "00.10", "1.000", "1.234", "2.0001",
		"999999999999999999999999", "NaN", "Inf", -0.01, 0.123, 2.01
	]
	for Value in Rejected {
		Normalized := "sentinel"
		AssertFalse(LLM_Option_TryNormalize("temperature", Value, &Normalized),
			"(ahk2-11-temperature-boundary) non-canonical or out-of-range value must fail: " . String(Value))
		AssertEqual(false, Normalized,
			"(ahk2-11-temperature-boundary) refusal must publish no normalized value")
	}
}
Test("LLM temperature: non-canonical and out-of-domain values fail closed (ahk2-11-temperature-boundary)",
	_LTB_NonCanonicalAndOutOfDomainValuesFailClosed)

_LTB_EngineAdmissionIsAtomic() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		_LLM_Engine := SavedEngine.Clone()
		_LLM_Engine["enabled"] := false
		_LLM_Engine["language"] := "safe-language"
		_LLM_Engine["temperature"] := "0.10"
		for Bad in ["0x10", "1e0", "+1", " 1", "2.01"] {
			Thrown := false
			try LLM_Engine_Init(Map(
				"language", "must-not-publish",
				"temperature", Bad))
			catch as Err {
				Thrown := true
				AssertTrue(Err is TypeError)
			}
			AssertTrue(Thrown,
				"(ahk2-11-temperature-boundary) engine admission must reject: " . Bad)
			AssertFalse(_LLM_Engine["enabled"],
				"(ahk2-11-temperature-boundary) a bad temperature must not enable the engine")
			AssertEqual("safe-language", _LLM_Engine["language"],
				"(ahk2-11-temperature-boundary) an earlier option must not publish before temperature validation")
			AssertEqual("0.10", _LLM_Engine["temperature"])
		}
	} finally {
		_LLM_Engine := SavedEngine
	}
}
Test("LLM temperature: engine admission is atomic (ahk2-11-temperature-boundary)",
	_LTB_EngineAdmissionIsAtomic)

_LTB_PersistenceAndPayloadUseValidatedValue() {
	global Features, _LLM_Menu
	CandidateFeatures := _HSDeepCloneMap(Features)
	CandidateMenu := LLM_Menu_DeepClone(_LLM_Menu)
	OriginalTemperature := CandidateFeatures["llm"]["generation"]["temperature"]
	CandidateMenu["temperature"] := "1e0"
	AssertFalse(_LLM_Menu_SyncToFeatures(CandidateFeatures, CandidateMenu),
		"(ahk2-11-temperature-boundary) persistence must refuse exponent spelling before Float converts it")
	AssertEqual(OriginalTemperature,
		CandidateFeatures["llm"]["generation"]["temperature"],
		"(ahk2-11-temperature-boundary) refused persistence must leave the detached Features graph unchanged")

	for Boundary in ["0", "2"] {
		AssertTrue(LLM_Option_TryNormalize("temperature", Boundary, &Normalized))
		Ollama := JsonParse(LLM_BuildOllamaPayload(
			"model", "system", "user", Normalized))
		Remote := JsonParse(_LLMRemoteBuildPayload(
			"openai", "model", "system", "user", Normalized))
		AssertEqual(Float(Normalized), Ollama["options"]["temperature"],
			"(ahk2-11-temperature-boundary) Ollama payload must carry the validated boundary")
		AssertEqual(Float(Normalized), Remote["temperature"],
			"(ahk2-11-temperature-boundary) remote payload must carry the validated boundary")
	}
}
Test("LLM temperature: persistence and payload use only validated values (ahk2-11-temperature-boundary)",
	_LTB_PersistenceAndPayloadUseValidatedValue)
