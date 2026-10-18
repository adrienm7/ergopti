; tests/unit/modules/llm/api/test_llm_api_ollama_local_presence.ahk

; ==============================================================================
; MODULE: Ollama Port and Local Model Presence
; DESCRIPTION:
; LLM_Ollama_SetPort validates the configurable port, and the local model
; presence preflight settles missing, installed, unknown, cancelled and
; superseded models before any private payload or POST.
; ==============================================================================

#Requires AutoHotkey v2.0





_OllamaSetPort_ValidApplies() {
	global LLM_OLLAMA_BASE_URL
	ok := LLM_Ollama_SetPort(13434)
	AssertTrue(ok, "a valid in-range port must be accepted")
	AssertEqual("http://localhost:13434", LLM_OLLAMA_BASE_URL, "base URL must rebuild from the new port")
	LLM_Ollama_SetPort(11434)  ; restore the default for downstream tests
}
Test("LLM_Ollama_SetPort: valid port applies and rebuilds the base URL", _OllamaSetPort_ValidApplies)


_OllamaSetPort_RejectsLow() {
	global LLM_OLLAMA_BASE_URL
	LLM_Ollama_SetPort(11434)
	ok := LLM_Ollama_SetPort(80)
	AssertFalse(ok, "privileged ports below 1024 must be rejected")
	AssertEqual("http://localhost:11434", LLM_OLLAMA_BASE_URL, "a rejected port must leave the URL unchanged")
}
Test("LLM_Ollama_SetPort: rejects ports below 1024", _OllamaSetPort_RejectsLow)


_OllamaSetPort_RejectsHigh() {
	LLM_Ollama_SetPort(11434)
	AssertFalse(LLM_Ollama_SetPort(70000), "ports above 65535 must be rejected")
}
Test("LLM_Ollama_SetPort: rejects ports above 65535", _OllamaSetPort_RejectsHigh)


_OllamaSetPort_RejectsNonInteger() {
	LLM_Ollama_SetPort(11434)
	AssertFalse(LLM_Ollama_SetPort("abc"), "non-integer input must be rejected")
}
Test("LLM_Ollama_SetPort: rejects non-integer input", _OllamaSetPort_RejectsNonInteger)


_OllamaLocalPresenceCorpus() {
	global _SharedDir, JSON_NULL
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\local_model_presence.json", "UTF-8"))
	for Vector in Corpus["normalization"]
		AssertEqual(Vector["expected"] == JSON_NULL ? "" : Vector["expected"],
			LLM_LocalModelNormalize(Vector["name"]), "independent normalization: " . Vector["name"])
	for Vector in Corpus["missing_responses"]
		AssertEqual(Vector["expected"] == JSON_NULL ? "" : Vector["expected"],
			LLM_LocalModelMissing(Vector["status"], Vector["error"]), "independent provider classification")
	for Vector in Corpus["lists"] {
		Receipt := LLM_LocalModelListReceipt(Vector)
		if Vector.Has("reason") {
			AssertFalse(Receipt["ok"], "unknown lists must not become valid empty lists")
			AssertEqual(Vector["reason"], Receipt["reason"])
		} else {
			AssertTrue(Receipt["ok"], "canonical empty or installed models are known")
			AssertEqual(Vector["names"].Length, Receipt["names"].Count)
			for Name in Vector["names"]
				AssertTrue(Receipt["names"].Has(Name), "both exact name fields are independently specified")
		}
	}
}
Test("Ollama local presence: replays the independent shared model corpus (todo-46-local-model)", _OllamaLocalPresenceCorpus)

_OllamaPresenceRecordList(State, Callback, Owner, Strict) {
	State["tags"] += 1
	State["strict"] := Strict
	State["callback"] := Callback
	State["owner"] := Owner
	LLM_AuxBindResources(Owner, Map("finalizer", Owner["on_retired"]))
}

_OllamaPresenceRecordSchedule(State, Callback, Period) {
	State["timer"] := Callback
	State["period"] := Period
}

_OllamaPresenceRecordSpawn(State, *) {
	State["posts"] += 1
}

_OllamaPresenceRecordFailure(State, Failure := "") {
	State["failures"].Push(Failure)
}

; Uses the real public chat dispatcher and reserved slot. Only the owned timer,
; tags transport and post-admission spawn cross deterministic fixture boundaries.
_OllamaPresenceWithFixture(Body) {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_PreflightPort
	global _LLM_AuxGeneration, _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_Engine
	Saved := Map("async", _LLM_Ollama_Async, "pending", _LLM_Ollama_Pending, "port", _LLM_Ollama_PreflightPort,
		"generation", _LLM_AuxGeneration, "owners", _LLM_AuxOwners, "debt", _LLM_AuxCleanupDebt, "engine", _LLM_Engine)
	State := Map("tags", 0, "posts", 0, "failures", [], "timer", 0, "owner", 0)
	try {
		_LLM_Ollama_Async := Map()
		_LLM_Ollama_Pending := ""
		_LLM_AuxOwners := Map()
		_LLM_AuxCleanupDebt := Map()
		_LLM_Engine := Map("enabled", true)
		_LLM_Ollama_PreflightPort := Map("schedule", _OllamaPresenceRecordSchedule.Bind(State),
			"list_models", _OllamaPresenceRecordList.Bind(State), "spawn", _OllamaPresenceRecordSpawn.Bind(State))
		Id := LLM_OllamaChat_Async('{"model":"QWEN2.5","messages":[{"role":"user","content":"private text"}]}',
			(*) => 0, _OllamaPresenceRecordFailure.Bind(State))
		State["id"] := Id
		AssertTrue(_LLM_Ollama_Async.Has(Id), "the public chat call must reserve the existing request slot")
		Entry := _LLM_Ollama_Async[Id]
		State["entry"] := Entry
		State["initial_deferred"] := State["timer"]
		AssertEqual(0, Entry["presence_owner"], "the reserved slot declares that no native tags owner exists yet")
		AssertFalse(Entry["presence_pending"], "a queued preflight is not an acquired tags owner")
		AssertFalse(Entry["presence_admitted"], "reserving a slot does not admit a private POST")
		AssertEqual("", Entry["presence_model"], "the model is unproven until tags admission")
		AssertFalse(FileExist(_LLM_Ollama_Async[Id]["tmp_payload"]), "no private payload is written while tags are pending")
		if HasMethod(State["timer"], "Call")
			State["timer"].Call()
		AssertEqual(1, State["tags"], "actual chat admission must issue tags before any inference")
		AssertTrue(Entry["presence_owner"] == State["owner"], "preflight publishes the exact auxiliary lease in the existing slot")
		AssertTrue(Entry["presence_pending"], "the published native tags owner is pending its actual receipt")
		AssertFalse(Entry["presence_admitted"], "a pending tags owner still cannot admit a POST")
		AssertTrue(State["strict"], "the guard requires a strict receipt while legacy menus keep arrays")
		AssertEqual(0, State["posts"], "a pending list cannot admit an inference POST")
		Body.Call(State)
	} finally {
		try {
			for _, Owner in _LLM_AuxOwners.Clone()
				_LLM_AuxRetireOwner(Owner, true)
			if _LLM_Ollama_Async.Has(State.Get("id", 0))
				_LLM_Ollama_Async.Delete(State["id"])
			AssertEqual(0, _LLM_AuxCleanupDebt.Count, "Fixture teardown cannot hide unresolved resource cleanup.")
		} finally {
			_LLM_Ollama_Async := Saved["async"]
			_LLM_Ollama_Pending := Saved["pending"]
			_LLM_Ollama_PreflightPort := Saved["port"]
			_LLM_AuxGeneration := Saved["generation"]
			_LLM_AuxOwners := Saved["owners"]
			_LLM_AuxCleanupDebt := Saved["debt"]
			_LLM_Engine := Saved["engine"]
		}
	}
}

_OllamaPresenceMissing(State) {
	State["callback"].Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200, "body", '{"models":[]}')))
	AssertEqual(0, State["posts"], "known empty tags never POST private chat content")
	AssertEqual(1, State["failures"].Length, "a missing model settles exactly once")
	AssertTrue(LLM_LocalModelIsMissing(State["failures"][1]))
	AssertEqual("QWEN2.5", State["failures"][1]["model"], "offer names the actual requested model")
}
_OllamaPresenceMissingCase() {
	_OllamaPresenceWithFixture(_OllamaPresenceMissing)
}
Test("Ollama local presence: actual chat missing model settles before payload/POST (todo-46-local-model)", _OllamaPresenceMissingCase)

_OllamaPresenceInstalled(State) {
	State["callback"].Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200,
		"body", '{"models":[{"model":"qwen2.5:latest"}]}')))
	AssertEqual(1, State["posts"], "matching the model alias admits exactly one POST")
	AssertEqual(0, State["failures"].Length)
	LLM_AuxFinish(State["owner"])
	State["callback"].Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200, "body", '{"models":[]}')))
	AssertEqual(1, State["posts"], "retiring the completed list cannot spawn again")
	AssertEqual(0, State["failures"].Length, "late duplicate tags cannot settle the admitted inference")
}
_OllamaPresenceInstalledCase() {
	_OllamaPresenceWithFixture(_OllamaPresenceInstalled)
}
Test("Ollama local presence: implicit latest and model alias admit actual chat once (todo-46-local-model)", _OllamaPresenceInstalledCase)

_OllamaPresenceUnknown(State) {
	State["callback"].Call(LLM_LocalModelListReceipt(Map("ok", false, "status", 500, "body", '{"models":[]}')))
	AssertEqual(0, State["posts"])
	AssertEqual(1, State["failures"].Length)
	AssertEqual("model_list_unavailable", State["failures"][1], "server refusal never asks to download a model")
	AssertFalse(LLM_LocalModelIsMissing(State["failures"][1]))
}
_OllamaPresenceUnknownCase() {
	_OllamaPresenceWithFixture(_OllamaPresenceUnknown)
}
Test("Ollama local presence: tags HTTP refusal stays unknown rather than missing (todo-46-local-model)", _OllamaPresenceUnknownCase)

_OllamaPresenceCancelled(State) {
	global _LLM_Ollama_Async
	_LLM_Ollama_Async[State["id"]]["cancelled"] := true
	_LLM_AuxRetireOwner(State["owner"], true)
	State["callback"].Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200, "body", '{"models":[]}')))
	AssertEqual(0, State["posts"], "late tags after exact owner cancellation cannot launch")
	AssertEqual(0, State["failures"].Length, "cancelled inference retains its historical silent cancellation")
	AssertFalse(_LLM_Ollama_Async.Has(State["id"]), "retirement releases exactly the cancelled reserved slot")
}
_OllamaPresenceCancelledCase() {
	_OllamaPresenceWithFixture(_OllamaPresenceCancelled)
}
Test("Ollama local presence: exact auxiliary retirement fences late callbacks (todo-46-local-model)", _OllamaPresenceCancelledCase)

/** Records the exact auxiliary timer acquired and cancelled by the actual owner. */
_OllamaPresenceOwnedSchedule(State, Callback, Period) {
	State["owned_periods"].Push(Period)
	if Period == 0
		State["cancelled_timer"] := Callback
	else
		State["owned_timer"] := Callback
}

_OllamaPresenceOwnedFinalizer(State, Finalizer) {
	State["finalizers"] += 1
	Finalizer.Call()
}

/** Observes internal classification while delegating the original public fence unchanged. */
_OllamaPresenceInternalFailure(State, Callback, Failure := "") {
	State["internal_failures"].Push(Failure)
	Callback.Call(Failure)
}

/** Acquires genuine owner resources so cleanup assertions cannot pass vacuously. */
_OllamaPresenceOwnTimer(State) {
	State["owned_periods"] := []
	State["owned_ticks"] := 0
	State["finalizers"] := 0
	State["cancelled_timer"] := 0
	State["internal_failures"] := []
	State["entry"]["on_fail"] := _OllamaPresenceInternalFailure.Bind(State, State["entry"]["on_fail"])
	Finalizer := State["owner"]["on_retired"]
	AssertTrue(LLM_AuxBindResources(State["owner"],
		Map("finalizer", _OllamaPresenceOwnedFinalizer.Bind(State, Finalizer))))
	AssertTrue(LLM_AuxSchedule(State["owner"], (*) => State["owned_ticks"] += 1,
		-1, _OllamaPresenceOwnedSchedule.Bind(State)))
	AssertEqual(1, State["owned_periods"].Length)
	AssertEqual(-1, State["owned_periods"][1])
	AssertTrue(State["owner"]["timer"] == State["owned_timer"])
}

/** The exact retired slot and acquired resources settle without public callbacks. */
_OllamaPresenceAssertRetired(State, Id, Entry, Owner) {
	global _LLM_Ollama_Async, _LLM_AuxOwners, _LLM_AuxCleanupDebt
	AssertFalse(_LLM_Ollama_Async.Has(Id))
	AssertFalse(Entry["presence_pending"])
	AssertFalse(Entry["presence_admitted"])
	for Key in ["tmp_payload", "tmp_stdout", "tmp_status", "tmp_exit"]
		AssertFalse(FileExist(Entry[Key]), "Retired preflight publishes no private artifact.")
	AssertTrue(Owner["cleanup_claimed"])
	AssertEqual(0, Owner["timer"])
	AssertEqual(0, Owner["timer_cancel"])
	AssertEqual(0, Owner["finalizer"])
	AssertEqual(2, State["owned_periods"].Length)
	AssertEqual(0, State["owned_periods"][2])
	AssertTrue(State["cancelled_timer"] == State["owned_timer"])
	AssertEqual(1, State["finalizers"])
	AssertEqual(0, _LLM_AuxOwners.Count)
	AssertEqual(0, _LLM_AuxCleanupDebt.Count)
	AssertEqual(0, State["owned_ticks"])
	AssertEqual(0, State["posts"])
	AssertEqual(0, State["failures"].Length, "Retired-origin failure delivery stays silent.")
	AssertEqual(1, State["internal_failures"].Length, "The original internal settlement still happens exactly once.")
	AssertEqual("request_superseded", State["internal_failures"][1])
}

/** Old callbacks cannot touch a current public successor's exact slot or owner. */
_OllamaPresenceCurrentSuccessor(State, StaleCallbacks) {
	global _LLM_Ollama_Async, _LLM_AuxOwners, _LLM_AuxCleanupDebt
	Id := LLM_OllamaChat_Async('{"model":"qwen2.5","messages":[]}',
		(*) => 0, _OllamaPresenceRecordFailure.Bind(State))
	State["id"] := Id
	AssertTrue(_LLM_Ollama_Async.Has(Id))
	Entry := _LLM_Ollama_Async[Id]
	State["timer"].Call()
	Owner := State["owner"]
	AssertTrue(Entry["presence_owner"] == Owner)
	AssertEqual(2, State["tags"], "A current successor can acquire its actual tags owner.")
	Callback := State["callback"]
	Settled := State["internal_failures"].Length
	loop 2 {
		for Stale in StaleCallbacks
			Stale.Call()
		AssertTrue(_LLM_Ollama_Async.Has(Id))
		AssertTrue(_LLM_Ollama_Async[Id] == Entry)
		AssertTrue(Entry["presence_owner"] == Owner)
		AssertEqual(2, State["tags"])
		AssertEqual(0, State["posts"])
		AssertEqual(0, State["failures"].Length)
		AssertEqual(0, State["owned_ticks"])
		AssertEqual(1, State["finalizers"])
		AssertEqual(Settled, State["internal_failures"].Length, "Stale duplicates cannot settle again internally.")
	}
	Callback.Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200, "body", '{"models":[]}')))
	AssertFalse(_LLM_Ollama_Async.Has(Id))
	AssertEqual(1, State["failures"].Length, "Current-origin failure still settles exactly once.")
	AssertTrue(LLM_LocalModelIsMissing(State["failures"][1]))
	AssertEqual("qwen2.5", State["failures"][1]["model"])
	Callback.Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200, "body", '{"models":[]}')))
	AssertEqual(1, State["failures"].Length)
	AssertEqual(0, State["posts"])
	AssertTrue(LLM_AuxFinish(Owner))
	AssertEqual(0, _LLM_AuxOwners.Count)
	AssertEqual(0, _LLM_AuxCleanupDebt.Count, "Current successor finalization cannot be hidden by fixture restoration.")
}

_OllamaPresenceSuperseded(State) {
	Owner := State["owner"], Entry := State["entry"], Id := State["id"]
	Tag := State["callback"].Bind(LLM_LocalModelListReceipt(Map("ok", true, "status", 200,
		"body", '{"models":[{"name":"qwen2.5"}]}')))
	_OllamaPresenceOwnTimer(State)
	LLM_AuxInvalidate("presence fixture supersession")
	_OllamaPresenceAssertRetired(State, Id, Entry, Owner)
	_OllamaPresenceCurrentSuccessor(State, [Tag, State["owned_timer"], State["initial_deferred"]])
}
_OllamaPresenceSupersededCase() {
	_OllamaPresenceWithFixture(_OllamaPresenceSuperseded)
}
Test("Ollama local presence: generation changes fence admission before private payload (todo-46-local-model)", _OllamaPresenceSupersededCase)

_OllamaLocalOfferConsent() {
	global _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, _LLM_LocalModelAsking, LLM_OLLAMA_BASE_URL
	Saved := Map("port", _LLM_LocalModelOfferPort, "notified", _LLM_LocalModelNotified, "asking", _LLM_LocalModelAsking)
	State := Map("confirms", 0, "downloads", 0, "notices", 0, "accept", false, "current", true)
	try {
		_LLM_LocalModelNotified := Map()
		_LLM_LocalModelAsking := false
		_LLM_LocalModelOfferPort := Map(
			"confirm", (*) => (State["confirms"] += 1, State["accept"]),
			"notify", (*) => (State["notices"] += 1, true),
			"install", (*) => (State["downloads"] += 1, true))
		Failure := LLM_LocalModelFailure("Qwen2.5", LLM_OLLAMA_BASE_URL)
		LLM_LocalModelOffer(Failure, true)
		LLM_LocalModelOffer(LLM_LocalModelFailure("qwen2.5:latest", LLM_OLLAMA_BASE_URL), true)
		AssertEqual(1, State["notices"], "automatic failures notify once per normalized model")
		AssertEqual(0, State["confirms"], "automatic typing never opens a modal")
		AssertEqual(0, State["downloads"], "automatic typing never downloads implicitly")
		LLM_LocalModelOffer(Failure)
		AssertEqual(1, State["confirms"])
		AssertEqual(0, State["downloads"], "manual refusal never downloads")
		State["accept"] := true
		LLM_LocalModelOffer(Failure)
		AssertEqual(1, State["downloads"], "only explicit manual consent admits the existing download owner")
		_LLM_LocalModelOfferPort["confirm"] := (*) => (State["current"] := false, true)
		LLM_LocalModelOffer(Failure, false, (*) => State["current"])
		AssertEqual(1, State["downloads"], "a newer flow during modal consent prevents a stale download")
	} finally {
		_LLM_LocalModelOfferPort := Saved["port"]
		_LLM_LocalModelNotified := Saved["notified"]
		_LLM_LocalModelAsking := Saved["asking"]
	}
}
Test("Ollama local presence: explicit consent, automatic notice and modal generation fence (todo-46-local-model)", _OllamaLocalOfferConsent)


_OllamaLocalDownloadOwnerAcknowledgesLaunch() {
	global LLM_OLLAMA_BASE_URL
	State := Map("commands", [], "timers", 0, "accept", false)
	RunFn := (Command) => (State["commands"].Push(Command), State["accept"])
	ScheduleFn := (*) => State["timers"] += 1
	AssertFalse(_LLM_Menu_PullModel("qwen2.5:7b", true, LLM_OLLAMA_BASE_URL, RunFn, ScheduleFn),
		"existing native download owner must preserve launch refusal")
	AssertEqual(0, State["timers"], "refusal cannot schedule a claimed successful pull")
	State["accept"] := true
	AssertTrue(_LLM_Menu_PullModel("registry.example:5000/team/Qwen:7B", true,
		LLM_OLLAMA_BASE_URL, RunFn, ScheduleFn), "an exact valid user tag can reuse the existing owner")
	AssertEqual(2, State["commands"].Length)
	AssertContains(State["commands"][2], 'set "OLLAMA_HOST=' . LLM_OLLAMA_BASE_URL . '"',
		"the existing pull follows the actual selected daemon endpoint")
	AssertContains(State["commands"][2], 'ollama pull "registry.example:5000/team/Qwen:7B"')
	AssertEqual(1, State["timers"])
	AssertFalse(_LLM_Menu_PullModel('qwen" & echo unsafe', true, LLM_OLLAMA_BASE_URL, RunFn, ScheduleFn))
	AssertFalse(_LLM_Menu_PullModel("qwen:7b", true, "http://localhost:1", RunFn, ScheduleFn),
		"a stale endpoint cannot launch a pull on a different daemon")
	AssertEqual(2, State["commands"].Length, "unadmitted model/endpoint text cannot reach the native command")
}
Test("Ollama local presence: existing download owner acknowledges launch and preserves exact endpoint (todo-46-local-model)",
	_OllamaLocalDownloadOwnerAcknowledgesLaunch)


_OllamaPresenceQueuedGeneration(State) {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	Owner := State["owner"], Entry := State["entry"], Id := State["id"]
	Tag := State["callback"].Bind(LLM_LocalModelListReceipt(Map("ok", true, "status", 200,
		"body", '{"models":[{"name":"qwen2.5"}]}')))
	QueuedId := LLM_OllamaChat_Async('{"model":"qwen2.5","messages":[]}',
		(*) => 0, _OllamaPresenceRecordFailure.Bind(State))
	Queued := _LLM_Ollama_Pending
	AssertTrue(Queued is Map, "the ordinary latest-only coalescing owner retains the waiting chat")
	AssertEqual(QueuedId, Queued["req_id"])
	_OllamaPresenceOwnTimer(State)
	LLM_AuxInvalidate("presence fixture queued supersession")
	_OllamaPresenceAssertRetired(State, Id, Entry, Owner)
	AssertEqual("", _LLM_Ollama_Pending, "The actual finalizer drains the coalesced job.")
	AssertTrue(_LLM_Ollama_Async.Has(QueuedId))
	QueuedEntry := _LLM_Ollama_Async[QueuedId]
	QueuedEntry["on_fail"] := _OllamaPresenceInternalFailure.Bind(State, QueuedEntry["on_fail"])
	Deferred := State["timer"]
	AssertEqual(Queued["presence_generation"], QueuedEntry["presence_generation"])
	State["id"] := QueuedId
	Deferred.Call()
	AssertFalse(_LLM_Ollama_Async.Has(QueuedId))
	AssertFalse(QueuedEntry["presence_pending"])
	AssertFalse(QueuedEntry["presence_admitted"])
	AssertFalse(FileExist(QueuedEntry["tmp_payload"]))
	AssertEqual(1, State["tags"], "a queued old-endpoint chat cannot even start tags on the new daemon")
	AssertEqual(0, State["posts"])
	AssertEqual(0, State["failures"].Length)
	AssertEqual(2, State["internal_failures"].Length)
	AssertEqual("request_superseded", State["internal_failures"][2], "The queued request retains its original internal classification.")
	_OllamaPresenceCurrentSuccessor(State, [Tag, State["owned_timer"], State["initial_deferred"], Deferred])
}
_OllamaPresenceQueuedGenerationCase() {
	_OllamaPresenceWithFixture(_OllamaPresenceQueuedGeneration)
}
Test("Ollama local presence: coalesced chat preserves request epoch through deferred dispatch (todo-46-local-model)",
	_OllamaPresenceQueuedGenerationCase)

_OllamaPresenceRemovedAfterAdmission() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending, LLM_OLLAMA_BASE_URL
	Saved := Map("async", _LLM_Ollama_Async, "pending", _LLM_Ollama_Pending)
	try {
		_LLM_Ollama_Async := Map()
		_LLM_Ollama_Pending := ""
		for Body in ['{"error":"model ' . "'qwen2.5:7b'" . ' not found"}', '{"error":"endpoint not found"}'] {
			State := Map("failures", [], "successes", 0)
			Prefix := A_Temp . "\ergopti_todo46_absent_" . A_TickCount . "_" . Random(1, 1000000)
			Entry := Map("pid", 0, "process_owner", 0, "cancelled", false,
				"tmp_payload", Prefix . ".json", "tmp_stdout", Prefix . ".out", "tmp_status", Prefix . ".status", "tmp_exit", Prefix . ".exit",
				"on_success", (*) => State["successes"] += 1, "on_fail", _OllamaPresenceRecordFailure.Bind(State),
				"presence_admitted", true, "presence_generation", LLM_AuxGeneration(), "base_url", LLM_OLLAMA_BASE_URL)
			_LLM_Ollama_Async[98046] := Entry
			Terminal := Map("complete", true, "exit", 0, "status", 404, "body_read", true, "body", Body)
			_LLM_Ollama_PollCurl(98046, Map("read_terminal", (*) => Terminal))
			AssertEqual(0, State["successes"])
			AssertEqual(1, State["failures"].Length)
			if A_Index == 1 {
				AssertTrue(LLM_LocalModelIsMissing(State["failures"][1]), "a model removed after tags has explicit recovery")
				AssertEqual("qwen2.5:7b", State["failures"][1]["model"])
			} else
				AssertFalse(LLM_LocalModelIsMissing(State["failures"][1]), "generic HTTP404 never becomes model-not-found")
			AssertEqual(0, _LLM_Ollama_Async.Count, "the native terminal owner settles before the callback")
		}
	} finally {
		_LLM_Ollama_Async := Saved["async"]
		_LLM_Ollama_Pending := Saved["pending"]
	}
}
Test("Ollama local presence: native inference 404 distinguishes removed model from missing endpoint (todo-46-local-model)",
	_OllamaPresenceRemovedAfterAdmission)


_OllamaPresenceCancelRefusal(State) {
	global _LLM_AuxCleanupDebt, _LLM_Ollama_Async
	Saved := _LLM_AuxCleanupDebt
	CancelState := Map("calls", 0, "accept", false)
	try {
		_LLM_AuxCleanupDebt := Map()
		CancelFn := (*) => (CancelState["calls"] += 1, CancelState["accept"])
		AssertTrue(LLM_AuxBindResources(State["owner"], Map("cancel", CancelFn)))
		_LLM_Ollama_Async[State["id"]]["cancelled"] := true
		_LLM_AuxRetireOwner(State["owner"], true)
		AssertEqual(1, CancelState["calls"])
		AssertEqual(1, _LLM_AuxCleanupDebt.Count, "native cancel refusal retains existing lease cleanup ownership")
		AssertTrue(_LLM_Ollama_Async.Has(State["id"]), "dependent chat slot waits for cancellation acknowledgement")
		AssertEqual(0, State["posts"], "refusal never admits a private POST")
		CancelState["accept"] := true
		AssertTrue(LLM_AuxRetryCleanupDebt(), "the exact native cleanup receipt can be retried")
		AssertEqual(2, CancelState["calls"], "the owner retries exactly its refused cancellation")
		AssertEqual(0, _LLM_AuxCleanupDebt.Count)
		AssertFalse(_LLM_Ollama_Async.Has(State["id"]), "acknowledged cleanup finally retires the dependent slot")
		State["callback"].Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200, "body", '{"models":[]}')))
		AssertEqual(0, State["posts"], "an old callback stays inert after refusal recovery")
		AssertEqual(0, State["failures"].Length)
	} finally _LLM_AuxCleanupDebt := Saved
}
_OllamaPresenceCancelRefusalCase() {
	_OllamaPresenceWithFixture(_OllamaPresenceCancelRefusal)
}
Test("Ollama local presence: native cancellation refusal keeps lease debt and reserved slot until receipt (todo-46-local-model)",
	_OllamaPresenceCancelRefusalCase)


; The native scheduler accepts one-shots and exact callback cancellation only.
; Its callback records observations; assertions remain outside timer delivery.
_OllamaPresenceNativeScheduleContract() {
	Calls := 0
	Callback() => (++Calls)
	PreviousCritical := Critical("On")
	try {
		_LLM_Ollama_SchedulePreflight(Callback, -1)
		_LLM_Ollama_SchedulePreflight(Callback, 0)
	} finally Critical(PreviousCritical)
	try {
		Sleep(30)
		AssertEqual(0, Calls, "zero retires the exact armed callback before dispatch")
		_LLM_Ollama_SchedulePreflight(Callback, -1)
		Started := A_TickCount
		while Calls == 0 && ((A_TickCount - Started) & 0xFFFFFFFF) < 500
			Sleep(-1)
		AssertEqual(1, Calls, "a negative period delivers the deferred preflight once")
		Sleep(30)
		AssertEqual(1, Calls, "the admitted preflight cannot become a repeating timer")
		AssertThrows(() => _LLM_Ollama_SchedulePreflight(Callback, 1), "a positive repeating period is refused")
		AssertThrows(() => _LLM_Ollama_SchedulePreflight(Callback, -1.5), "fractional periods are refused")
		AssertThrows(() => _LLM_Ollama_SchedulePreflight(Callback, "-1"), "numeric strings are not integer periods")
	} finally _LLM_Ollama_SchedulePreflight(Callback, 0)
}
Test("Ollama local presence: native preflight timer owns one-shot and cancel semantics (todo-46-local-model)",
	_OllamaPresenceNativeScheduleContract)


/** Drives actual chat presence through retained source currency and transport ports. */
_G4O_Presence(Mode, F) {
	Other := _G4B_Fixture()
	try _OllamaPresenceWithFixture(Receive)
	finally Other.Close()
	Receive(State) {
		global _LLM_ManagedBootstrap
		if Mode == "replacement" {
			AssertTrue(F.Flow.Cancel())
			Other.Start(), Other.Runtime.PublishReady()
			_LLM_ManagedBootstrap := Other.Flow
		}
		Names := Mode == "installed" ? Map("qwen2.5:latest", true) : Map()
		State["callback"].Call(Map("ok", true, "names", Names))
		AssertEqual(Mode == "installed" ? 1 : 0, State["posts"])
		AssertEqual(Mode == "missing" ? 1 : 0, State["failures"].Length)
		if Mode == "missing"
			AssertTrue(LLM_LocalModelIsMissing(State["failures"][1]))
	}
}
for _G4O_PresenceMode in ["installed", "missing", "replacement"]
	Test("Ollama managed origin: actual preflight " . _G4O_PresenceMode . " (managed-origin-custody)",
		_G4O_WithManaged.Bind(_G4O_Presence.Bind(_G4O_PresenceMode)))
