; tests/unit/test_healthcheck_owner_snapshots.ahk

; ==============================================================================
; MODULE: Healthcheck Owner Snapshot Regression Tests
; DESCRIPTION:
; Proves healthcheck rendering consumes one current Keylogger/LLM owner snapshot
; and cannot fall back to the legacy globals that had no production writers.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Owner snapshots and renderers
; =========================================
; =========================================

_HCOS_KeyloggerOwner() {
	return Map("enabled", true, "wpm", 87, "events_session", 41,
		"privacy_hits", 6, "today_log", "C:\metrics\today.log")
}

_HCOS_LlmOwner() {
	return Map("available", true, "enabled", true, "backend", "ollama",
		"profile_id", "work", "model", "qwen-health", "n_predictions", 5,
		"streaming", false)
}

_HCOS_OwnerValuesReachWebAndText() {
	KeyloggerState := _HealthCheck_KeyloggerSummary(_HCOS_KeyloggerOwner)
	LlmState := _HealthCheck_LLMState(_HCOS_LlmOwner)
	AssertEqual("true", KeyloggerState["enabled"])
	AssertEqual(87, KeyloggerState["wpm"])
	AssertEqual(41, KeyloggerState["events_session"])
	AssertEqual(6, KeyloggerState["privacy_hits"])
	AssertEqual("true", LlmState["enabled"])
	AssertEqual("ollama", LlmState["backend"])
	AssertEqual("work", LlmState["active_profile"])

	Snapshot := HealthCheck_Run()
	Snapshot["keylogger"] := KeyloggerState
	Snapshot["llm"] := LlmState
	Plain := HealthCheck_FormatPlain(Snapshot)
	WebJson := _HC_SnapshotToJson(Snapshot)
	for Expected in ["events=41", "wpm=87", "privacy_hits=6",
		"enabled=true backend=ollama profile=work"]
		AssertTrue(InStr(Plain, Expected, true) > 0,
			"plain export must render current owner value: " . Expected)
	for Expected in ['"events_session":41', '"wpm":87', '"privacy_hits":6',
		'"backend":"ollama"', '"active_profile":"work"']
		AssertTrue(InStr(WebJson, Expected, true) > 0,
			"WebView snapshot must render current owner value: " . Expected)
}

Test("healthcheck: current owner snapshots reach WebView and text export (healthcheck-stale-globals)",
	_HCOS_OwnerValuesReachWebAndText)

_HCOS_ProductionOwnersAreAtomic() {
	global _LLM_Menu, _LLM_Menu_Loaded
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedInitialized := Keylogger.initialized
	SavedEvents := Keylogger.health_events_session
	SavedPrivacy := Keylogger.health_privacy_hits
	SavedToday := Keylogger.today_log_path
	try {
		_LLM_Menu := Map("enabled", true, "backend", "api", "profile_id", "legal",
			"model", "remote-model", "n_predictions", 7, "streaming", false)
		_LLM_Menu_Loaded := true
		Llm := LLM_Menu_HealthSnapshot()
		AssertTrue(Llm["available"])
		AssertEqual("api", Llm["backend"])
		AssertEqual("legal", Llm["profile_id"])

		Keylogger.initialized := true
		Keylogger.health_events_session := 23
		Keylogger.health_privacy_hits := 4
		Keylogger.today_log_path := "C:\owner\today.log"
		Kl := KL_HealthSnapshot(() => Map("wpm", 72))
		AssertTrue(Kl["enabled"])
		AssertEqual(23, Kl["events_session"])
		AssertEqual(4, Kl["privacy_hits"])
		AssertEqual(72, Kl["wpm"])
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		Keylogger.initialized := SavedInitialized
		Keylogger.health_events_session := SavedEvents
		Keylogger.health_privacy_hits := SavedPrivacy
		Keylogger.today_log_path := SavedToday
	}
}

Test("healthcheck: Keylogger and LLM expose provenance-checked atomic snapshots (healthcheck-stale-globals)",
	_HCOS_ProductionOwnersAreAtomic)





; ======================================
; ======================================
; ======= 2/ Dead-global ratchet =======
; ======================================
; ======================================

_HCOS_NoUnwrittenLegacyGlobals() {
	Source := FileRead(A_ScriptDir . "\\..\\ui\\healthcheck\\helpers.ahk", "UTF-8")
	AssertTrue(Source != "", "healthcheck helpers source must be readable")
	for DeadName in ["_Keylogger_EventsToday", "_Keylogger_WPM",
		"_Keylogger_PrivacyCount", "llm_enabled", "llm_backend",
		"llm_active_profile", "FeaturesV2", "ErgoptiBaseEnabled",
		"AltGrActive", "ShiftActive", "CapsActive", "_AltGrPrefixLatched",
		"PERSONAL_HOTSTRINGS", "DYNAMIC_HOTSTRINGS", "MAGIC_KEY"]
		AssertFalse(InStr(Source, DeadName, true) > 0,
			"healthcheck must not read unwritten legacy global: " . DeadName)
	AssertTrue(InStr(Source, "KL_HealthSnapshot") > 0)
	AssertTrue(InStr(Source, "LLM_Menu_HealthSnapshot") > 0)
}

Test("healthcheck: unwritten legacy globals cannot return (healthcheck-stale-globals)",
	_HCOS_NoUnwrittenLegacyGlobals)
