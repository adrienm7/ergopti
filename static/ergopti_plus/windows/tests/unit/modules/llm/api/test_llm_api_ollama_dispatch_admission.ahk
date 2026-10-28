; tests/unit/modules/llm/api/test_llm_api_ollama_dispatch_admission.ahk

; ==============================================================================
; MODULE: Ollama Async Preparation Admission Tests
; DESCRIPTION:
; The public chat owns cancellation and coalescing before private-directory
; preparation can return. Directory resolution and payload writes are genuine;
; only a caller event and external scheduling/list/launch boundaries are driven.
; No native process identity or transport result is fabricated.
; ==============================================================================

#Requires AutoHotkey v2.0

_OllamaAsync_PreparationAdmission(Mode) {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_PreflightPort, _LLM_Ollama_ActiveStreams
	global _LLM_AuxGeneration, _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_ManagedBootstrap
	global LLM_Defaults, LLM_OLLAMA_PORT, LLM_OLLAMA_BASE_URL, LLM_OLLAMA_KEEP_ALIVE
	Saved := Map("async", _LLM_Ollama_Async, "pending", _LLM_Ollama_Pending,
		"port", _LLM_Ollama_PreflightPort, "streams", _LLM_Ollama_ActiveStreams,
		"generation", _LLM_AuxGeneration, "owners", _LLM_AuxOwners, "debt", _LLM_AuxCleanupDebt,
		"bootstrap", _LLM_ManagedBootstrap, "server_port", LLM_OLLAMA_PORT,
		"origin", LLM_OLLAMA_BASE_URL, "keep_alive", LLM_OLLAMA_KEEP_ALIVE)
	HadDefaults := IsSet(LLM_Defaults)
	if HadDefaults
		SavedDefaults := LLM_Defaults
	WasSuspended := A_IsSuspended, PreviousCritical := Critical("Off")
	DirectoryFn := _LLM_Ollama_TempDir
	HadDirectoryCall := DirectoryFn.HasOwnProp("Call")
	SavedDirectoryCall := HadDirectoryCall ? DirectoryFn.GetOwnPropDesc("Call") : 0
	State := Map("current", true, "directory_returns", 0, "scheduled", [], "lists", 0,
		"spawns", 0, "writes", 0, "launches", 0, "failures", [], "replacement_id", 0)
	Payload := '{"model":"QWEN2.5","messages":[{"role":"user","content":"synthetic private preparation"}]}'
	Current := (*) => State["current"]
	try {
		AssertFalse(HadDirectoryCall, "the directory boundary must start from its genuine production owner")
		Suspend(false)
		_LLM_Ollama_Async := Map(), _LLM_Ollama_Pending := "", _LLM_Ollama_ActiveStreams := []
		_LLM_AuxOwners := Map(), _LLM_AuxCleanupDebt := Map(), _LLM_ManagedBootstrap := 0
		LLM_Defaults_Load()
		AssertTrue(LLM_Ollama_LoadDefaults(), "the real canonical boot owner supplies an admitted server origin")
		AssertEqual(LLM_Defaults["llm_ollama_port"], LLM_OLLAMA_PORT, "the test never invents a server-port default")
		_LLM_Ollama_PreflightPort := Map("schedule", Schedule, "list_models", ListModels, "spawn", Spawn)
		DirectoryFn.DefineProp("Call", {Call: ObserveDirectory})
		Caught := false
		try Id := LLM_OllamaChat_Async(Payload, (*) => 0, Failed.Bind("outer"), Current)
		catch as Err {
			AssertEqual("schedule-error", Mode, "only the explicit scheduler refusal may throw")
			AssertEqual("Injected scheduler admission refusal.", Err.Message, "preparation must propagate the exact scheduler failure")
			Caught := true
		}
		AssertEqual(Mode == "schedule-error", Caught, "scheduler exceptions must propagate after retiring the reservation")
		AssertEqual(Mode == "queued-cancel" ? 2 : 1, State["directory_returns"], "the real private-directory return must cross the observed boundary")
		FileAppend(Format("RECEIPT async-prepare mode={1} directory_returns={2} before_active={3} queued={4} scheduled={5}`n",
			Mode, State["directory_returns"], _LLM_Ollama_Async.Count, _LLM_Ollama_Pending is Map,
			State["scheduled"].Length), "*")
		if Mode == "replacement" {
			AssertTrue(State["replacement_id"] > Id, "the nested real caller obtains a newer request identity")
			AssertEqual(1, _LLM_Ollama_Async.Count, "yielding preparation cannot publish two concurrent inference slots")
			AssertTrue(_LLM_Ollama_Pending is Map, "the second current request stays under the existing coalescing owner")
			QueuedId := _LLM_Ollama_Pending["req_id"]
			AssertFalse(_LLM_Ollama_Async.Has(QueuedId), "a waiting request cannot also own an active inference slot")
			OwnedIds := Map(QueuedId, true)
			for ActiveId, ActiveEntry in _LLM_Ollama_Async
				OwnedIds[ActiveId] := true
			AssertTrue(OwnedIds.Has(Id) && OwnedIds.Has(State["replacement_id"]) && OwnedIds.Count == 2,
				"coalescing must retain both actual request identities without duplicating either")
		}
		for Callback in State["scheduled"].Clone()
			Callback.Call()
		FileAppend(Format("RECEIPT async-prepare mode={1} lists={2} spawns={3} real_writes={4} native_launches={5} failures={6} after_active={7}`n",
			Mode, State["lists"], State["spawns"], State["writes"], State["launches"],
			State["failures"].Length, _LLM_Ollama_Async.Count), "*")
		ExpectedWork := Mode == "live" || Mode == "replacement" || Mode == "directory-error-replacement"
		AssertEqual(ExpectedWork ? 1 : 0, State["lists"], "cancelled or withdrawn preparation cannot start model-list I/O")
		AssertEqual(ExpectedWork ? 1 : 0, State["spawns"], "cancelled or withdrawn preparation cannot reach native spawn preparation")
		AssertEqual(ExpectedWork ? 1 : 0, State["writes"], "private payload bytes must never be written after cancellation")
		AssertEqual(0, State["launches"], "the real post-write cancellation fence prevents every native launch")
		AssertEqual(0, _LLM_Ollama_Async.Count, "every completed or cancelled fixture request must relinquish its exact slot")
		AssertEqual("", _LLM_Ollama_Pending, "the explicit write-boundary cancellation retires any queued replacement too")
		ExpectedFailures := Mode == "requester-revoked" || Mode == "cancel" || Mode == "schedule-error" ? 0 : Mode == "replacement" || Mode == "directory-error-replacement" ? 2 : 1
		AssertEqual(ExpectedFailures, State["failures"].Length, "current callers settle once while withdrawn requesters receive nothing")
	} finally {
		; Drop only the unarmed callbacks this scheduler observation retained.
		State["scheduled"] := []
		if DirectoryFn.HasOwnProp("Call")
			DirectoryFn.DeleteProp("Call")
		if HadDirectoryCall
			DirectoryFn.DefineProp("Call", SavedDirectoryCall)
		try {
			_LLM_Ollama_Pending := ""
			for _, Owner in _LLM_AuxOwners.Clone()
				_LLM_AuxRetireOwner(Owner, true)
			for RequestId, Entry in _LLM_Ollama_Async.Clone() {
				Entry["cancelled"] := true
				_LLM_CurlReleaseEntryProcess(Entry, true)
				_LLM_Ollama_CleanupCurlFiles(Entry)
				_LLM_Ollama_DeleteAsyncOwned(RequestId, Entry)
			}
			AssertEqual(0, _LLM_AuxCleanupDebt.Count, "the unit boundaries cannot hide native auxiliary cleanup debt")
		} finally {
			_LLM_Ollama_Async := Saved["async"], _LLM_Ollama_Pending := Saved["pending"]
			_LLM_Ollama_PreflightPort := Saved["port"], _LLM_Ollama_ActiveStreams := Saved["streams"]
			_LLM_AuxGeneration := Saved["generation"], _LLM_AuxOwners := Saved["owners"]
			_LLM_AuxCleanupDebt := Saved["debt"], _LLM_ManagedBootstrap := Saved["bootstrap"]
			LLM_OLLAMA_PORT := Saved["server_port"], LLM_OLLAMA_BASE_URL := Saved["origin"]
			LLM_OLLAMA_KEEP_ALIVE := Saved["keep_alive"]
			LLM_Defaults := HadDefaults ? SavedDefaults : unset
			Suspend(WasSuspended)
			Critical(PreviousCritical)
		}
	}
	ObserveDirectory(Self, Args*) {
		DirectoryFn.DeleteProp("Call")
		Directory := DirectoryFn.Call(Args*)
		AssertTrue(DirExist(Directory), "the observed return must come from genuine native directory resolution")
		AssertEqual(0, A_IsCritical, "this supported public preparation call is interruptible at the actual filesystem boundary")
		State["directory_returns"] += 1
		if Mode == "cancel"
			LLM_OllamaCancelAllAsync()
		else if Mode == "requester-revoked"
			State["current"] := false
		else if Mode == "replacement" || Mode == "directory-error-replacement" || Mode == "queued-cancel" {
			if Mode == "queued-cancel" && State["directory_returns"] == 2
				LLM_OllamaCancelAllAsync()
			else {
				State["replacement_id"] := LLM_OllamaChat_Async(Payload, (*) => 0, Failed.Bind("replacement"), Current)
				if Mode == "queued-cancel"
					DirectoryFn.DefineProp("Call", {Call: ObserveDirectory})
				if Mode != "replacement"
					throw Error("Injected private-directory refusal after publishing a real queued caller.")
			}
		}
		else if Mode == "suspended"
			Suspend(true)
		else if Mode == "directory-error"
			throw Error("Injected private-directory preparation refusal.")
		return Directory
	}
	Schedule(Callback, Period) {
		AssertTrue(HasMethod(Callback, "Call"), "the external scheduler receives the genuine deferred callback")
		AssertTrue(Period is Integer && Period < 0, "deferred preparation keeps its native one-shot scheduling contract")
		if Mode == "schedule-error"
			throw Error("Injected scheduler admission refusal.")
		State["scheduled"].Push(Callback)
	}
	ListModels(Callback, Owner, Strict) {
		State["lists"] += 1
		AssertTrue(Strict && LLM_AuxIsCurrent(Owner), "the real preflight must retain current strict list ownership")
		AssertTrue(LLM_AuxBindResources(Owner, Map("finalizer", Owner["on_retired"])))
		try Callback.Call(LLM_LocalModelListReceipt(Map("ok", true, "status", 200,
			"body", '{"models":[{"name":"qwen2.5:latest"}]}')))
		finally LLM_AuxFinish(Owner)
		return Owner
	}
	Spawn(RequestId, Body, PayloadPath, OutputPath, Job) {
		State["spawns"] += 1
		_LLM_Ollama_DoSpawn(RequestId, Body, PayloadPath, OutputPath, Job,
			Map("write", WritePayload, "run", UnexpectedLaunch))
	}
	WritePayload(Path, Body) {
		State["writes"] += 1
		AssertTrue(FSWrite(Path, Body), "the positive boundary writes actual private synthetic payload bytes")
		AssertEqual(Body, FileRead(Path, "UTF-8-RAW"), "the actual private file must contain exactly the submitted body")
		; Stop at the real write return so no test can contact an external daemon.
		LLM_OllamaCancelAllAsync()
		return true
	}
	UnexpectedLaunch(Command, WorkingDir, Options, &Pid, &Owner) {
		State["launches"] += 1
		throw Error("The unit preparation probe must not cross its native launch boundary.")
	}
	Failed(Label, Failure := "") {
		State["failures"].Push(Map("caller", Label, "failure", Failure))
	}
}

for _OllamaPreparationMode in ["live", "cancel", "requester-revoked", "replacement", "suspended", "directory-error", "directory-error-replacement", "queued-cancel", "schedule-error"]
	Test("Ollama async preparation: " . _OllamaPreparationMode . " retains admission ownership (ollama-async-prepare-admission)",
		_OllamaAsync_PreparationAdmission.Bind(_OllamaPreparationMode))
