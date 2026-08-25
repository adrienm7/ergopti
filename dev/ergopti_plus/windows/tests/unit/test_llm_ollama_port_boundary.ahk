; tests/unit/test_llm_ollama_port_boundary.ahk

; ==============================================================================
; MODULE: Ollama Port Boundary Tests
; DESCRIPTION:
; Proves that one semantic port boundary owns public option admission, persisted
; TOML restore and engine publication before the HTTP client is mutated.
; ==============================================================================

#Requires AutoHotkey v2.0

_AHK022_ReturnZero(*) {
	return 0
}

_AHK022_ReturnStringOne(*) {
	return "1"
}

_AHK022_ThrowSetter(*) {
	throw Error("injected setter failure")
}

_AHK022_PortNormalizerOwnsTheDocumentedRange() {
	for Value in [1024, 65535, "12000"] {
		AssertTrue(LLM_Option_TryNormalize("ollama_port", Value, &Normalized),
			"valid Ollama port must normalize: " . Value)
		AssertEqual(Integer(Value), Normalized)
	}
	for Value in [80, 1023, 65536, -1, 12.5, "12.5", "not-a-port", [], Map()] {
		AssertFalse(LLM_Option_TryNormalize("ollama_port", Value, &Normalized),
			"invalid Ollama port must fail closed: " . Type(Value))
	}
}
Test("AHK-022 Ollama port: one normalizer owns type and range "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_PortNormalizerOwnsTheDocumentedRange)

_AHK022_InvalidPersistedPortNeverReachesSavedOptions() {
	Path := A_Temp . "\ergopti_ahk022_invalid_port.toml"
	try {
		try FileDelete(Path)
		FileAppend("[llm]`nollama_port = 80`n", Path, "UTF-8")
		Cache := ParseTomlFile(Path)
		AssertEqual(80, IniCacheGet(Cache, "llm", "ollama_port"),
			"fixture must reach the production loader as an integer")
		Opts := LLM_Menu_BuildSavedOpts(Cache)
		AssertFalse(Opts.Has("ollama_port"),
			"an invalid persisted port must be omitted before menu publication")
	} finally {
		try FileDelete(Path)
	}
}
Test("AHK-022 Ollama port: invalid TOML is rejected before menu restore "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_InvalidPersistedPortNeverReachesSavedOptions)

_AHK022_RestorePreservesTheValidatedDefault() {
	global _LLM_Menu, _LLM_Menu_Loaded
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	try {
		_LLM_Menu := LLM_Menu_DeepClone(SavedMenu)
		_LLM_Menu["ollama_port"] := 14000
		_LLM_Menu_Loaded := false
		AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(Map("ollama_port", 80)))
		AssertEqual(14000, _LLM_Menu["ollama_port"],
			"direct restore must keep the last validated default on rejection")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
	}
}
Test("AHK-022 Ollama port: direct restore preserves the validated default "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_RestorePreservesTheValidatedDefault)

_AHK022_EngineRejectsTheSameInvalidPort() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		Thrown := false
		try LLM_Engine_Init(Map("ollama_port", 80))
		catch
			Thrown := true
		AssertTrue(Thrown,
			"engine admission must not publish a port rejected by the HTTP client")
	} finally {
		_LLM_Engine := SavedEngine
	}
}
Test("AHK-022 Ollama port: engine and HTTP client share admission "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_EngineRejectsTheSameInvalidPort)

_AHK022_BootPublicationRequiresASetterAck() {
	State := Map("ollama_port", "12000")
	Calls := []
	AssertTrue(_LLM_Menu_ApplyOllamaPortAtBoot(State,
		(Port) => (Calls.Push(Port), 1)))
	AssertEqual(1, Calls.Length)
	AssertEqual(12000, Calls[1])
	AssertEqual(12000, State["ollama_port"])

	for RefusalFn in [_AHK022_ReturnZero, _AHK022_ReturnStringOne] {
		Candidate := Map("ollama_port", 13000)
		Thrown := false
		try _LLM_Menu_ApplyOllamaPortAtBoot(Candidate, RefusalFn)
		catch
			Thrown := true
		AssertTrue(Thrown,
			"boot must fail loudly unless the exact client setter acknowledges")
		AssertEqual(13000, Candidate["ollama_port"],
			"a refused setter must not rewrite the candidate")
	}

	Thrown := false
	try _LLM_Menu_ApplyOllamaPortAtBoot(
		Map("ollama_port", 13000), _AHK022_ThrowSetter)
	catch
		Thrown := true
	AssertTrue(Thrown, "a throwing client setter must remain a boot failure")
}
Test("AHK-022 Ollama port: boot requires a strict client receipt "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_BootPublicationRequiresASetterAck)

_AHK022_InvalidPortCannotAcquireTransactionOwnership() {
	Calls := Map("stop", 0, "invalidate", 0, "cancel", 0)
	Prepared := _LLM_Menu_PrepareOllamaPortCandidate(
		Map("ollama_port", 80),
		(*) => Calls["stop"] += 1,
		(*) => Calls["invalidate"] += 1,
		(*) => (Calls["cancel"] += 1, true))
	AssertFalse(Prepared,
		"an invalid port must be rejected before transaction ownership begins")
	AssertEqual(0, Calls["stop"])
	AssertEqual(0, Calls["invalidate"])
	AssertEqual(0, Calls["cancel"])
}
Test("AHK-022 Ollama port: invalid candidate has no transaction side effects "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_InvalidPortCannotAcquireTransactionOwnership)

_AHK022_SharedDefaultsUseTheSameBoundary() {
	global LLM_Defaults, LLM_OLLAMA_KEEP_ALIVE
	HadDefaults := IsSet(LLM_Defaults)
	SavedDefaults := HadDefaults ? LLM_Defaults : 0
	SavedKeepAlive := LLM_OLLAMA_KEEP_ALIVE
	try {
		Calls := []
		LLM_Defaults := Map(
			"llm_ollama_port", "14000",
			"llm_ollama_keep_alive", "7m")
		AssertTrue(LLM_Ollama_LoadDefaults(
			(Port) => (Calls.Push(Port), 1)))
		AssertEqual(1, Calls.Length)
		AssertEqual(14000, Calls[1])
		AssertEqual("7m", LLM_OLLAMA_KEEP_ALIVE)

		LLM_Defaults["llm_ollama_port"] := 80
		AssertFalse(LLM_Ollama_LoadDefaults(
			(Port) => (Calls.Push(Port), 1)))
		AssertEqual(1, Calls.Length,
			"an invalid shared default must not reach the client setter")
		AssertEqual("7m", LLM_OLLAMA_KEEP_ALIVE,
			"invalid defaults must preserve the last complete publication")

		LLM_Defaults["llm_ollama_port"] := 15000
		LLM_Defaults["llm_ollama_keep_alive"] := "8m"
		AssertFalse(LLM_Ollama_LoadDefaults((*) => "1"),
			"a string-shaped setter result must not certify publication")
		AssertEqual("7m", LLM_OLLAMA_KEEP_ALIVE,
			"keep-alive must publish only after the port setter ACK")
	} finally {
		if HadDefaults
			LLM_Defaults := SavedDefaults
		else
			LLM_Defaults := unset
		LLM_OLLAMA_KEEP_ALIVE := SavedKeepAlive
	}
}
Test("AHK-022 Ollama port: shared defaults are complete-or-absent "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_SharedDefaultsUseTheSameBoundary)
