; tests/unit/modules/hotstrings/engine/test_hotstring_injection_plan.ahk

; ==============================================================================
; MODULE: Hotstring Injection Plan Vectors (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/injection_plan_vectors.json through
; HSE_PlanBuild, as macOS and Linux do through hotstring_engine.injection_plan,
; then ties HSE_DispatchMatch to the plan: a dispatch whose erase, text or
; terminator the plan did not decide would pass the vectors and still diverge.
; ==============================================================================

#Requires AutoHotkey v2.0

; The vector count the three drivers' replayers are written for.
global _THIP_VECTOR_COUNT := 18

_THIP_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\injection_plan_vectors.json", "UTF-8"))
}

; The plan spells "none" as "", where the corpus spells it null.
_THIP_Plain(Value) {
	return Value == JSON_NULL ? "" : Value
}

_THIP_Request(Input) {
	Request := Input.Clone()
	if Request.Has("cascade") {
		Cascade := Request["cascade"].Clone()
		if Cascade.Has("tail")
			Cascade["tail"] := _THIP_Plain(Cascade["tail"])
		Request["cascade"] := Cascade
	}
	return Request
}

_THIP_AssertReplay(Id, Expected, Actual) {
	if (Expected == JSON_NULL) {
		AssertEqual(0, Actual, Id . ": no replay")
		return
	}
	Assert(Actual is Map, Id . ": a replay")
	AssertEqual(Expected.Count, Actual.Count, Id . ": replay fields")
	for Name, Value in Expected
		AssertEqual(Value, Actual[Name], Id . ": replay " . Name)
}

_THIP_Vectors() {
	Corpus := _THIP_Corpus()
	AssertEqual(_THIP_VECTOR_COUNT, Corpus["vectors"].Length, "the corpus holds another number of vectors")
	for Vector in Corpus["vectors"] {
		Id := Vector["id"]
		Plan := HSE_PlanBuild(_THIP_Request(Vector["input"]))
		Expect := Vector["expect"]
		AssertEqual(Expect["erase"], Plan["erase"], Id . ": erase")
		AssertEqual(Expect["text"], Plan["text"], Id . ": text")
		AssertEqual(_THIP_Plain(Expect["tail"]), Plan["tail"], Id . ": tail")
		_THIP_AssertReplay(Id, Expect["replay"], Plan["replay"])
		AssertEqual(Expect["buffer_suffix"], Plan["buffer_suffix"], Id . ": buffer suffix")
		AssertEqual(Expect["final_result"] ? 1 : 0, Plan["final_result"] ? 1 : 0, Id . ": final result")
	}
}
Test("hotstring injection plan: the 18 shared vectors (injection-plan)", _THIP_Vectors)

_THIP_Refusals() {
	AssertThrows(() => HSE_PlanEraseCount("x", 1, 1, true), "an unknown path is refused")
	AssertThrows(() => HSE_PlanEraseCount("auto", -1, 1, true), "a negative length is refused")
	AssertThrows(() => HSE_PlanEraseCount("auto", 1, 1, ""), "a missing event_on_screen is refused")
	AssertThrows(() => HSE_PlanBuild(Map("path", "auto", "trigger_len", 1, "event_len", 1,
		"event_on_screen", true)), "a missing replacement is refused")
}
Test("hotstring injection plan: refuses an unknown path and a malformed length (injection-plan)", _THIP_Refusals)





; ============================================
; ============================================
; ======= The dispatch reads the plan ========
; ============================================
; ============================================

; Fires one match on the cascade harness and returns the burst it injected.
_THIP_Fire(Flags, Trigger, Text, Typed, Expected) {
	_HCA_Run(1, _THIP_FireBody.Bind(Flags, Trigger, Text, Typed, Expected))
}

_THIP_FireBody(Flags, Trigger, Text, Typed, Expected) {
	global _HCA_Screen
	_HCA_Register(Flags, Trigger, Text)
	_HCA_Type(Typed)
	AssertEqual(Expected, _HCA_Screen, "the document after " . Trigger)
}

_THIP_DispatchFollowsThePlan() {
	; Each document only comes out when the burst erases what the plan counts.
	_THIP_Fire("*", "btw", "by the way", "xx btw", "xx by the way")
	_THIP_Fire("", "abc", "alphabet", "xx abc ", "xx alphabet ")
	_THIP_Fire("", "😀x", "ok", "a 😀x ", "a ok ")
	Body := _StripFullLineComments(_DriverFuncBody("HSE_DispatchMatch"))
	Assert(Body != "", "HSE_DispatchMatch must exist in the driver source")
	Assert(InStr(Body, "_HSE_ExpansionPlan(") > 0, "the dispatch must build the injection plan")
	Assert(InStr(Body, 'BSCount := Plan["erase"]') > 0, "the plan decides the erase")
	Assert(!InStr(Body, "_TextCodepointLength(Spec.Trigger"),
		"the dispatch must not count the erase on its own: the three drivers would drift apart")
	Assert(!InStr(Body, "HSE_CONSUMED_DELIMITERS"),
		"the dispatch must not decide the terminator replay on its own")
}
Test("hotstring injection plan: the dispatch erases and replays what the plan says (injection-plan)", _THIP_DispatchFollowsThePlan)

; A stale no-break-space flag belongs to the terminator path alone: the plan
; ignores it on the auto path, in the burst and in the buffer alike.
_THIP_AutoPathIgnoresNbsp() {
	AssertEqual(3, _HSE_ExpansionStripUnits(3, "", true), "auto path")
	AssertEqual(5, _HSE_ExpansionStripUnits(3, ":", true), "terminator path")
}
Test("hotstring injection plan: a stripped no-break space only widens the terminator path (injection-plan)", _THIP_AutoPathIgnoresNbsp)
