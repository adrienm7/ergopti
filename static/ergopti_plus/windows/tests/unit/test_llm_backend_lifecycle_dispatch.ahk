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
			_LBLD_RecordDepsCheck(State, OnReady, OnFailed),
		"menu_build", (*) => State["build"] += 1,
		"warmup", (*) => State["warmup"] += 1,
		"deps_failed", (*) => State["failed"] += 1)
}

_LBLD_RecordDepsCheck(State, OnReady, OnFailed) {
	State["deps_checks"] += 1
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

Test("[ahk-003] backend lifecycle dispatch is backend-specific and owned",
	_LBLD_ApiNeverConsultsOllama)
Test("[ahk-003] Ollama lifecycle remains dependency-gated",
	_LBLD_OllamaRemainsDepsGated)
Test("[ahk-003] stale Ollama lifecycle cannot mutate the API backend",
	_LBLD_StaleOllamaWorkCannotMutateApi)
Test("[ahk-003] A-B-A backend changes keep old lifecycle intents stale",
	_LBLD_AbaBackendIntentStaysStale)
Test("[ahk-003] invalid selected API entry fails closed",
	_LBLD_InvalidApiFailsClosed)
Test("[ahk-003] API waits for exact Ollama ownership retirement",
	_LBLD_OllamaOwnershipMustRetireBeforeApiStarts)
Test("[ahk-003] API admission uses the real selected-entry resolver",
	_LBLD_SelectedApiEntryUsesRealResolver)
Test("[ahk-003] prediction readiness is dispatched by backend",
	_LBLD_PredictionReadinessIsBackendSpecific)
