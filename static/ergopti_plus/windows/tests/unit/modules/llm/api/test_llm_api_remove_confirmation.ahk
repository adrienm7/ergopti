; tests/unit/modules/llm/api/test_llm_api_remove_confirmation.ahk

; ==============================================================================
; MODULE: API-entry removal confirmation regression tests
; DESCRIPTION:
; Keeps the actual native two-file source owner across a passive modal boundary.
; Real classified disk, DPAPI, the single boot fixture, and joint WAL publication
; prove that a stale Yes cannot overwrite later configuration or credentials.
; ==============================================================================

#Requires AutoHotkey v2.0

_WAR_Notify(State, Message, Options) {
	State.Notices.Push(Message)
	return true
}

_WAR_ReplaceApi(State) {
	State.ForeignApi := StrReplace(State.World.ApiImage, "independent-first", "external-remove-sentinel")
	AssertTrue(State.ForeignApi != State.World.ApiImage, "The external API mutation must change real source bytes.")
	AssertTrue(FSWriteDurable(State.World.ApiPath, State.ForeignApi))
}

_WAR_Confirm(State, Body, Title, Options) {
	global _LLM_Menu
	State.ConfirmCalls += 1
	AssertTrue(Body != "" && Title != "", "The actual localized removal question must reach the modal port.")
	AssertEqual("4 48", Options, "The destructive Yes/No warning must retain its native options.")
	AssertTrue(InStr(Title, _LLM_Menu_ApiEntryDisplayName(_LLM_Menu["api_entries"][2])) > 0,
		"The question must identify the originally active entry.")
	if State.Mode == "api"
		_WAR_ReplaceApi(State)
	else if State.Mode == "config" {
		State.ForeignConfig := StrReplace(State.World.ConfigImage, "unowned-remove-sentinel", "external-remove-sentinel")
		AssertTrue(State.ForeignConfig != State.World.ConfigImage, "The external config mutation must change real source bytes.")
		AssertTrue(FSWriteDurable(State.World.ConfigPath, State.ForeignConfig))
	} else if State.Mode == "active"
		_LLM_Menu["api_entry_id"] := "native-first"
	else if State.Mode == "menu"
		_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
	else if State.Mode == "throw"
		throw Error("Independent removal confirmation failure")
	State.MenuAfterModal := _LLM_Menu
	return State.Mode == "no" ? "No" : "Yes"
}

_WAR_Collect(State, CandidateFeatures, CandidateMenu) {
	State.CollectCalls += 1
	Updates := State.World.Collect(CandidateFeatures, CandidateMenu)
	if State.Mode == "late-api"
		_WAR_ReplaceApi(State)
	return Updates
}

_WAR_RemovalRetainsSource(Mode) {
	global _LLM_Menu, Features, _PathsFile
	World := _LSP_World()
	PreviousCritical := Critical("On")
	State := { Mode: Mode, World: World, ConfirmCalls: 0, CollectCalls: 0,
		Notices: [], ForeignApi: "", ForeignConfig: "", MenuAfterModal: _LLM_Menu }
	try {
		World.ConfigImage .= '[personal]`nmarker = "unowned-remove-sentinel"`n'
		AssertTrue(FSWriteDurable(World.ConfigPath, World.ConfigImage))
		World.Capture()
		SourceOptions := World.Owner.Options.Clone()
		SourceOptions["notify"] := _WAR_Notify.Bind(State)
		SourceOptions["collect"] := _WAR_Collect.Bind(State)
		Port := Map("confirm", _WAR_Confirm.Bind(State), "source_options", SourceOptions)
		ErrorMessage := ""
		Committed := false
		try Committed := _LLM_Menu_RemoveActiveApiEntry(Port)
		catch as Err
			ErrorMessage := Err.Message
		AssertEqual(Mode == "throw" ? "Independent removal confirmation failure" : "", ErrorMessage,
			"Unexpected fixture failures cannot masquerade as a refused or cancelled write.")
		AssertEqual(1, State.ConfirmCalls, "Every scenario must reach the actual removal question.")
		AssertEqual(Mode == "yes", Committed, "Only an unchanged Yes may commit the removal.")
		AssertEqual(Mode == "yes", World.ApplyCalls, "Only durable owned removal may run its application callback.")
		AssertEqual(Mode == "yes" || Mode == "late-api", State.CollectCalls,
			"Stale modal answers must stop before candidate serialization; late mutation must reach the real transaction.")
		AssertEqual(Mode == "yes" || Mode == "no" || Mode == "throw" ? 0 : 1, State.Notices.Length,
			"A stale source must report refusal; ordinary cancellation and successful removal remain silent.")
		if Mode == "yes" {
			Persisted := JsonParse(FSReadUtf8Exact(World.ApiPath))
			AssertEqual(1, Persisted.Length, "The actual WAL commit must remove exactly one saved entry.")
			AssertEqual("native-first", Persisted[1]["Id"], "The independently owned sibling must survive removal.")
			AssertEqual("independent-first", Persisted[1]["Model"])
			AssertTrue(LLM_ApiToken_IsValidEnvelope(Persisted[1]["Token"]), "The remaining real credential must be DPAPI sealed.")
			AssertEqual("private-first-sentinel", LLM_ApiToken_Decrypt(Persisted[1]["Token"]))
			AssertEqual(1, _LLM_Menu["api_entries"].Length)
			AssertEqual("native-first", _LLM_Menu["api_entry_id"])
			Config := TOML_ParseFreshFileTyped(World.ConfigPath)
			AssertEqual("native-first", Config["llm"]["api_entry_id"], "Both durable targets must name the same remaining entry.")
			AssertContains(FSReadUtf8Exact(World.ConfigPath), 'marker = "unowned-remove-sentinel"')
		} else {
			AssertEqual(State.ForeignApi != "" ? State.ForeignApi : World.ApiImage,
				FSReadUtf8Exact(World.ApiPath), "A refused old question cannot overwrite externally updated API bytes.")
			AssertEqual(State.ForeignConfig != "" ? State.ForeignConfig : World.ConfigImage,
				FSReadUtf8Exact(World.ConfigPath), "A refused old question cannot overwrite externally updated config bytes.")
			AssertTrue(_LLM_Menu == State.MenuAfterModal, "Refusal must retain the exact post-modal menu owner.")
			AssertTrue(Features == World.OldFeatures, "Refusal cannot publish a detached Features candidate.")
			AssertEqual(2, _LLM_Menu["api_entries"].Length)
			AssertEqual(Mode == "active" ? "native-first" : "native-active", _LLM_Menu["api_entry_id"])
			AssertEqual("private-active-sentinel", _LLM_Menu["api_entries"][2]["Token"],
				"A refused removal cannot discard the original active credential from RAM.")
		}
		AssertFalse(_ConfigWriteTerminalIsActive(), "Every path must settle its exact terminal owner.")
		AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort()), "absent"),
			"Success, refusal and cancellation must leave no pending joint WAL.")
	} finally {
		try World.Restore()
		finally Critical(PreviousCritical)
	}
}
for _WAR_Mode in ["yes", "no", "api", "config", "active", "menu", "late-api", "throw"]
	Test("API entry removal: " . _WAR_Mode . " (llm-api-remove-confirmation-source)",
		_WAR_RemovalRetainsSource.Bind(_WAR_Mode))
