; tests/unit/test_llm_backend_lifecycle_dispatch.ahk

; ==============================================================================
; MODULE: LLM backend lifecycle ownership regression tests
; DESCRIPTION:
; AHK-003 requires each deferred bootstrap and dependency callback to remain
; owned by the exact backend/configuration generation that created it. These
; tests call the production dispatcher with a faithful fake port so a remote API
; never consults Ollama and stale Ollama work cannot mutate the new backend.
; ==============================================================================

#Requires AutoHotkey v2.0

; The registry range this file fills, from here to _LBLD_LAST_CASE at its end:
; the isolation guard checks every case in it, a bare Test( registration too.
global _LBLD_FIRST_CASE := TEST_REGISTRY.Length + 1

_LBLD_Menu(Backend := "api", Enabled := true) {
	return Map(
		"backend", Backend,
		"enabled", Enabled,
		"api_entry_id", "remote-a",
		"api_entries", [Map(
			"Id", "remote-a",
			"Provider", "openai",
			"BaseUrl", "https://example.invalid/v1",
			"Token", "secret",
			"Model", "model-a")],
		"model", "local-a",
		"bootstrap_pending", false)
}

_LBLD_State() {
	return Map(
		"cancel", 0,
		"validate", 0,
		"start", 0,
		"stop", 0,
		"deps_ready", false,
		"deps_checks", 0,
		"deps_models", [],
		"build", 0,
		"warmup", 0,
		"failed", 0,
		"scheduled", [],
		"ready_callbacks", [],
		"failed_callbacks", [])
}

_LBLD_Port(State) {
	return Map(
		"cancel_ollama", (*) => State["cancel"] += 1,
		"validate_api", (*) => (State["validate"] += 1) && true,
		"start_bridge", (*) => (State["start"] += 1) && true,
		"stop_bridge", (*) => State["stop"] += 1,
		"deps_ready", (*) => State["deps_ready"],
		"deps_check", (Model, OnReady, OnFailed, ShowUi) =>
			_LBLD_RecordDepsCheck(State, Model, OnReady, OnFailed),
		"menu_build", (*) => State["build"] += 1,
		"warmup", (*) => State["warmup"] += 1,
		"deps_failed", (*) => State["failed"] += 1)
}

_LBLD_RecordDepsCheck(State, Model, OnReady, OnFailed) {
	State["deps_checks"] += 1
	State["deps_models"].Push(Model)
	State["ready_callbacks"].Push(OnReady)
	State["failed_callbacks"].Push(OnFailed)
	return true
}

_LBLD_Schedule(State, Callback, Period) {
	State["scheduled"].Push(Map("callback", Callback, "period", Period))
	return true
}

_LBLD_Reset(Menu) {
	global _LLM_Menu := Menu
	global _LLM_BackendLifecycleEpoch := 0
	global _LLM_BackendLifecycleReadyContinuation := 0
}

_LBLD_ApiNeverConsultsOllama() {
	for ShowUi in [false, true] {
		State := _LBLD_State()
		_LBLD_Reset(_LBLD_Menu("api", true))
		Intent := LLM_Menu_ScheduleBackendLifecycle(ShowUi,
			(Callback, Period) => _LBLD_Schedule(State, Callback, Period),
			_LBLD_Port(State))
		AssertTrue(Intent is Map,
			"backend lifecycle scheduling must return its immutable intent")
		AssertEqual(1, State["scheduled"].Length,
			"cold init and toggle-on must each schedule one owned bootstrap")
		AssertEqual(-1, State["scheduled"][1]["period"],
			"backend bootstrap must remain a one-shot")
		State["scheduled"][1]["callback"].Call()
		AssertEqual(1, State["cancel"],
			"API bootstrap must cancel Ollama ownership before admission")
		AssertEqual(1, State["validate"],
			"API bootstrap must validate the exact selected entry")
		AssertEqual(1, State["start"],
			"enabled API bootstrap must start the bridge exactly once")
		AssertEqual(0, State["deps_checks"],
			"remote API bootstrap must never consult Ollama dependencies")
	}
}

_LBLD_OllamaRemainsDepsGated() {
	State := _LBLD_State()
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	LLM_Menu_ScheduleBackendLifecycle(false,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period),
		_LBLD_Port(State))
	State["scheduled"][1]["callback"].Call()
	AssertEqual(1, State["deps_checks"],
		"Ollama bootstrap must dispatch one dependency check while pending")
	AssertEqual(0, State["start"],
		"Ollama bridge must not start before the owned ready callback")
	State["ready_callbacks"][1].Call()
	AssertEqual(1, State["start"],
		"the current Ollama ready callback must start the bridge once")
	AssertEqual(1, State["build"],
		"the current ready callback must publish one menu refresh")
	AssertEqual(1, State["warmup"],
		"the current ready callback must schedule one model warmup")
}

_LBLD_ProjectRoot(State, Port, FirstRestore) {
	global _LLM_Menu
	State["projections"] += 1
	if _LLM_Menu_ShouldScheduleInitialBackendLifecycle(
			FirstRestore, _LLM_Menu) {
		LLM_Menu_ScheduleBackendLifecycle(false,
			(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	}
	return true
}

_LBLD_MenuBuildProjection(State, Port) {
	State["build"] += 1
	return _LBLD_ProjectRoot(State, Port, false)
}

_LBLD_InitialProjectionReachesTerminalLifecycle() {
	State := _LBLD_State()
	State["projections"] := 0
	Port := _LBLD_Port(State)
	Port["deps_ready"] := (*) => true
	Port["menu_build"] := (*) => _LBLD_MenuBuildProjection(State, Port)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	_LBLD_ProjectRoot(State, Port, true)

	Drained := 0
	while State["scheduled"].Length > 0 {
		Drained += 1
		AssertTrue(Drained <= 4,
			"root projection must not create an unbounded lifecycle queue")
		State["scheduled"].RemoveAt(1)["callback"].Call()
	}
	AssertEqual(2, State["projections"],
		"readiness must publish exactly one replacement root")
	AssertEqual(1, State["build"],
		"readiness must request exactly one menu build")
	AssertEqual(1, State["start"],
		"the original lifecycle must survive its root projection and start once")
	AssertEqual(1, State["warmup"],
		"the original lifecycle must warm exactly once after bridge start")
}

_LBLD_StaleOllamaWorkCannotMutateApi() {
	State := _LBLD_State()
	Port := _LBLD_Port(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	LLM_Menu_ScheduleBackendLifecycle(true,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	OldScheduled := State["scheduled"][1]["callback"]

	global _LLM_Menu := _LBLD_Menu("api", true)
	LLM_Menu_ScheduleBackendLifecycle(false,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	OldScheduled.Call()
	AssertEqual(0, State["deps_checks"],
		"an Ollama timer invalidated before dispatch must do no dependency work")
	State["scheduled"][2]["callback"].Call()
	AssertEqual(1, State["start"],
		"the current API intent must still start exactly once")

	global _LLM_Menu := _LBLD_Menu("ollama", true)
	LLM_Menu_ScheduleBackendLifecycle(true,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	State["scheduled"][3]["callback"].Call()
	OldReady := State["ready_callbacks"][1]
	OldFailed := State["failed_callbacks"][1]
	global _LLM_Menu := _LBLD_Menu("api", true)
	LLM_Menu_ScheduleBackendLifecycle(false,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	StartsBefore := State["start"]
	BuildsBefore := State["build"]
	FailuresBefore := State["failed"]
	OldReady.Call()
	OldFailed.Call("stale")
	AssertEqual(StartsBefore, State["start"],
		"a stale ready callback must not start or replace the API bridge")
	AssertEqual(BuildsBefore, State["build"],
		"stale Ollama callbacks must not rebuild the API menu")
	AssertEqual(FailuresBefore, State["failed"],
		"a stale Ollama failure must not disable or mutate the API lifecycle")
}

_LBLD_AbaBackendIntentStaysStale() {
	State := _LBLD_State()
	Port := _LBLD_Port(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	OldIntent := LLM_Menu_ScheduleBackendLifecycle(false,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	OldCallback := State["scheduled"][1]["callback"]
	global _LLM_Menu := _LBLD_Menu("api", true)
	LLM_Menu_ScheduleBackendLifecycle(false,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	global _LLM_Menu := _LBLD_Menu("ollama", true)
	CurrentIntent := LLM_Menu_ScheduleBackendLifecycle(false,
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port)
	AssertEqual(CurrentIntent["backend"], OldIntent["backend"],
		"the ABA fixture must restore the same backend value")
	AssertEqual(CurrentIntent["api_entry_id"], OldIntent["api_entry_id"],
		"the ABA fixture must restore the same selected-entry value")
	OldCallback.Call()
	AssertEqual(0, State["deps_checks"],
		"an A-B-A backend cycle must not revive the first generation")
	State["scheduled"][3]["callback"].Call()
	AssertEqual(1, State["deps_checks"],
		"the final generation in an A-B-A cycle must remain executable")
}

_LBLD_InvalidApiFailsClosed() {
	State := _LBLD_State()
	Port := _LBLD_Port(State)
	Port["validate_api"] := (*) => (State["validate"] += 1) && false
	_LBLD_Reset(_LBLD_Menu("api", true))
	Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	AssertFalse(LLM_Menu_RunBackendLifecycle(Intent, Port),
		"an unusable selected API entry must fail lifecycle admission")
	AssertEqual(0, State["start"],
		"invalid API configuration must never start the bridge")
	AssertEqual(1, State["stop"],
		"invalid API configuration must detach any previously active bridge")
}

_LBLD_OllamaOwnershipMustRetireBeforeApiStarts() {
	State := _LBLD_State()
	Port := _LBLD_Port(State)
	Port["cancel_ollama"] := (*) => false
	_LBLD_Reset(_LBLD_Menu("api", true))
	Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	AssertFalse(LLM_Menu_RunBackendLifecycle(Intent, Port),
		"API admission must fail if Ollama ownership was not retired")
	AssertEqual(0, State["validate"],
		"API validation must not race an unretired Ollama lifecycle")
	AssertEqual(0, State["start"],
		"API bridge must not start while Ollama cleanup is ambiguous")
	AssertEqual(1, State["stop"],
		"ambiguous backend ownership must detach the bridge")
}

_LBLD_SelectedApiEntryUsesRealResolver() {
	global _LLM_Menu, LLM_API_PROVIDERS
	SavedMenu := _LLM_Menu
	SavedProviders := LLM_API_PROVIDERS
	try {
		LLM_API_PROVIDERS := Map("openai", Map(
			"Format", "openai",
			"BaseUrl", "https://provider.invalid/v1",
			"DefaultModel", "default-model"))
		_LLM_Menu := _LBLD_Menu("api", true)
		AssertTrue(_LLM_Menu_SelectedApiEntryIsUsable(),
			"one exact resolvable selected API entry must be admitted")
		_LLM_Menu["api_entries"][1]["Token"] := ""
		AssertFalse(_LLM_Menu_SelectedApiEntryIsUsable(),
			"the real resolver must reject an entry without a token")
		_LLM_Menu["api_entries"][1]["Token"] := "secret"
		_LLM_Menu["api_entries"].Push(_LBLD_Menu("api", true)["api_entries"][1])
		AssertFalse(_LLM_Menu_SelectedApiEntryIsUsable(),
			"duplicate selected IDs must fail closed before bridge admission")
	} finally {
		_LLM_Menu := SavedMenu
		LLM_API_PROVIDERS := SavedProviders
	}
}

_LBLD_PredictionReadinessIsBackendSpecific() {
	_LBLD_Reset(_LBLD_Menu("api", true))
	AssertTrue(_LLM_Menu_BackendIsReadyForUse((*) => false, (*) => true),
		"API readiness must not inherit a pending Ollama dependency state")
	AssertFalse(_LLM_Menu_BackendIsReadyForUse((*) => true, (*) => false),
		"an invalid API selection must fail closed even when Ollama is ready")
	global _LLM_Menu := _LBLD_Menu("ollama", true)
	AssertFalse(_LLM_Menu_BackendIsReadyForUse((*) => false, (*) => true),
		"Ollama readiness must remain dependency-gated")
	AssertTrue(_LLM_Menu_BackendIsReadyForUse((*) => true, (*) => false),
		"a ready Ollama backend must not consult the API-entry resolver")
}

_LBLD_ModelChangeRejectsCapturedCallbacks() {
	global _LLM_Menu
	State := _LBLD_State()
	Port := _LBLD_Port(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	AssertTrue(LLM_Menu_RunBackendLifecycle(Intent, Port))
	AssertEqual("local-a", State["deps_models"][1])
	OldReady := State["ready_callbacks"][1]
	OldFailed := State["failed_callbacks"][1]
	_LLM_Menu["model"] := "local-b"

	OldReady.Call()
	OldFailed.Call("stale-model")
	AssertEqual(0, State["start"],
		"(ahk3-01-model-lifecycle-owner) a ready callback for model A must not start model B")
	AssertEqual(0, State["build"],
		"a stale model callback must not rebuild the current menu")
	AssertEqual(0, State["warmup"],
		"a stale model callback must not warm the newly selected model")
	AssertEqual(0, State["failed"],
		"a failure for model A must not disable model B")
}

_LBLD_RecordModelApply(State, *) {
	State["model_apply"] += 1
	return true
}

_LBLD_ApplyModelCommitRetiresAndReplacesIntent() {
	global _LLM_Menu
	State := _LBLD_State()
	State["model_apply"] := 0
	Port := _LBLD_Port(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	LLM_Menu_RunBackendLifecycle(
		_LLM_Menu_CaptureBackendLifecycleIntent(false), Port)
	OldReady := State["ready_callbacks"][1]
	OldFailed := State["failed_callbacks"][1]

	Candidate := _LBLD_Menu("ollama", true)
	Candidate["model"] := "local-b"
	_LLM_Menu := Candidate
	AssertTrue(LLM_Menu_ApplyModelLifecycleCommitted(Candidate,
		_LBLD_RecordModelApply.Bind(State),
		(Callback, Period) => _LBLD_Schedule(State, Callback, Period), Port),
		"the real model apply boundary must publish one replacement lifecycle")
	AssertEqual(1, State["cancel"],
		"model commit must retire Ollama work owned by the previous model")
	AssertEqual(1, State["model_apply"],
		"the ordinary model runtime apply must still complete once")
	AssertEqual(1, State["scheduled"].Length,
		"enabled model B must receive one replacement lifecycle intent")

	OldReady.Call()
	OldFailed.Call("stale-model")
	AssertEqual(0, State["start"])
	AssertEqual(0, State["failed"])
	State["scheduled"][1]["callback"].Call()
	AssertEqual("local-b", State["deps_models"][2],
		"the replacement dependency check must own exact model B")
	State["ready_callbacks"][2].Call()
	AssertEqual(1, State["start"],
		"the current model B callback must remain executable")
	AssertEqual(1, State["build"])
	AssertEqual(1, State["warmup"])
}

_LBLD_ModelAbaKeepsOnlyFinalIntentCurrent() {
	global _LLM_Menu
	State := _LBLD_State()
	State["model_apply"] := 0
	Port := _LBLD_Port(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	LLM_Menu_RunBackendLifecycle(
		_LLM_Menu_CaptureBackendLifecycleIntent(false), Port)
	OldAReady := State["ready_callbacks"][1]
	ScheduleFn := (Callback, Period) => _LBLD_Schedule(State, Callback, Period)
	ApplyFn := _LBLD_RecordModelApply.Bind(State)

	CandidateB := _LBLD_Menu("ollama", true)
	CandidateB["model"] := "local-b"
	_LLM_Menu := CandidateB
	LLM_Menu_ApplyModelLifecycleCommitted(CandidateB, ApplyFn, ScheduleFn, Port)
	State["scheduled"][1]["callback"].Call()
	BReady := State["ready_callbacks"][2]

	CandidateA := _LBLD_Menu("ollama", true)
	_LLM_Menu := CandidateA
	LLM_Menu_ApplyModelLifecycleCommitted(CandidateA, ApplyFn, ScheduleFn, Port)
	State["scheduled"][2]["callback"].Call()
	CurrentAReady := State["ready_callbacks"][3]

	OldAReady.Call()
	BReady.Call()
	AssertEqual(0, State["start"],
		"(ahk3-01-model-lifecycle-owner) A-B-A must not revive either superseded receipt")
	CurrentAReady.Call()
	AssertEqual(1, State["start"],
		"the final A generation must remain live after an A-B-A cycle")
}

/** Keeps actual cache/auxiliary ownership around the injected lifecycle ports. */
_LBLD_WithTagsFixture(Callback) {
	global _LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners
	global _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter, _LLM_Deps_State
	global _LLM_InstalledTagsCache, _LLM_InstalledTagsCacheAt
	Saved := [_LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners,
		_LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter, _LLM_Deps_State]
	HadCache := IsSet(_LLM_InstalledTagsCache), HadAt := IsSet(_LLM_InstalledTagsCacheAt)
	SavedCache := HadCache ? _LLM_InstalledTagsCache : 0
	SavedAt := HadAt ? _LLM_InstalledTagsCacheAt : 0
	try {
		_LLM_AuxGeneration += 1, _LLM_AuxOwnerCounter := 0
		_LLM_AuxOwners := Map(), _LLM_AuxCleanupDebt := Map(), _LLM_AuxCleanupDebtCounter := 0
		_LLM_InstalledTagsCache := unset, _LLM_InstalledTagsCacheAt := 0
		AssertFalse(LLM_InstalledTagsCacheReady(), "the first probe starts without an admitted snapshot")
		; Dependencies and bridge are controlled ports; no native request may run.
		_LLM_Deps_State := "pending"
		return Callback.Call()
	} finally {
		try LLM_AuxInvalidate("deferred_tags_fixture_cleanup")
		finally {
			_LLM_AuxGeneration := Saved[1], _LLM_AuxOwnerCounter := Saved[2], _LLM_AuxOwners := Saved[3]
			_LLM_AuxCleanupDebt := Saved[4], _LLM_AuxCleanupDebtCounter := Saved[5], _LLM_Deps_State := Saved[6]
			_LLM_InstalledTagsCache := HadCache ? SavedCache : unset
			_LLM_InstalledTagsCacheAt := HadAt ? SavedAt : unset
		}
	}
}

_LBLD_TagsBridgeStart(State) {
	State["start"] += 1
	if !LLM_InstalledTagsCacheReady()
		return false
	if State.Get("replace_during_start", false)
		State["successor"] := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	return true
}

_LBLD_TagsDeferredReady() {
	_LBLD_WithTagsFixture(_LBLD_TagsDeferredReadyInner)
}

_LBLD_TagsDeferredReadyInner() {
	global _LLM_BackendLifecycleReadyContinuation
	State := _LBLD_State(), Port := _LBLD_Port(State)
	Port["start_bridge"] := _LBLD_TagsBridgeStart.Bind(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	AssertFalse(LLM_Menu_OnDepsReady(Intent, Port), "uncached bridge defers its original lifecycle")
	AssertEqual(1, State["start"])
	AssertEqual(0, State["warmup"])
	Owner := LLM_AuxBegin("menu_tags", Map("backend", "ollama"))
	AssertTrue(_LLM_Menu_OnInstalledTagsProbeDone(["local-a"], Owner, (*) => true))
	AssertEqual(2, State["start"], "the actual cache terminal retries the originating bridge port")
	AssertEqual(1, State["warmup"], "the deferred readiness must reach its original warmup port")
	AssertEqual(0, _LLM_BackendLifecycleReadyContinuation)
	AssertFalse(_LLM_Menu_OnInstalledTagsProbeDone(["local-a"], Owner, (*) => true))
	AssertFalse(LLM_Menu_ResumeBackendLifecycleAfterTags(), "an absent continuation cannot create a new intent")
	AssertEqual(2, State["start"])
	AssertEqual(1, State["warmup"], "duplicate completion cannot duplicate model loading")
}

_LBLD_TagsRetiredReady(Variant) {
	_LBLD_WithTagsFixture(_LBLD_TagsRetiredReadyInner.Bind(Variant))
}

_LBLD_TagsRetiredReadyInner(Variant) {
	global _LLM_Menu
	State := _LBLD_State(), Port := _LBLD_Port(State)
	Port["start_bridge"] := _LBLD_TagsBridgeStart.Bind(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	AssertFalse(LLM_Menu_OnDepsReady(Intent, Port))
	Owner := LLM_AuxBegin("menu_tags", Map("backend", "ollama"))
	switch Variant {
		case "invalidate": LLM_Menu_BackendLifecycleInvalidate()
		case "disable": _LLM_Menu["enabled"] := false
		case "api": _LLM_Menu["backend"] := "api"
		case "model": _LLM_Menu["model"] := "successor-model"
		case "successor": _LLM_Menu_CaptureBackendLifecycleIntent(false)
		default: throw ValueError("Unknown deferred readiness control.")
	}
	_LLM_Menu_OnInstalledTagsProbeDone(["local-a"], Owner, (*) => true)
	AssertEqual(1, State["start"], Variant . " cannot restart an old bridge continuation")
	AssertEqual(0, State["warmup"], Variant . " cannot warm a stale or successor selection")
}

_LBLD_TagsReentrantReady() {
	_LBLD_WithTagsFixture(_LBLD_TagsReentrantReadyInner)
}

_LBLD_TagsReentrantReadyInner() {
	State := _LBLD_State(), Port := _LBLD_Port(State)
	Port["start_bridge"] := _LBLD_TagsBridgeStart.Bind(State)
	_LBLD_Reset(_LBLD_Menu("ollama", true))
	Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	AssertFalse(LLM_Menu_OnDepsReady(Intent, Port))
	State["replace_during_start"] := true
	Owner := LLM_AuxBegin("menu_tags", Map("backend", "ollama"))
	AssertTrue(_LLM_Menu_OnInstalledTagsProbeDone(["local-a"], Owner, (*) => true))
	AssertEqual(2, State["start"])
	AssertEqual(0, State["warmup"], "a bridge callback cannot lend an old intent to its successor")
	State["replace_during_start"] := false
	AssertTrue(LLM_Menu_OnDepsReady(State["successor"], Port))
	AssertEqual(3, State["start"])
	AssertEqual(1, State["warmup"], "the explicitly dispatched successor remains live")
}


/** Receives both model-correction callers against an exact source body. */
_LBLD_ModelCorrectionsKeepLifecycle() {
	Body := _DriverFuncBody("LLM_Menu_EnsureModelReady")
	Assert(Body != "", "the installed-model correction subject must exist")
	Assert(RegExMatch(Body, "^\s*LLM_Menu_EnsureModelReady\(\)\s*\{"),
		"the common source reader retains the complete function definition")
	Subject := Body
	Program := '
(
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
Suspend(true)
global _LLM_Menu := 0, _DriverInputInitPending := false
global _LLM_LOCAL_DEFAULTS := Map("llm_model", "default-model")
global OwnedApply := 0, ProbeCalls := 0
LLM_Deps_IsReady() => true
LLM_InstalledTagsCacheReady() => true
_LLM_Menu_FireInstalledTagsProbe() {
 global ProbeCalls
 ProbeCalls += 1
 return true
}
LLM_IsModelInstalled(Model) => Model == "default-model"
_LLM_DefaultFor(Key, Fallback) => Fallback
LLM_PickBestInstalledDisplayName() => "default-model"
_LLM_ResolveOllamaTagCore(Model, *) => Model
_LLM_Menu_SetCandidateValue(Candidate, Key, Value) {
 Candidate[Key] := Value
 return true
}
_LLM_Menu_ApplyModelCommitted(*) => true
LLM_Menu_CommitMutation(Context, MutateFn, ApplyFn := 0) {
 global _LLM_Menu, OwnedApply
 Candidate := _LLM_Menu.Clone()
 if !MutateFn.Call(Candidate)
  return false
 OwnedApply += ApplyFn == _LLM_Menu_ApplyModelCommitted ? 1 : 0
 _LLM_Menu := Candidate
 return HasMethod(ApplyFn, "Call") ? ApplyFn.Call(Candidate) : true
}
LoggerWarn(*) => 0
SUBJECT
Failures := 0
for Scenario in ["default", "replacement"] {
 _LLM_Menu := Map("backend", "ollama", "model", Scenario == "default" ? "" : "not-installed")
 OwnedApply := 0, ProbeCalls := 0
 if !LLM_Menu_EnsureModelReady() || _LLM_Menu["model"] != "default-model" || ProbeCalls != 0 {
  FileAppend("PRECONDITION: the original correction did not publish its model." . Chr(10), "**")
  ExitApp(2)
 }
 FileAppend("OBSERVED model=" . Scenario . " owned_apply=" . OwnedApply . Chr(10), "*")
 if OwnedApply != 1 {
  Failures += 1
  FileAppend("CAUSAL: " . Scenario . " correction omitted its committed-model lifecycle." . Chr(10), "**")
 }
}
FileAppend("MODEL_CORRECTION received cases=2" . Chr(10), "*")
ExitApp(Failures ? 1 : 0)
)'
	Root := A_Temp . "\ergopti_tags_model_" . A_ScriptHwnd . "_" . A_TickCount
	if FileExist(Root)
		throw Error("Preserve the previous model-correction receiving.")
	DirCreate(Root)
	Child := Root . "\subject.ahk"
	FileAppend(StrReplace(Program, "SUBJECT", Subject), Child, "UTF-8")
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Child], OnDone)
	AssertTrue(Handle.start(), "the source-only model-correction child must start")
	while !Receipt.Calls {
		_SR_TreePoll()
		Sleep(10)
	}
	FileAppend(Receipt.Output, Root . "\stdout.log", "UTF-8")
	FileAppend(Receipt.Errors, Root . "\stderr.log", "UTF-8")
	AssertEqual(1, Receipt.Calls)
	AssertTrue(Handle.terminate(), "the completed child retains no native process")
	AssertEqual(0, Receipt.Code, "model-correction source refusal retained at " . Root . ": "
		. SubStr(Receipt.Errors . Receipt.Output, -8192))
	AssertEqual("", Receipt.Errors)
	AssertContains(Receipt.Output, "OBSERVED model=default owned_apply=1")
	AssertContains(Receipt.Output, "OBSERVED model=replacement owned_apply=1")
	AssertContains(Receipt.Output, "MODEL_CORRECTION received cases=2")
	AssertFalse(InStr(Receipt.Output, "[WATCHDOG]"))
	for Name in ["subject.ahk", "stdout.log", "stderr.log"]
		FileDelete(Root . "\" . Name)
	DirDelete(Root)
}


; Every case replaces the shared menu, epoch and readiness continuation. Left in
; place, the partial fixture Map reached the next test of the same run: later
; LLM menu tests failed with "Item has no value" whenever a filter such as
; --only lifecycle ran them after these (llm-backend-fixture-isolation).
_LBLD_Isolated(TestFn) {
	global _LLM_Menu, _LLM_BackendLifecycleEpoch, _LLM_BackendLifecycleReadyContinuation
	SavedMenu := _LLM_Menu
	SavedEpoch := _LLM_BackendLifecycleEpoch
	SavedContinuation := _LLM_BackendLifecycleReadyContinuation
	try TestFn.Call()
	finally {
		_LLM_Menu := SavedMenu
		_LLM_BackendLifecycleEpoch := SavedEpoch
		_LLM_BackendLifecycleReadyContinuation := SavedContinuation
	}
}

_LBLD_Cases() {
	return [
		["[ahk-003] backend lifecycle dispatch is backend-specific and owned",
			_LBLD_ApiNeverConsultsOllama],
		["[ahk-003] Ollama lifecycle remains dependency-gated",
			_LBLD_OllamaRemainsDepsGated],
		["[ahk-019] Ollama readiness projection reaches one terminal lifecycle "
			. "(backend-lifecycle-root-projection)",
			_LBLD_InitialProjectionReachesTerminalLifecycle],
		["[ahk-003] stale Ollama lifecycle cannot mutate the API backend",
			_LBLD_StaleOllamaWorkCannotMutateApi],
		["[ahk-003] A-B-A backend changes keep old lifecycle intents stale",
			_LBLD_AbaBackendIntentStaysStale],
		["[ahk-003] invalid selected API entry fails closed",
			_LBLD_InvalidApiFailsClosed],
		["[ahk-003] API waits for exact Ollama ownership retirement",
			_LBLD_OllamaOwnershipMustRetireBeforeApiStarts],
		["[ahk-003] API admission uses the real selected-entry resolver",
			_LBLD_SelectedApiEntryUsesRealResolver],
		["[ahk-003] prediction readiness is dispatched by backend",
			_LBLD_PredictionReadinessIsBackendSpecific],
		["[ahk3-01] model changes reject captured dependency callbacks "
			. "(ahk3-01-model-lifecycle-owner)",
			_LBLD_ModelChangeRejectsCapturedCallbacks],
		["[ahk3-01] model apply retires and replaces lifecycle ownership "
			. "(ahk3-01-model-lifecycle-owner)",
			_LBLD_ApplyModelCommitRetiresAndReplacesIntent],
		["[ahk3-01] model A-B-A keeps only the final generation current "
			. "(ahk3-01-model-lifecycle-owner)",
			_LBLD_ModelAbaKeepsOnlyFinalIntentCurrent],
		["installed-tags-warmup: actual tag completion resumes one owned warmup",
			_LBLD_TagsDeferredReady],
		["installed-tags-warmup: invalidation retires the deferred lifecycle",
			_LBLD_TagsRetiredReady.Bind("invalidate")],
		["installed-tags-warmup: disabling rejects the old completion",
			_LBLD_TagsRetiredReady.Bind("disable")],
		["installed-tags-warmup: API switch rejects the old completion",
			_LBLD_TagsRetiredReady.Bind("api")],
		["installed-tags-warmup: model replacement cannot borrow the old intent",
			_LBLD_TagsRetiredReady.Bind("model")],
		["installed-tags-warmup: a successor cannot borrow the old completion",
			_LBLD_TagsRetiredReady.Bind("successor")],
		["installed-tags-warmup: reentrant bridge publication keeps the successor owned",
			_LBLD_TagsReentrantReady],
		["installed-tags-warmup: both installed-model corrections enter lifecycle ownership",
			_LBLD_ModelCorrectionsKeepLifecycle]]
}

for _LBLD_Spec in _LBLD_Cases()
	Test(_LBLD_Spec[1], _LBLD_Isolated.Bind(_LBLD_Spec[2]))

; Runs every case this file registered exactly as the runner does and requires
; the shared LLM menu and lifecycle epoch to come back untouched. It walks the
; registry range the file filled, not the _LBLD_Cases list: a case registered
; with a bare Test( outside that list, the original leak, is checked too.
_LBLD_EveryCaseRestoresSharedState() {
	global TEST_REGISTRY, _LLM_Menu, _LLM_BackendLifecycleEpoch, _LLM_BackendLifecycleReadyContinuation
	global _LBLD_FIRST_CASE, _LBLD_LAST_CASE
	Src := FileRead(A_LineFile, "UTF-8")
	Marker := "`nglobal _LBLD_LAST_CASE := TEST_REGISTRY.Length"
	Tail := SubStr(Src, InStr(Src, Marker, , -1) + 1)
	Assert(InStr(Tail, SubStr(Marker, 2)) = 1, "the range end marker must close this file")
	AssertEqual(0, RegExMatch(Tail, "m)^\s*Test\("),
		"a case registered after the range end marker escapes this guard")
	Checked := 0
	Index := _LBLD_FIRST_CASE
	while (Index <= _LBLD_LAST_CASE) {
		Entry := TEST_REGISTRY[Index]
		Index += 1
		if (Entry.callback == _LBLD_EveryCaseRestoresSharedState)
			continue
		MenuBefore := _LLM_Menu
		EpochBefore := _LLM_BackendLifecycleEpoch
		ContinuationBefore := _LLM_BackendLifecycleReadyContinuation
		Entry.callback.Call()
		Checked += 1
		Assert(_LLM_Menu == MenuBefore,
			Entry.name . " must restore the shared LLM menu it replaced "
			. "(llm-backend-fixture-isolation)")
		AssertEqual(EpochBefore, _LLM_BackendLifecycleEpoch,
			Entry.name . " must restore the backend lifecycle epoch")
		Assert(_LLM_BackendLifecycleReadyContinuation == ContinuationBefore,
			Entry.name . " must restore the exact deferred readiness continuation")
	}
	AssertEqual(_LBLD_Cases().Length, Checked,
		"every backend lifecycle case must be registered through _LBLD_Cases, which isolates it, and checked")
}
Test("[llm-backend-fixture-isolation] backend lifecycle cases restore shared LLM state",
	_LBLD_EveryCaseRestoresSharedState)

; Must stay the last statement: see _LBLD_FIRST_CASE.
global _LBLD_LAST_CASE := TEST_REGISTRY.Length
