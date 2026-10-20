; tests/unit/modules/llm/api/test_llm_api_post_save_owner.ahk

; ==============================================================================
; MODULE: Saved API-entry validation ownership regression tests
; DESCRIPTION:
; Acknowledges real native saves, then publishes another actual joint transaction
; while the optional test offer is open. The old continuation cannot re-authorize
; the removed credentials. Real readiness dispatch uses passive HTTP ports only.
; ==============================================================================

#Requires AutoHotkey v2.0

_WAPO_Mutate(State, Candidate) {
	if State.Mode == "delete"
		return _LLM_Menu_RemoveApiEntryCandidate(Candidate, State.SavedEntry["Id"])
	Entry := State.SavedEntry.Clone()
	Entry["BaseUrl"] := "http://127.0.0.1:8100/v1"
	Entry["Token"] := "independent-replacement-token"
	Entry["Model"] := "independent-replacement-model"
	Entry["Name"] := "independent replacement"
	return _LLM_Menu_UpsertApiEntryCandidate(Candidate, Entry, Entry["Id"])
}

_WAPO_Publish(State) {
	Options := State.Form.World.Owner.Options
	Owner := LLM_Menu_ApiPrivateSourceOwner(Options)
	Receipt := Owner.Capture()
	AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt, "The second action must capture the actual acknowledged native files.")
	AssertTrue(LLM_Menu_CommitApiEntriesMutation("the independent post-offer mutation",
		_WAPO_Mutate.Bind(State), Options["apply"], Owner.Port, Options["notify"],
		Options["acquire"], Options["settle"], Options["collect"], Options["build_config"],
		Options["serialize"], Options["pause"], Receipt, Owner, (*) => true),
		"The replacement action must really commit, not merely change an epoch or fake admission.")
	State.SecondCommits += 1
}

_WAPO_CheckFields(State) {
	global _LLM_Menu
	Entry := _LLM_Menu["api_entries"][3]
	AssertTrue(_LLM_Menu_SavedApiEntryCurrent(State.OriginalOwner, _LLM_Menu,
		State.SavedEntry, LLM_AuxGeneration()), "The unchanged saved entry must qualify before negative controls.")
	for Field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"] {
		Original := Entry[Field]
		try {
			Entry[Field] := StrUpper(Original)
			AssertTrue(!(Entry[Field] == Original), "Every case-sensitive field control must actually differ.")
			AssertFalse(_LLM_Menu_SavedApiEntryCurrent(State.OriginalOwner, _LLM_Menu,
				State.SavedEntry, LLM_AuxGeneration()), "Even a case-only change must withdraw the saved entry: " . Field)
			Entry[Field] := true
			AssertFalse(_LLM_Menu_SavedApiEntryCurrent(State.OriginalOwner, _LLM_Menu,
				State.SavedEntry, LLM_AuxGeneration()), "A non-string may not coerce into a saved credential field: " . Field)
			State.FieldChecks += 2
		} finally Entry[Field] := Original
	}
	AssertTrue(_LLM_Menu_SavedApiEntryCurrent(State.OriginalOwner, _LLM_Menu,
		State.SavedEntry, LLM_AuxGeneration()), "Restored exact fields must retain the original owner.")
}

_WAPO_Ask(State) {
	global _LLM_Menu, _LLM_AuxOwners
	State.AskCalls += 1
	State.SavedEntry := _LLM_Menu["api_entries"][3].Clone()
	State.SavedApi := FSReadUtf8Exact(State.Form.World.ApiPath)
	State.SavedConfig := FSReadUtf8Exact(State.Form.World.ConfigPath)
	AssertEqual(3, JsonParse(State.SavedApi).Length, "The actual first save must precede the offer.")
	AssertFalse(_ConfigWriteTerminalIsActive(), "The first transaction must settle before another action can enter.")
	Kind := "api_validation:" . State.SavedEntry["Id"]
	AssertTrue(_LLM_AuxOwners.Has(Kind), "The validation owner must exist before any modal answer can pump a replacement.")
	State.OriginalOwner := _LLM_AuxOwners[Kind]
	AssertTrue(LLM_AuxIsCurrent(State.OriginalOwner))
	if State.Mode == "replace" || State.Mode == "delete"
		_WAPO_Publish(State)
	else if State.Mode == "off-on" {
		Suspend(true)
		LLM_AuxInvalidate("suspend")
		Suspend(false)
	} else if State.Mode == "guard-fields"
		_WAPO_CheckFields(State)
	else if State.Mode == "offer-error"
		throw Error("independent optional offer failure")
	return State.Mode == "yes" || State.Mode == "replace" || State.Mode == "delete"
		|| State.Mode == "off-on" || State.Mode == "after-test-replace"
}

_WAPO_Test(State, Unused, EntryId) {
	State.TestCalls += 1
	AssertEqual(State.SavedEntry["Id"], EntryId, "Only the exact saved entry may reach the full-test callback.")
	if State.Mode == "after-test-replace"
		_WAPO_Publish(State)
	return true
}

_WAPO_Resolve(State, Url, Callback) {
	if State.Mode == "late-transport"
		_WAPO_Publish(State)
	return _WAA_ReadyResolve(Url, Callback)
}

_WAPO_Ready(State, Entry, Callback, Owner) {
	State.ReadyCalls += 1
	AssertTrue(Owner == State.OriginalOwner, "Readiness must receive the owner captured before the offer.")
	AssertTrue(HasMethod(Callback, "Call"), "The actual validation handler must be bound for dispatch.")
	Port := Map("resolve_proxy", _WAPO_Resolve.Bind(State),
		"create_http", _WAA_ReadyCreate.Bind(State.Http, 200, '{"data":[]}'))
	LLM_RemoteIsReady_Async(Entry, _WAPO_Result.Bind(State), Owner, Port)
}

_WAPO_Result(State, Value) {
	State.Results.Push(Value)
}

_WAPO_ActualSaveOffer(Mode) {
	return _ManagedRemoteFixtureWithLlmTimings(_WAPO_ActualSaveOfferBody.Bind(Mode))
}

_WAPO_ActualSaveOfferBody(Mode) {
	global _LLM_Menu, _LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners
	global _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	Saved := { Generation: _LLM_AuxGeneration, Counter: _LLM_AuxOwnerCounter,
		Owners: _LLM_AuxOwners, Debt: _LLM_AuxCleanupDebt, DebtCounter: _LLM_AuxCleanupDebtCounter,
		Suspended: A_IsSuspended }
	Form := _WAA_Form("openai")
	PreviousCritical := Critical("On")
	State := { Mode: Mode, Form: Form, AskCalls: 0, TestCalls: 0, ReadyCalls: 0,
		SecondCommits: 0, FieldChecks: 0, OriginalOwner: 0, SavedEntry: 0,
		SavedApi: "", SavedConfig: "", Results: [],
		Http: Map("creates", 0, "opens", 0, "sends", 0, "aborts", 0, "headers", Map()) }
	try {
		Suspend(false)
		_LLM_AuxOwners := Map()
		_LLM_AuxCleanupDebt := Map()
		if Mode == "disabled"
			_LLM_Menu["enabled"] := false
		Form.Port["ask_test"] := _WAPO_Ask.Bind(State)
		Form.Port["test_entry"] := _WAPO_Test.Bind(State)
		Form.Port["ready"] := _WAPO_Ready.Bind(State)
		AssertTrue(Form.Run(), "Optional stale post-save work cannot undo an acknowledged native save.")
		AssertEqual(4, Form.Inputs.Length)
		AssertEqual(1, State.AskCalls, "The actual four-step form must reach its post-save offer.")
		Retired := Mode == "replace" || Mode == "delete" || Mode == "off-on" || Mode == "after-test-replace"
		AssertEqual(!Retired, State.ReadyCalls, "Only an unchanged offer continuation may enter readiness.")
		Sends := !Retired && Mode != "late-transport"
		AssertEqual(Sends, State.Http["creates"], "Retired ownership must block HTTP creation at the real transport fence.")
		AssertEqual(Sends, State.Http["opens"])
		AssertEqual(Sends, State.Http["sends"], "No removed or replaced credentials may be sent.")
		AssertEqual(Sends, State.Results.Length)
		if Sends {
			AssertTrue(State.Results[1])
			AssertEqual("Bearer  private form token ", State.Http["headers"]["Authorization"],
				"Stable validation must preserve the exact saved credential, including spaces.")
		}
		AssertEqual(Mode == "yes" || Mode == "after-test-replace", State.TestCalls,
			"No declines only the full probe; stale Yes cannot test a later entry by its reused id.")
		AssertEqual(1 + State.SecondCommits, Form.World.ApplyCalls, "Each asserted replacement must be an actual applied native commit.")
		AssertEqual(Mode == "replace" || Mode == "delete" || Mode == "after-test-replace" || Mode == "late-transport",
			State.SecondCommits, "Every replacement scenario must exercise the genuine second publication.")
		if !State.SecondCommits {
			AssertEqual(State.SavedApi, FSReadUtf8Exact(Form.World.ApiPath))
			AssertEqual(State.SavedConfig, FSReadUtf8Exact(Form.World.ConfigPath))
		}
		if Mode == "guard-fields"
			AssertEqual(12, State.FieldChecks, "All six exact typed fields require non-vacuous negative controls.")
		AssertFalse(LLM_AuxIsCurrent(State.OriginalOwner), "Validation completion or refusal must settle its exact captured owner.")
		AssertEqual(0, _LLM_AuxOwners.Count, "No post-save validation owner may leak after terminal refusal or completion.")
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertEqual(0, Form.Notices.Length, "An accepted first save and owned second action must not report persistence failure.")
	} finally {
		try {
			LLM_AuxInvalidate("post_save_offer_fixture")
			Form.Restore()
		} finally {
			Form.Port := 0
			State.Form := 0
			_LLM_AuxGeneration := Saved.Generation
			_LLM_AuxOwnerCounter := Saved.Counter
			_LLM_AuxOwners := Saved.Owners
			_LLM_AuxCleanupDebt := Saved.Debt
			_LLM_AuxCleanupDebtCounter := Saved.DebtCounter
			Suspend(Saved.Suspended)
			Critical(PreviousCritical)
		}
	}
}
for _WAPO_Mode in ["yes", "no", "disabled", "offer-error", "replace", "delete", "off-on", "after-test-replace", "late-transport", "guard-fields"]
	Test("Saved API validation: " . _WAPO_Mode . " (llm-api-post-save-validation-owner)",
		_WAPO_ActualSaveOffer.Bind(_WAPO_Mode))
