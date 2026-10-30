; tests/unit/modules/llm/menu/test_llm_menu_test_prediction.ahk

; ==============================================================================
; MODULE: AI Menu Test Prediction
; DESCRIPTION:
; The AI menu's "Test a prediction" runs one prediction on a sample context with
; the active backend and shows the result or why it could not run. No model is
; involved: the requests stop at the backend seams.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body(Fx, Lines, Sent) with the AI on, its API backend ready.
_LTP_Run(Body) {
	_LAG_Run(_LAG_Menu("action", "", ""), _LTN_Screen(""), Body)
}

_LTP_Refusals() {
	_LTP_Run(_Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu
		Calls := []
		Send := (Args*) => Calls.Push(Args)
		_LLM_Menu["enabled"] := false
		AssertFalse(LLM_Menu_TestPrediction(Send), "the AI off refuses")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(), "and says why")
		_LLM_Menu["enabled"] := true
		_LLM_Menu["api_entry_id"] := "missing"
		AssertFalse(LLM_Menu_TestPrediction(Send), "a backend not ready refuses")
		AssertEqual(t("llm.manual_prediction.backend_not_ready"), _LPP_PendingNotice(), "and says why")
		_LLM_Menu["api_entry_id"] := "remote-a"
		Suspend(true)
		try AssertFalse(LLM_Menu_TestPrediction(Send), "a pause refuses")
		finally Suspend(false)
		AssertEqual(0, Calls.Length, "nothing was sent")
	}
}
Test("AI menu test prediction: a refusal says why and sends nothing (ai-test-prediction)", _LTP_Refusals)

_LTP_Result() {
	_LTP_Run(_Body)
	_Body(Fx, Lines, Sent) {
		global LLM_TEST_PREDICTION_EXCERPT_CHARS, _LLM_Bridge_Buffer
		Calls := []
		Typed := _LLM_Bridge_Buffer
		AssertTrue(LLM_Menu_TestPrediction((Args*) => Calls.Push(Args)), "the request leaves")
		AssertEqual(t("llm.test_prediction.running"), _LPP_PendingNotice(), "at once visible")
		AssertEqual(1, Calls.Length, "one request")
		AssertEqual(t("llm.test_prediction.sample"), Calls[1][1], "on the sample, never on what was typed")
		AssertEqual(Typed, _LLM_Bridge_Buffer, "the typed context is untouched")
		Calls[1][2].Call("  mardi à 14 h`n", "usage")
		AssertEqual(StrReplace(t("llm.test_prediction.result"), "{1}", "mardi à 14 h"), _LPP_PendingNotice(),
			"the trimmed answer is shown")
		AssertEqual(0, Sent.Length, "nothing is typed")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "mardi"), "and the answer is not logged")
		; A long answer is cut, a new test supersedes the old one's late answer.
		LLM_Menu_TestPrediction((Args*) => Calls.Push(Args))
		LLM_Menu_TestPrediction((Args*) => Calls.Push(Args))
		Before := _LPP_PendingNotice()
		Calls[2][2].Call("late")
		AssertEqual(Before, _LPP_PendingNotice(), "a superseded answer is dropped")
		Long := ""
		Loop LLM_TEST_PREDICTION_EXCERPT_CHARS + 5
			Long .= "x"
		Calls[3][2].Call(Long)
		AssertContains(_LPP_PendingNotice(), SubStr(Long, 1, LLM_TEST_PREDICTION_EXCERPT_CHARS) . "…", "cut with a mark")
	}
}
Test("AI menu test prediction: the answer is shown, cut, and only the newest one (ai-test-prediction)", _LTP_Result)

_LTP_Failure() {
	_LTP_Run(_Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu
		Calls := []
		Send := (Args*) => Calls.Push(Args)
		Failed(Reason) => StrReplace(t("llm.test_prediction.failed"), "{1}", Reason)
		LLM_Menu_TestPrediction(Send)
		Calls[1][3].Call(Map("reason", "quota exceeded"))
		AssertEqual(Failed("quota exceeded"), _LPP_PendingNotice(), "the backend's reason is shown")
		LLM_Menu_TestPrediction(Send)
		Calls[2][2].Call("   ")
		AssertEqual(Failed("the backend returned an empty answer"), _LPP_PendingNotice(), "a blank answer is a failure")
		AssertFalse(LLM_Menu_TestPrediction((*) => _AAG_Throw()), "a refused dispatch reports")
		AssertEqual(Failed("Controlled native refusal."), _LPP_PendingNotice(), "its cause")
		; The switch-off withdraws a test in flight.
		LLM_Menu_TestPrediction(Send)
		Before := _LPP_PendingNotice()
		_LLM_Menu["enabled"] := false
		Calls[3][2].Call("late")
		AssertEqual(Before, _LPP_PendingNotice(), "no result after the switch-off")
	}
}
Test("AI menu test prediction: a failure says why, the switch-off withdraws it (ai-test-prediction)", _LTP_Failure)

; The active backend's own seams receive the request.
_LTP_ActiveBackend() {
	_LTP_Run(_Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Menu, _LLM_Engine, _LLM_Engine_RemoteTransport
		SavedTransport := _LLM_Engine_RemoteTransport
		Remote := [], OnDevice := []
		try {
			_LLM_Engine_RemoteTransport := (Args*) => Remote.Push(Args)
			AssertTrue(LLM_Menu_TestPrediction())
			AssertEqual(1, Remote.Length, "the API backend's transport is asked")
			AssertEqual("remote-a", Remote[1][1]["Id"], "with the active entry")
			AssertEqual(t("llm.test_prediction.sample"), Remote[1][3], "on the sample")
			_LLM_Menu["backend"] := "ollama"
			_LLM_Menu["model"] := "local-a"
			_AAG_WithFn(LLM_OllamaGenerate_Async, (Self, Args*) => OnDevice.Push(Args), _SendLocal)
			AssertEqual(1, Remote.Length, "and the API one is not")
			AssertEqual(1, OnDevice.Length, "the local backend is asked")
			AssertEqual(t("llm.test_prediction.sample"), OnDevice[1][3], "on the sample")
		} finally _LLM_Engine_RemoteTransport := SavedTransport
		_SendLocal() {
			; Only the local readiness differs: the seam stands in for its probe.
			_AAG_WithFn(_LLM_Menu_BackendIsReadyForUse, (*) => true, () => AssertTrue(LLM_Menu_TestPrediction()))
		}
	}
}
Test("AI menu test prediction: the request reaches the active backend (ai-test-prediction)", _LTP_ActiveBackend)

_LTP_MenuRow() {
	Row := 0
	for _, Entry in _MR_GetMenuDef("llm_menu") {
		if (Entry is Map && _MR_Get(Entry, "id", "") == "llm_test_prediction")
			Row := Entry
	}
	AssertTrue(Row is Map, "the AI menu declares the row")
	AssertTrue(_MR_IsForAhk(Row), "on Windows")
	Assert(t("menu.llm.test_prediction") != "menu.llm.test_prediction", "with its text")
	Body := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Assert(Body != "", "the builder must exist")
	AssertContains(Body, 'Commands["llm_test_prediction"] := (*) => LLM_Menu_TestPrediction()', "wired to the action")
}
Test("AI menu test prediction: the menu declares and wires the row (ai-test-prediction)", _LTP_MenuRow)
