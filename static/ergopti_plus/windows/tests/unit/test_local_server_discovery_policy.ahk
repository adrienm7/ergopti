; tests/unit/test_local_server_discovery_policy.ahk

; ==============================================================================
; MODULE: Local Server Discovery Policy Tests
; DESCRIPTION:
; Replays the unchanged independent Lua-driver corpus through the shared AHK
; controller. Controlled callbacks additionally exercise reentrant publication,
; superseding dispatch and logical tickets without claiming native retirement.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ Independent Trace Fixture =======
; ============================================
; ============================================

class _LSD_Fixture {
	__New(Order, MaxAge) {
		this.ClockValue := 0
		this.MaxAge := MaxAge
		this.Calls := Map()
		this.Targets := Map()
		this.Done := []
		this.Errors := []
		this.Published := 0
		this.BeforeProbe := 0
		this.BeforePublish := 0
		this.BeforeClock := 0
		this.CallbackCritical := []
		this.Controller := LocalServerDiscoveryController(Map("order", Order,
			"clock", ObjBindMethod(this, "Clock"), "max_age", ObjBindMethod(this, "Age"),
			"on_publish", ObjBindMethod(this, "Publish"), "on_error", ObjBindMethod(this, "Report")))
	}

	Clock() {
		this.CallbackCritical.Push(A_IsCritical)
		if HasMethod(this.BeforeClock, "Call")
			this.BeforeClock.Call()
		return this.ClockValue
	}

	Age() {
		this.CallbackCritical.Push(A_IsCritical)
		return this.MaxAge
	}

	Publish(Results, Changed) {
		this.CallbackCritical.Push(A_IsCritical)
		this.Published += 1
		if HasMethod(this.BeforePublish, "Call")
			this.BeforePublish.Call(Results, Changed)
	}

	Report(Kind, Detail, Id) {
		this.CallbackCritical.Push(A_IsCritical)
		this.Errors.Push(Kind)
	}

	Probe(Step, Target, Settle, Ticket) {
		this.CallbackCritical.Push(A_IsCritical)
		this.Calls[Step["name"]][Target["id"]] := Map(
			"target", Target, "settle", Settle, "ticket", Ticket)
		if HasMethod(this.BeforeProbe, "Call")
			this.BeforeProbe.Call(Step, Target, Settle, Ticket)
		if _LSD_Contains(Step.Get("throw", []), Target["id"])
			throw Error("injected probe refusal")
		Synchronous := Step.Get("sync", Map())
		if Synchronous.Has(Target["id"])
			Settle.Call(Synchronous[Target["id"]])
		return !_LSD_Contains(Step.Get("refuse", []), Target["id"])
	}

	Observer(Step, Changed) {
		this.CallbackCritical.Push(A_IsCritical)
		this.Done.Push(Map("name", Step["name"], "changed", Changed))
		if Step.Get("observer_throws", false)
			throw Error("injected observer failure")
	}

	Sweep(Step) {
		this.Calls[Step["name"]] := Map()
		this.Targets[Step["name"]] := Step["targets"]
		return this.Controller.Sweep(Step["targets"], ObjBindMethod(this, "Probe", Step),
			ObjBindMethod(this, "Observer", Step))
	}

	Answer(Name, Id, Response) {
		Settle := this.Calls[Name][Id]["settle"]
		Settle.Call(Response)
	}

	Snapshot() {
		return Map("active", this.Controller.IsSweeping(), "stale", this.Controller.IsStale(),
			"detected", this.Controller.Detected(), "done", this.Done,
			"published", this.Published, "results", this.Controller.Results, "errors", this.Errors)
	}
}

_LSD_Contains(Values, Wanted) {
	for Value in Values
		if Value == Wanted
			return true
	return false
}

; A trace names only the observations it intends to assert at each boundary.
; Arrays are exact, including length; maps permit explicitly omitted observations.
_LSD_AssertTrace(Expected, Actual, Context) {
	if Expected is Array {
		AssertTrue(Actual is Array, Context . " must be an array")
		AssertEqual(Expected.Length, Actual.Length, Context . " length")
		for Index, Value in Expected
			_LSD_AssertTrace(Value, Actual[Index], Context . "[" . Index . "]")
	} else if Expected is Map {
		AssertTrue(Actual is Map, Context . " must be a map")
		for Key, Value in Expected {
			AssertTrue(Actual.Has(Key), Context . " owns " . Key)
			_LSD_AssertTrace(Value, Actual[Key], Context . "." . Key)
		}
	} else {
		AssertEqual(Expected, Actual, Context)
	}
}

_LSD_Replay(Vector, Corpus) {
	Fixture := _LSD_Fixture(Corpus["order"], Corpus["max_age"])
	for Index, Step in Vector["steps"] {
		switch Step["kind"] {
			case "sweep":
				AssertTrue(Fixture.Sweep(Step), "the logical trace sweep is accepted")
			case "answer":
				Fixture.Answer(Step["sweep"], Step["id"], Step["response"])
			case "clock":
				Fixture.ClockValue := Step["value"]
			case "mutate":
				Target := Fixture.Targets[Step["sweep"]][Step["index"]]
				for Key, Value in Step["fields"]
					Target[Key] := Value
			default:
				throw Error("The independent trace contains an unsupported step.")
		}
		if Step.Has("expected")
			_LSD_AssertTrace(Step["expected"], Fixture.Snapshot(), Vector["name"] . " step " . Index)
	}
}

_LSD_RegisterCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\local_server_discovery.json", "UTF-8"))
	if Corpus["version"] != 1 || Corpus["cases"].Length != 8
		throw Error("The independent local discovery corpus requires explicit review.")
	for Vector in Corpus["cases"]
		Test("local discovery corpus: " . Vector["name"], _LSD_Replay.Bind(Vector, Corpus))
}
_LSD_RegisterCorpus()





; ===================================================
; ===================================================
; ======= 2/ Reentrancy And Ticket Boundaries =======
; ===================================================
; ===================================================

_LSD_Step(Name, Ids*) {
	Targets := []
	for Id in Ids
		Targets.Push(Map("id", Id, "base_url", "http://fixture.invalid/" . Id))
	return Map("kind", "sweep", "name", Name, "targets", Targets)
}

_LSD_Models(Model := "model") {
	return Map("ok", true, "status", 200,
		"body", '{"data":[{"id":"' . Model . '"}]}')
}

_LSD_ReenterProbe(Fixture, Step, Target, Settle, Ticket) {
	if Step["name"] == "old" && Target["id"] == "omlx"
		Fixture.Sweep(_LSD_Step("new", "jan"))
}

_LSD_ReentrantDispatch() {
	Fixture := _LSD_Fixture(["omlx", "lmstudio", "jan"], 30)
	Fixture.BeforeProbe := _LSD_ReenterProbe.Bind(Fixture)
	Fixture.Sweep(_LSD_Step("old", "omlx", "lmstudio"))
	AssertEqual(1, Fixture.Calls["old"].Count, "the superseded loop cannot dispatch its second native owner")
	AssertTrue(Fixture.Calls["new"].Has("jan"), "the reentrant successor acquires its own probe")
	Fixture.Answer("old", "omlx", _LSD_Models("obsolete"))
	AssertEqual(0, Fixture.Published, "a stale callback cannot publish")
	Fixture.Answer("new", "jan", _LSD_Models("current"))
	_LSD_AssertTrace(["jan"], Fixture.Controller.Detected(), "newest catalogue result")
	_LSD_AssertTrace([Map("name", "old", "changed", true), Map("name", "new", "changed", true)],
		Fixture.Done, "superseded observers receive the newest committed result")
}
Test("local discovery: reentrant acquisition stops the superseded dispatch loop", _LSD_ReentrantDispatch)

_LSD_ReenterPublish(Fixture, Results, Changed) {
	if Fixture.Published == 1
		Fixture.Sweep(_LSD_Step("new", "jan"))
}

_LSD_ReentrantPublication() {
	Fixture := _LSD_Fixture(["omlx", "jan"], 30)
	Fixture.BeforePublish := _LSD_ReenterPublish.Bind(Fixture)
	Fixture.Sweep(_LSD_Step("old", "omlx"))
	Fixture.Answer("old", "omlx", _LSD_Models())
	AssertTrue(Fixture.Controller.IsSweeping(), "publication starts a separate live successor")
	_LSD_AssertTrace([Map("name", "old", "changed", true)], Fixture.Done,
		"the old publication cannot consume its successor's observer")
	Fixture.Answer("new", "jan", _LSD_Models())
	_LSD_AssertTrace([Map("name", "old", "changed", true), Map("name", "new", "changed", true)],
		Fixture.Done, "each publication acknowledges only its detached observers")
}
Test("local discovery: publication detaches observers before reentrant sweeps", _LSD_ReentrantPublication)

_LSD_TicketCurrent(Ticket) {
	Current := Ticket["is_current"]
	return Current.Call()
}

_LSD_TicketsAndInvalidation() {
	Fixture := _LSD_Fixture(["omlx", "jan"], 30)
	Fixture.Sweep(_LSD_Step("first", "omlx"))
	First := Fixture.Calls["first"]["omlx"]["ticket"]
	AssertTrue(_LSD_TicketCurrent(First), "a pending captured probe has a live logical ticket")
	Fixture.Answer("first", "omlx", _LSD_Models("retained"))
	AssertFalse(_LSD_TicketCurrent(First), "settlement retires the exact ticket")
	Fixture.Sweep(_LSD_Step("old", "jan"))
	Old := Fixture.Calls["old"]["jan"]["ticket"]
	Fixture.Sweep(_LSD_Step("new", "jan"))
	NewTicket := Fixture.Calls["new"]["jan"]["ticket"]
	AssertFalse(_LSD_TicketCurrent(Old), "a successor invalidates earlier logical tickets")
	AssertTrue(_LSD_TicketCurrent(NewTicket))
	Fixture.Controller.Invalidate()
	AssertFalse(_LSD_TicketCurrent(NewTicket), "invalidation fences the pending callback")
	AssertFalse(Fixture.Controller.IsSweeping())
	AssertTrue(Fixture.Controller.IsStale())
	AssertEqual("retained", Fixture.Controller.Result("omlx")["models"][1], "invalidation preserves the last cache")
	Fixture.Answer("new", "jan", _LSD_Models("obsolete"))
	AssertEqual(1, Fixture.Published, "late response cannot acknowledge logical or native retirement")
	AssertEqual(1, Fixture.Done.Length, "invalidated observers are abandoned")
	AssertTrue(Fixture.Calls["new"].Has("jan"), "the fixture still retains its opaque native call")
}
Test("local discovery: tickets settle and invalidate without retiring native resources", _LSD_TicketsAndInvalidation)

_LSD_CaseIdentityAndOrderSnapshot() {
	Order := ["omlx"]
	Fixture := _LSD_Fixture(Order, 30)
	Order[1] := "jan"
	Fixture.Sweep(_LSD_Step("first", "omlx"))
	Fixture.Answer("first", "omlx", _LSD_Models("Model"))
	_LSD_AssertTrace(["omlx"], Fixture.Controller.Detected(), "captured catalogue order")
	Fixture.Sweep(_LSD_Step("case", "omlx"))
	Fixture.Answer("case", "omlx", _LSD_Models("model"))
	AssertTrue(Fixture.Done[2]["changed"], "model identifiers preserve Lua's case-sensitive identity")
	Step := _LSD_Step("address", "omlx")
	Step["targets"][1]["base_url"] := "http://fixture.invalid/OMLX"
	Fixture.Sweep(Step)
	Fixture.Answer("address", "omlx", _LSD_Models("model"))
	AssertTrue(Fixture.Done[3]["changed"], "address bytes preserve Lua's case-sensitive identity")
}
Test("local discovery: catalogue snapshots and verdict identity preserve case", _LSD_CaseIdentityAndOrderSnapshot)

_LSD_ReenterClock(Fixture, Synchronous) {
	if Fixture.ClockReentered
		return
	Fixture.ClockReentered := true
	Step := _LSD_Step("new", "jan")
	if Synchronous
		Step["sync"] := Map("jan", _LSD_Models("successor"))
	Fixture.Sweep(Step)
}

_LSD_ReentrantClockCase(Synchronous) {
	Fixture := _LSD_Fixture(["omlx", "jan"], 30)
	Fixture.ClockReentered := false
	Fixture.BeforeClock := _LSD_ReenterClock.Bind(Fixture, Synchronous)
	Fixture.Sweep(_LSD_Step("old", "omlx"))
	Fixture.Answer("old", "omlx", _LSD_Models("obsolete"))
	if !Synchronous {
		AssertTrue(Fixture.Controller.IsSweeping(), "a reentrant clock leaves the newer sweep active")
		AssertFalse(Fixture.Controller.Result("omlx") is Map, "the interrupted old result never publishes")
		AssertEqual(0, Fixture.Done.Length, "a refused old finish cannot consume successor observers")
		AssertEqual(0, Fixture.Published)
		Fixture.Answer("new", "jan", _LSD_Models("successor"))
	}
	AssertEqual(1, Fixture.Published, "only the successor's exact generation may publish")
	AssertEqual("successor", Fixture.Controller.Result("jan")["models"][1])
	AssertFalse(Fixture.Controller.Result("omlx") is Map, "the old finish cannot overwrite an already completed successor")
	_LSD_AssertTrace([Map("name", "old", "changed", true), Map("name", "new", "changed", true)],
		Fixture.Done, "the successor retains and acknowledges both pending observers once")
}
Test("local discovery: reentrant clock cannot publish or detach a pending successor", _LSD_ReentrantClockCase.Bind(false))
Test("local discovery: reentrant clock cannot overwrite a synchronously completed successor", _LSD_ReentrantClockCase.Bind(true))

_LSD_CompleteAgedSuccessor(Fixture) {
	if Fixture.ClockReentered
		return
	Fixture.ClockReentered := true
	Step := _LSD_Step("successor", "jan")
	Step["sync"] := Map("jan", _LSD_Models("aged-successor"))
	Fixture.Sweep(Step)
	; The inner publication read time zero. The outer age observation occurs
	; later and must compare time 31 with that actual successor timestamp.
	Fixture.ClockValue := 31
}

_LSD_ReentrantStaleClock() {
	Fixture := _LSD_Fixture(["omlx", "jan"], 30)
	Fixture.Sweep(_LSD_Step("first", "omlx"))
	Fixture.Answer("first", "omlx", _LSD_Models())
	Fixture.ClockReentered := false
	Fixture.BeforeClock := _LSD_CompleteAgedSuccessor.Bind(Fixture)
	AssertTrue(Fixture.Controller.IsStale(), "a completed successor checked at zero is stale at 31 with maximum age 30")
	AssertEqual(0, Fixture.Controller.CheckedAt, "the inner successor actually published its own zero timestamp")
	AssertEqual(31, Fixture.ClockValue, "the outer clock returned the later observation")
	AssertEqual(2, Fixture.Published, "the clock callback completed exactly one successor")
	AssertFalse(Fixture.Controller.IsSweeping())
	AssertEqual("aged-successor", Fixture.Controller.Result("jan")["models"][1], "age is evaluated against the actual newest cache")
}
Test("local discovery: reentrant clock evaluates the completed successor's actual age", _LSD_ReentrantStaleClock)

_LSD_CallerCriticalCase(InitialCritical) {
	Fixture := _LSD_Fixture(["omlx", "jan"], 30)
	PreviousCritical := Critical(InitialCritical)
	try {
		ExpectedCritical := A_IsCritical
		Fixture.Sweep(_LSD_Step("first", "omlx"))
		AssertEqual(ExpectedCritical, A_IsCritical, "sweep restores the exact caller Critical interval")
		Ticket := Fixture.Calls["first"]["omlx"]["ticket"]
		AssertTrue(_LSD_TicketCurrent(Ticket))
		AssertEqual(ExpectedCritical, A_IsCritical, "ticket observation restores the caller")
		Fixture.Answer("first", "omlx", _LSD_Models())
		AssertEqual(ExpectedCritical, A_IsCritical, "JSON classification and publication restore the caller")
		AssertFalse(Fixture.Controller.IsStale())
		AssertEqual(ExpectedCritical, A_IsCritical, "clock and age callbacks restore the caller")
		Refused := _LSD_Step("refused", "jan")
		Refused["throw"] := ["jan"]
		Refused["observer_throws"] := true
		Fixture.Sweep(Refused)
		AssertEqual(ExpectedCritical, A_IsCritical, "producer and observer exceptions restore the caller")
		Fixture.Controller.Invalidate()
		AssertEqual(ExpectedCritical, A_IsCritical, "logical invalidation restores the caller")
		AssertTrue(Fixture.CallbackCritical.Length > 0, "actual callbacks must have been observed")
		for Observed in Fixture.CallbackCritical
			AssertEqual(0, Observed, "no injected producer, clock, age, publication, observer or error callback runs Critical")
	} finally Critical(PreviousCritical)
}
Test("local discovery: callbacks run outside Critical and restore a non-Critical caller", _LSD_CallerCriticalCase.Bind("Off"))
Test("local discovery: callbacks run outside Critical and restore the exact Critical interval", _LSD_CallerCriticalCase.Bind(37))
