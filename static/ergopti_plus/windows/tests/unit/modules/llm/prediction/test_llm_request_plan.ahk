; tests/unit/modules/llm/prediction/test_llm_request_plan.ahk

; ==============================================================================
; MODULE: LLM Request Plan Twin
; DESCRIPTION:
; Replays the shared request transcripts through the AutoHotkey twin, then pins
; how the engine uses it: "never" arms nothing, the user's floor holds automatic
; requests only, and the old per-backend floor is gone.
; ==============================================================================

#Requires AutoHotkey v2.0

_LReqPlan_Corpus(Name) {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\" . Name, "UTF-8"))
}

/** Whether Actual holds exactly Expected's decisions, in order. */
_LReqPlan_SameDecisions(Expected, Actual, Label) {
	AssertEqual(Expected.Length, Actual.Length, Label . ": decision count")
	for Index, Decision in Expected {
		AssertEqual(Decision.Count, Actual[Index].Count, Label . ": decision fields")
		for Key, Value in Decision
			AssertEqual(Value, Actual[Index].Get(Key, "(absent)"), Label . ": " . Key)
	}
}

_LReqPlan_Step(Plan, Step) {
	Args := Step.Get("args", Map())
	switch Step["call"] {
		case "configure": return Plan.Configure(Args)
		case "on_input": return Plan.OnInput(Args)
		case "on_cancel": return Plan.OnCancel()
		case "on_timer": return Plan.OnTimer(Args["token"])
		case "on_dispatch": return Plan.OnDispatch(Args, Step["now_ms"])
		case "on_explicit": return Plan.OnExplicit(Args)
		case "on_sent": return Plan.OnSent(Step["now_ms"])
		case "reset": return Plan.Reset()
	}
	throw Error("Unknown plan call in the corpus: " . Step["call"])
}

_LReqPlan_ReplayDebounceVectors() {
	Corpus := _LReqPlan_Corpus("request_plan_debounce_vectors.json")
	AssertTrue(Corpus["vectors"].Length > 0, "the corpus holds vectors")
	for Vector in Corpus["vectors"] {
		Floor := Vector["floor_ms"]
		Plan := LLMRequestPlan(() => Floor)
		for Index, Step in Vector["steps"] {
			Label := Vector["id"] . " step " . Index
			if Step.Has("expect_error") {
				Message := ""
				try _LReqPlan_Step(Plan, Step)
				catch as Err
					Message := Err.Message
				AssertContains(Message, Step["expect_error"], Label)
				continue
			}
			_LReqPlan_SameDecisions(Step["expect"], _LReqPlan_Step(Plan, Step), Label)
		}
	}
}
Test("LLM request plan: replays every shared debounce vector (par-65)", _LReqPlan_ReplayDebounceVectors)

_LReqPlan_ReplayBatchingVectors() {
	Corpus := _LReqPlan_Corpus("request_plan_batching_vectors.json")
	for Vector in Corpus["vectors"] {
		if Vector.Has("expect_error") {
			Message := ""
			try LLM_RequestPlanBatching(Vector["batch_profile"], Vector["requested"])
			catch as Err
				Message := Err.Message
			AssertContains(Message, Vector["expect_error"], Vector["id"])
			continue
		}
		Plan := LLM_RequestPlanBatching(Vector["batch_profile"], Vector["requested"])
		for Key, Value in Vector["expect"]
			AssertEqual(Value, Plan[Key], Vector["id"] . ": " . Key)
	}
}
Test("LLM request plan: replays every shared batching vector (par-65)", _LReqPlan_ReplayBatchingVectors)

/** Runs Body with a usable engine and a fresh plan, restoring both. */
_LReqPlan_WithEngine(Debounce, Floor, Body) {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		_LLM_Engine := SavedEngine.Clone()
		_LLM_Engine["enabled"] := true
		_LLM_Engine["debounce_ms"] := Debounce
		_LLM_Engine["min_request_interval_ms"] := Floor
		if _LLM_Engine.Has("request_plan")
			_LLM_Engine.Delete("request_plan")
		Body.Call()
	} finally {
		try LLM_Engine_CancelTimer()
		_LLM_Engine := SavedEngine
	}
}

_LReqPlan_NeverArmsNothing() {
	_LReqPlan_WithEngine(-1, 300, Run)
	Run() {
		Arms := []
		LLM_Engine_OnKeystroke("du texte", "", (Timer, Period) => Arms.Push(Period))
		LLM_Engine_OnKeystroke("du texte ", 0, (Timer, Period) => Arms.Push(Period))
		AssertEqual(0, Arms.Length, "a debounce of -1 turns the automatic trigger off")
		AssertFalse(_LLM_Engine["timer_active"])
	}
}
Test("LLM request plan: the stored -1 arms no automatic request (par-65)", _LReqPlan_NeverArmsNothing)

_LReqPlan_ConfiguredDebounceArms() {
	_LReqPlan_WithEngine(700, 300, Run)
	Run() {
		Arms := []
		LLM_Engine_OnKeystroke("du texte", "", (Timer, Period) => Arms.Push(Period))
		AssertEqual(1, Arms.Length)
		AssertEqual(-700, Arms[1], "the configured debounce is the delay")
	}
}
Test("LLM request plan: typing arms the configured debounce (par-65)", _LReqPlan_ConfiguredDebounceArms)

_LReqPlan_FloorHoldsAutomaticOnly() {
	_LReqPlan_WithEngine(500, 4000, Run)
	Run() {
		Now := 100000
		Plan := _LLM_Engine_Plan()
		Plan.OnSent(Now)
		Deferred := _LLM_Engine_DispatchDecision(0, Now + 1000)
		AssertEqual("defer", Deferred["action"], "an automatic request waits for the user's floor")
		AssertEqual(3000, Deferred["delay_ms"], "the wait comes from min_request_interval_ms")
		AssertEqual("defer", _LLM_Engine_DispatchDecision(Map("live", true), Now + 1000)["action"],
			"live mode's automatic trigger is held too")
		AssertEqual("send", _LLM_Engine_DispatchDecision(Map("profile_id", "p"), Now + 1000)["action"],
			"a prompt action the user triggered is never held")
		AssertEqual("send", _LLM_Engine_DispatchDecision(0, Now + 4000)["action"])
	}
}
Test("LLM request plan: the floor holds automatic requests only (par-65)", _LReqPlan_FloorHoldsAutomaticOnly)

_LReqPlan_OptionAcceptsNeverAndInterval() {
	AssertTrue(LLM_Option_TryNormalize("debounce_ms", -1, &Value))
	AssertEqual(-1, Value)
	for Bad in [-2, 0, 49, 10001]
		AssertFalse(LLM_Option_TryNormalize("debounce_ms", Bad, &Value), "debounce " . Bad)
	AssertTrue(LLM_Option_TryNormalize("min_request_interval_ms", 0, &Value), "0 turns the floor off")
	for Bad in [-1, 10001]
		AssertFalse(LLM_Option_TryNormalize("min_request_interval_ms", Bad, &Value), "interval " . Bad)
}
Test("LLM request plan: options accept -1 never and the interval range (par-65)", _LReqPlan_OptionAcceptsNeverAndInterval)

_LReqPlan_OldFloorIsGone() {
	global _SharedDir
	Inference := FileRead(_SharedDir . "\modules\llm\inference.json", "UTF-8")
	AssertFalse(InStr(Inference, "rate_limit_min_interval_ms"), "the per-backend floor left inference.json")
	AssertFalse(InStr(_DriverSourceConcat(), "GetRateLimitMs"), "its reader is gone with it")
}
Test("LLM request plan: the per-backend floor is gone (par-65)", _LReqPlan_OldFloorIsGone)
