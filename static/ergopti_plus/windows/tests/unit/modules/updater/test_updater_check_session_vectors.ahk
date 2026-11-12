; tests/unit/modules/updater/test_updater_check_session_vectors.ahk

; ==============================================================================
; MODULE: Update Check Session Vectors (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/updater/check_session_vectors.json on the Windows
; host of the update-check window and on its rate-limit sentence, as the Lua
; session of macOS and Linux does (_shared/lua/test/check_session_contract.lua).
; ==============================================================================

#Requires AutoHotkey v2.0

_TUSV_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\updater\check_session_vectors.json", "UTF-8"))
}

; The answer of a phase as the Windows host receives it.
_TUSV_Answer(Corpus, Id, CheckOnly := false) {
	Answer := Corpus["answers"][Id].Clone()
	if (Id == "available")
		Answer["release"] := { Tag: Answer["latest"], RawJson: "{}", Body: Answer["body"] }
	if CheckOnly
		Answer["check_only"] := true
	return Answer
}

; Runs a scenario with the window captured and a manual check showing one phase.
_TUSV_InPhase(Corpus, Phase, Scenario) {
	global _UC_PresentFn, _UC_RequestId, _UC_State, _UC_Release, UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterTest_SaveRequestState()
	SavedPresent := _UC_PresentFn
	Shown := []
	_UC_PresentFn := (State) => (Shown.Push(State), true)
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false, "dev")
		UpdateCheck_Begin(Request, "v0.0.0-dev.144")
		if (Phase != "checking")
			UpdateCheck_ShowResult(Request, _TUSV_Answer(Corpus, Phase))
		Scenario.Call(Request, Shown)
	} finally {
		_UC_PresentFn := SavedPresent
		_UC_RequestId := 0, _UC_State := 0, _UC_Release := 0
		_UpdaterTest_RestoreRequestState(Saved)
	}
}

_TUSV_Actions() {
	Corpus := _TUSV_Corpus()
	Assert(Corpus["actions"].Length == UC_PAGE_ACTIONS.Count, "the vectors name every action of the host")
	for Rule in Corpus["actions"] {
		Assert(UC_PAGE_ACTIONS.Has(Rule["action"]), "the host knows " . Rule["action"])
		Allowed := Map()
		for Phase in Rule["phases"]
			Allowed[Phase] := true
		for Phase in ["checking", "up_to_date", "available", "no_release", "error"]
			_TUSV_InPhase(Corpus, Phase, _TUSV_ActionCase.Bind(Corpus, Rule["action"], Phase, Allowed.Has(Phase)))
	}
}
_TUSV_ActionCase(Corpus, Name, Phase, Expected, Request, Shown) {
	Reached := []
	Port(*) {
		Reached.Push(true)
		return true
	}
	Effects := Map("install", Port, "changelog", Port, "open_url", Port, "set_channel", Port,
		"report", Port, "open_log", Port, "close", Port)
	UpdateCheck_Perform(Name, Corpus["switch_channel"], Effects, false, , Corpus["link"])
	AssertEqual(Expected ? 1 : 0, Reached.Length ? 1 : 0, Name . " in " . Phase)
}
Test("update check session vectors: each action reaches its effect in its phases only (PAR-76)", _TUSV_Actions)

_TUSV_StateMessages() {
	Corpus := _TUSV_Corpus()
	Assert(Corpus["state_messages"].Length >= 5, "the corpus holds its messages")
	for Vector in Corpus["state_messages"]
		_TUSV_InPhase(Corpus, "checking", _TUSV_StateMessageCase.Bind(Corpus, Vector))
}
_TUSV_StateMessageCase(Corpus, Vector, Request, Shown) {
	UpdateCheck_ShowResult(Request, _TUSV_Answer(Corpus, Vector["answer"], Vector.Get("check_only", false)))
	Message := JsonParse(_UpdateCheck_StateJson(Shown[Shown.Length]))
	for Name, Value in Vector["expect"]
		AssertEqual(Value, Message[Name], Vector["id"] . ": " . Name)
	if Vector.Has("expect_notes") {
		for Name, Value in Vector["expect_notes"]
			AssertEqual(Value, Message["notes"][Name], Vector["id"] . ": notes." . Name)
	}
	for Name in Vector["absent"]
		AssertFalse(Message.Has(Name), Vector["id"] . " must not send " . Name)
}
Test("update check session vectors: the page receives the shared fields (PAR-76)", _TUSV_StateMessages)

_TUSV_RateLimit() {
	Corpus := _TUSV_Corpus()
	Assert(Corpus["rate_limit"].Length >= 9, "the corpus holds its limits")
	for Vector in Corpus["rate_limit"] {
		AssertEqual(Vector["detail"], _Updater_RateLimitDetail(Vector["status"], Vector.Get("remaining", ""),
			Vector.Get("reset", "")), Vector["id"])
	}
}
Test("update check session vectors: the exhausted rate limit reads the shared sentence (PAR-76)", _TUSV_RateLimit)
