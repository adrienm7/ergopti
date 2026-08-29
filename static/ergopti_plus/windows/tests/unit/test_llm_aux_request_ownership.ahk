; tests/unit/test_llm_aux_request_ownership.ahk

; ==============================================================================
; MODULE: LLM auxiliary request ownership regression tests
; DESCRIPTION:
; AHK-008 requires health, installed-tag, delete, and API-validation callbacks
; to retain the exact configuration and request generation that dispatched
; them. These tests reorder deterministic owners without starting a process or
; touching the network, and prove that the Ollama port participates in the
; prediction engine's live semantic identity.
; ==============================================================================

#Requires AutoHotkey v2.0

class _LAO_FakeReadyHttp {
	__New() {
		this.abort_calls := 0
		this.wait_calls := 0
	}

	Abort() {
		this.abort_calls += 1
	}

	WaitForResponse(*) {
		this.wait_calls += 1
		return true
	}
}

_LAO_ResetOwners() {
	global _LLM_AuxGeneration := 41
	global _LLM_AuxOwnerCounter := 0
	global _LLM_AuxOwners := Map()
	global _LLM_AuxCleanupDebt := Map()
	global _LLM_AuxCleanupDebtCounter := 0
}

_LAO_Context(Endpoint := "http://localhost:11434", Identity := "") {
	return Map("backend", "ollama", "endpoint", Endpoint,
		"identity", Identity)
}

_LAO_RecordSchedule(State, Callback, Period) {
	State["schedules"].Push(Map("callback", Callback, "period", Period))
}

_LAO_RecordCancel(State) {
	State["cancel_calls"] += 1
}

_LAO_RecordFinalizer(State) {
	State["finalizer_calls"] += 1
}

_LAO_RecordTimerRun(State) {
	State["timer_runs"] += 1
}

_LAO_Throw(Args*) {
	throw Error("injected auxiliary boundary failure")
}

_LAO_FailCancelOnce(State) {
	State["cancel_calls"] += 1
	if State["cancel_calls"] = 1
		throw Error("injected auxiliary cancellation failure")
}

_LAO_FailFirstTimerCancel(State, Callback, Period) {
	State["schedules"].Push(Map("callback", Callback, "period", Period))
	if Period = 0 && !State["cancel_failed"] {
		State["cancel_failed"] := true
		throw Error("injected auxiliary timer cancellation failure")
	}
}

_LAO_RecordPortPrepareStep(State, Step, Args*) {
	State["steps"].Push(Step)
	if Step == "cancel"
		LLM_AuxInvalidate("ollama_port_prepare", _LLM_Menu_ResetOllamaAuxState)
	return true
}

_LAO_LatestOwnerWinsAndInvalidationRetiresTheClass() {
	_LAO_ResetOwners()
	First := LLM_AuxBegin("menu_tags", _LAO_Context())
	Second := LLM_AuxBegin("menu_tags", _LAO_Context())
	AssertFalse(LLM_AuxIsCurrent(First),
		"a newer installed-tags request must retire the older callback")
	AssertTrue(LLM_AuxIsCurrent(Second),
		"the latest installed-tags request must remain current")
	AssertFalse(LLM_AuxFinish(First),
		"a stale completion must not consume the current owner")
	AssertTrue(LLM_AuxFinish(Second),
		"the exact current owner must complete once")
	AssertFalse(LLM_AuxFinish(Second),
		"an auxiliary owner must not complete twice")

	Health := LLM_AuxBegin("menu_health", _LAO_Context())
	LLM_AuxInvalidate("backend")
	AssertFalse(LLM_AuxIsCurrent(Health),
		"backend, endpoint, and lifecycle invalidation must retire every old owner")
}
Test("[ahk-008-aux-owner] latest request wins and global invalidation retires the class",
	_LAO_LatestOwnerWinsAndInvalidationRetiresTheClass)

_LAO_ReplacedOwnerCancelsResourcesExactlyOnce() {
	_LAO_ResetOwners()
	State := Map("schedules", [], "cancel_calls", 0,
		"finalizer_calls", 0, "timer_runs", 0)
	OldOwner := LLM_AuxBegin("menu_tags", _LAO_Context())
	AssertTrue(LLM_AuxBindResources(OldOwner, Map(
		"process_pid", 4242,
		"cancel", _LAO_RecordCancel.Bind(State),
		"finalizer", _LAO_RecordFinalizer.Bind(State))),
		"the current owner must accept its exact process and finalizer")
	AssertTrue(LLM_AuxSchedule(OldOwner, _LAO_RecordTimerRun.Bind(State), -150,
		_LAO_RecordSchedule.Bind(State)),
		"the current owner must arm its exact polling timer")
	AssertEqual(-150, State["schedules"][1]["period"],
		"the auxiliary poll must remain a one-shot timer")
	AssertEqual(4242, OldOwner["process_pid"],
		"the owner receipt must carry the process resource it owns")
	FirstTimer := State["schedules"][1]["callback"]
	AssertTrue(LLM_AuxSchedule(OldOwner, _LAO_RecordTimerRun.Bind(State), -75,
		_LAO_RecordSchedule.Bind(State)),
		"re-arming must replace the exact timer owned by the request")
	AssertEqual(3, State["schedules"].Length,
		"re-arm must first disarm the prior timer, then arm the replacement")
	AssertEqual(0, State["schedules"][2]["period"],
		"re-arm must retire the previous timer before publishing another")
	AssertEqual(-75, State["schedules"][3]["period"],
		"the replacement must retain one-shot semantics")
	FirstTimer.Call()
	AssertEqual(0, State["timer_runs"],
		"a replaced timer callback must be inert even while its owner stays current")

	NewOwner := LLM_AuxBegin("menu_tags", _LAO_Context())
	AssertFalse(LLM_AuxIsCurrent(OldOwner),
		"replacement must retire the old owner before its cleanup runs")
	AssertTrue(LLM_AuxIsCurrent(NewOwner),
		"replacement must publish the new owner")
	AssertEqual(4, State["schedules"].Length,
		"replacement must explicitly disarm the old exact timer")
	AssertEqual(0, State["schedules"][4]["period"],
		"timer retirement must use SetTimer(..., 0) semantics")
	AssertEqual(1, State["cancel_calls"],
		"replacement must cancel the old process resource exactly once")
	AssertEqual(1, State["finalizer_calls"],
		"replacement must finalize the old temporary resources exactly once")
	State["schedules"][3]["callback"].Call()
	AssertEqual(0, State["timer_runs"],
		"an already-queued old timer callback must still reject stale ownership")
	LLM_AuxInvalidate("backend")
	AssertEqual(1, State["cancel_calls"],
		"later invalidation must not cancel an already-retired owner twice")
	AssertEqual(1, State["finalizer_calls"],
		"later invalidation must not finalize an already-retired owner twice")
}
Test("[ahk-008-aux-owner] replacement cancels timer process and finalizer exactly once",
	_LAO_ReplacedOwnerCancelsResourcesExactlyOnce)


_LAO_StaleCurlOwnerReleasesExactProcessHandle() {
	_LAO_ResetOwners()
	State := Map("terminate_calls", 0, "close_calls", 0,
		"terminated_handle", 0, "closed_handle", 0)
	Port := Map(
		"open_process", (*) => 9401,
		"terminate_process", (Handle) => (
			State["terminate_calls"] += 1,
			State["terminated_handle"] := Handle,
			true),
		"close_process", (Handle) => (
			State["close_calls"] += 1,
			State["closed_handle"] := Handle,
			true))
	ProcessOwner := _LLM_CurlAdoptProcess(4247, Port)
	OldOwner := LLM_AuxBegin("menu_tags", _LAO_Context())
	AssertTrue(LLM_AuxBindResources(OldOwner, Map(
		"process_pid", 4247,
		"process_owner", ProcessOwner,
		"cancel", _LLM_CurlReleaseProcess.Bind(ProcessOwner, true, Port))),
		"the exact process handle must attach to the current auxiliary owner")
	NewOwner := LLM_AuxBegin("menu_tags", _LAO_Context())
	AssertFalse(LLM_AuxIsCurrent(OldOwner),
		"replacement must make the old generation stale before cleanup")
	AssertTrue(LLM_AuxIsCurrent(NewOwner),
		"the replacement generation must remain current")
	AssertEqual(1, State["terminate_calls"],
		"stale-generation cleanup must terminate the exact retained process once")
	AssertEqual(9401, State["terminated_handle"],
		"stale-generation cleanup must not search by recyclable PID")
	AssertEqual(1, State["close_calls"],
		"stale-generation cleanup must close the retained handle once")
	AssertEqual(9401, State["closed_handle"],
		"the same exact handle must own termination and close")
	LLM_AuxInvalidate("test_cleanup")
	AssertEqual(1, State["terminate_calls"],
		"later invalidation must not terminate the retired process twice")
	AssertEqual(1, State["close_calls"],
		"later invalidation must not close the retired handle twice")
}
Test("[ahk2-04-curl-exact-process-owner] stale auxiliary generation releases exact handle once",
	_LAO_StaleCurlOwnerReleasesExactProcessHandle)

_LAO_BoundaryFailuresStillRetireExactResources() {
	_LAO_ResetOwners()
	ResetState := Map("cancel_calls", 0, "finalizer_calls", 0)
	ResetOwner := LLM_AuxBegin("menu_health", _LAO_Context())
	AssertTrue(LLM_AuxBindResources(ResetOwner, Map(
		"cancel", _LAO_RecordCancel.Bind(ResetState),
		"finalizer", _LAO_RecordFinalizer.Bind(ResetState))),
		"the invalidation fixture must own cancellable resources")
	ResetThrew := false
	try LLM_AuxInvalidate("reset_failure", _LAO_Throw)
	catch
		ResetThrew := true
	AssertTrue(ResetThrew,
		"the reset failure must remain visible to its transaction caller")
	AssertFalse(LLM_AuxIsCurrent(ResetOwner),
		"a reset exception must not resurrect the invalidated owner")
	AssertEqual(1, ResetState["cancel_calls"],
		"a reset exception must still cancel the exact in-flight resource")
	AssertEqual(1, ResetState["finalizer_calls"],
		"a reset exception must still finalize the exact temporary resources")

	ScheduleState := Map("cancel_calls", 0, "finalizer_calls", 0)
	ScheduleOwner := LLM_AuxBegin("menu_tags", _LAO_Context())
	AssertTrue(LLM_AuxBindResources(ScheduleOwner, Map(
		"cancel", _LAO_RecordCancel.Bind(ScheduleState),
		"finalizer", _LAO_RecordFinalizer.Bind(ScheduleState))),
		"the scheduler fixture must own cancellable resources")
	AssertFalse(LLM_AuxSchedule(ScheduleOwner, (*) => true, -150, _LAO_Throw),
		"a refused timer arm must fail closed")
	AssertFalse(LLM_AuxIsCurrent(ScheduleOwner),
		"a request without its required poller must not remain publishable")
	AssertEqual(1, ScheduleState["cancel_calls"],
		"timer-arm failure must cancel the exact process resource")
	AssertEqual(1, ScheduleState["finalizer_calls"],
		"timer-arm failure must finalize exact temporary resources")
}
Test("[ahk-008-aux-owner] boundary failures retain terminal cleanup ownership",
	_LAO_BoundaryFailuresStillRetireExactResources)

_LAO_CleanupFailureRetainsRetryDebt() {
	global _LLM_AuxCleanupDebt
	_LAO_ResetOwners()
	State := Map("cancel_calls", 0, "finalizer_calls", 0)
	OldOwner := LLM_AuxBegin("menu_health", _LAO_Context())
	AssertTrue(LLM_AuxBindResources(OldOwner, Map(
		"cancel", _LAO_FailCancelOnce.Bind(State),
		"finalizer", _LAO_RecordFinalizer.Bind(State))),
		"the old request must own both dependent cleanup callbacks")
	NewOwner := LLM_AuxBegin("menu_health", _LAO_Context())

	AssertTrue(LLM_AuxIsCurrent(NewOwner),
		"cleanup failure must not resurrect an obsolete request")
	AssertEqual(1, _LLM_AuxCleanupDebt.Count,
		"failed cancellation must retain an explicit cleanup owner")
	AssertEqual(0, State["finalizer_calls"],
		"a dependent finalizer must not destroy resources needed by cancellation retry")
	AssertTrue(LLM_AuxRetryCleanupDebt(),
		"a later retry must complete the retained cleanup transaction")
	AssertEqual(2, State["cancel_calls"],
		"cleanup retry must invoke the exact failed cancellation again")
	AssertEqual(1, State["finalizer_calls"],
		"the finalizer may run exactly once after cancellation succeeds")
	AssertEqual(0, _LLM_AuxCleanupDebt.Count,
		"successful retry must retire the cleanup debt")
	LLM_AuxInvalidate("test_cleanup")
}
Test("[ahk-008-aux-owner] failed cleanup retains retry debt (aux-cleanup-debt)",
	_LAO_CleanupFailureRetainsRetryDebt)

_LAO_RearmFailurePreservesPreviousTimerOwner() {
	_LAO_ResetOwners()
	State := Map("schedules", [], "cancel_failed", false)
	Owner := LLM_AuxBegin("menu_tags", _LAO_Context())
	AssertTrue(LLM_AuxSchedule(Owner, (*) => 0, -150,
		_LAO_FailFirstTimerCancel.Bind(State)),
		"the fixture must acquire its first timer")
	FirstTimer := Owner["timer"]

	AssertFalse(LLM_AuxSchedule(Owner, (*) => 0, -75,
		_LAO_FailFirstTimerCancel.Bind(State)),
		"a refused predecessor cancellation must reject replacement")
	AssertTrue(LLM_AuxIsCurrent(Owner),
		"timer cleanup failure must preserve the current request owner")
	AssertTrue(IsObject(Owner["timer"])
		&& ObjPtr(Owner["timer"]) = ObjPtr(FirstTimer),
		"failed re-arm must retain the exact predecessor timer identity")
	AssertEqual(2, State["schedules"].Length,
		"failed predecessor cancellation must not arm a replacement timer")

	AssertTrue(LLM_AuxSchedule(Owner, (*) => 0, -75,
		_LAO_FailFirstTimerCancel.Bind(State)),
		"a later re-arm retry must replace the predecessor after cleanup succeeds")
	AssertEqual(4, State["schedules"].Length,
		"successful retry must cancel once and then arm once")
	LLM_AuxInvalidate("test_cleanup")
}
Test("[ahk-008-aux-owner] failed re-arm retains predecessor ownership (aux-rearm-ownership)",
	_LAO_RearmFailurePreservesPreviousTimerOwner)

_LAO_InstalledTagsCannotPublishOutOfOrder() {
	global _LLM_Menu, _LLM_InstalledTagsCache, _LLM_InstalledTagsCacheAt
	SavedMenu := _LLM_Menu
	HadCache := IsSet(_LLM_InstalledTagsCache)
	HadAt := IsSet(_LLM_InstalledTagsCacheAt)
	SavedCache := HadCache ? _LLM_InstalledTagsCache : 0
	SavedAt := HadAt ? _LLM_InstalledTagsCacheAt : 0
	Builds := []
	try {
		_LAO_ResetOwners()
		_LLM_Menu := Map("enabled", true, "backend", "ollama")
		_LLM_InstalledTagsCache := []
		_LLM_InstalledTagsCacheAt := 0
		OldOwner := LLM_AuxBegin("menu_tags", _LAO_Context("http://localhost:11434", "old"))
		NewOwner := LLM_AuxBegin("menu_tags", _LAO_Context("http://localhost:11434", "new"))
		AssertTrue(_LLM_Menu_OnInstalledTagsProbeDone(["new-model"], NewOwner,
			(*) => Builds.Push("new")),
			"the current installed-tags result must publish")
		AssertFalse(_LLM_Menu_OnInstalledTagsProbeDone(["deleted-model"], OldOwner,
			(*) => Builds.Push("old")),
			"an older installed-tags result must be inert after the newer result")
		AssertEqual(1, _LLM_InstalledTagsCache.Length,
			"only the current tag set may remain cached")
		AssertEqual("new-model", _LLM_InstalledTagsCache[1],
			"late completion must not resurrect a deleted model")
		AssertEqual(1, Builds.Length,
			"only the current installed-tags owner may request a repaint")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_InstalledTagsCache := HadCache ? SavedCache : unset
		_LLM_InstalledTagsCacheAt := HadAt ? SavedAt : unset
	}
}
Test("[ahk-008-aux-owner] installed tags B then A retains only B",
	_LAO_InstalledTagsCannotPublishOutOfOrder)

_LAO_ApiValidationRequiresExactEntryOwner() {
	global _LLM_Menu
	SavedMenu := _LLM_Menu
	Notices := []
	try {
		_LAO_ResetOwners()
		_LLM_Menu := Map("enabled", true, "backend", "api", "api_entry_id", "prod",
			"api_entries", [Map("Id", "prod", "Name", "Prod", "Provider", "openai",
				"BaseUrl", "https://b.invalid/v1", "Token", "secret", "Model", "b")])
		OldOwner := LLM_AuxBegin("api_validation:prod",
			Map("backend", "api", "endpoint", "https://a.invalid/v1", "identity", "prod"))
		NewOwner := LLM_AuxBegin("api_validation:prod",
			Map("backend", "api", "endpoint", "https://b.invalid/v1", "identity", "prod"))
		NotifyFn := (Reachable, Name) => Notices.Push(Map("reachable", Reachable, "name", Name))
		AssertTrue(_LLM_Menu_OnApiValidationDone(true, "Prod", "prod", NewOwner, NotifyFn),
			"the current saved entry may publish its validation")
		AssertFalse(_LLM_Menu_OnApiValidationDone(false, "Prod-old", "prod", OldOwner, NotifyFn),
			"an older endpoint result must not contradict the current entry")
		AssertEqual(1, Notices.Length,
			"only one validation notification may survive B then A completion")
		AssertTrue(Notices[1]["reachable"],
			"the retained notification must belong to endpoint B")

		DeleteOwner := LLM_AuxBegin("api_validation:prod",
			Map("backend", "api", "endpoint", "https://b.invalid/v1", "identity", "prod"))
		LLM_AuxRetirePrefix("api_validation:")
		AssertFalse(_LLM_Menu_OnApiValidationDone(false, "Prod", "prod", DeleteOwner, NotifyFn),
			"deleting an entry must retire its pending validation without a TrayTip")
		AssertEqual(1, Notices.Length,
			"a deleted entry must never produce a late notification")
	} finally _LLM_Menu := SavedMenu
}
Test("[ahk-008-aux-owner] API validation is bound to the exact entry generation",
	_LAO_ApiValidationRequiresExactEntryOwner)

_LAO_ApiValidationPublishesWhileDisabled() {
	global _LLM_Menu
	SavedMenu := _LLM_Menu
	Notices := []
	try {
		_LAO_ResetOwners()
		_LLM_Menu := Map("enabled", false, "backend", "api", "api_entry_id", "prod",
			"api_entries", [Map("Id", "prod", "Name", "Prod", "Provider", "openai",
				"BaseUrl", "https://b.invalid/v1", "Token", "secret", "Model", "b")])
		NotifyFn := (Reachable, Name) => Notices.Push(Map(
			"reachable", Reachable, "name", Name))
		Owner := LLM_AuxBegin("api_validation:prod", Map(
			"backend", "api", "endpoint", "https://b.invalid/v1", "identity", "prod"))
		AssertTrue(_LLM_Menu_OnApiValidationDone(true, "Prod", "prod", Owner, NotifyFn),
			"a configuration action must report its current result while LLM is disabled")
		AssertEqual(1, Notices.Length,
			"the disabled configuration action must notify exactly once")

		BackendOwner := LLM_AuxBegin("api_validation:prod", Map(
			"backend", "api", "endpoint", "https://b.invalid/v1", "identity", "prod"))
		_LLM_Menu["backend"] := "ollama"
		AssertFalse(_LLM_Menu_OnApiValidationDone(false, "Prod", "prod",
			BackendOwner, NotifyFn),
			"a backend switch must still reject an obsolete validation result")
		_LLM_Menu["backend"] := "api"
		_LLM_Menu["api_entries"] := []
		DeletedOwner := LLM_AuxBegin("api_validation:prod", Map(
			"backend", "api", "endpoint", "https://b.invalid/v1", "identity", "prod"))
		AssertFalse(_LLM_Menu_OnApiValidationDone(false, "Prod", "prod",
			DeletedOwner, NotifyFn),
			"a deleted entry must still reject an obsolete validation result")
		AssertEqual(1, Notices.Length,
			"only the current disabled-state completion may notify")
	} finally _LLM_Menu := SavedMenu
}
Test("[ahk-020] API validation reports while LLM is disabled "
	. "(api-validation-disabled-feedback)",
	_LAO_ApiValidationPublishesWhileDisabled)

_LAO_ApiEntryPublicationRetiresValidationFirst() {
	_LAO_ResetOwners()
	OldOwner := LLM_AuxBegin("api_validation:prod", Map(
		"backend", "api", "endpoint", "https://a.invalid/v1",
		"identity", "prod"))
	Observed := Map("published", 0, "owner_current", true)
	PublishFn := (CandidateFeatures, CandidateMenu) => (
		Observed["published"] += 1,
		Observed["owner_current"] := LLM_AuxIsCurrent(OldOwner),
		true)
	AssertTrue(_LLM_Menu_PublishApiEntriesCandidate(Map(), Map(), PublishFn),
		"the detached API entry candidate must publish")
	AssertEqual(1, Observed["published"],
		"the API entry graph must publish exactly once")
	AssertFalse(Observed["owner_current"],
		"the old validation must be retired before the new entry graph is visible")
}
Test("[ahk-008-aux-owner] API publication retires old validation atomically",
	_LAO_ApiEntryPublicationRetiresValidationFirst)

_LAO_StaleRemotePollAbortsBeforeObservingCompletion() {
	_LAO_ResetOwners()
	Owner := LLM_AuxBegin("api_validation:prod", Map(
		"backend", "api", "endpoint", "https://a.invalid/v1", "identity", "prod"))
	Http := _LAO_FakeReadyHttp()
	Results := []
	LLM_AuxInvalidate("endpoint")
	_LLMRemote_PollReady(Http, (Reachable) => Results.Push(Reachable),
		A_TickCount, 1000, Owner)
	AssertEqual(1, Http.abort_calls,
		"a stale remote request must abort its exact WinHTTP transport")
	AssertEqual(0, Http.wait_calls,
		"stale ownership must be rejected before observing a later HTTP completion")
	AssertEqual(0, Results.Length,
		"an invalidated remote endpoint must never publish readiness")
}
Test("[ahk-008-aux-owner] stale remote readiness aborts before completion",
	_LAO_StaleRemotePollAbortsBeforeObservingCompletion)

_LAO_CurrentResultsStaySilentDuringSuspend() {
	global _LLM_Menu, _LLM_InstalledTagsCacheAt
	global _LLM_Menu_DeleteReconcilePending
	SavedMenu := _LLM_Menu
	HadAt := IsSet(_LLM_InstalledTagsCacheAt)
	SavedAt := HadAt ? _LLM_InstalledTagsCacheAt : 0
	HadPending := IsSet(_LLM_Menu_DeleteReconcilePending)
	SavedPending := HadPending ? _LLM_Menu_DeleteReconcilePending : 0
	_LLM_Menu_DeleteReconcilePending := Map()
	WasSuspended := A_IsSuspended
	Builds := []
	Warnings := []
	Notices := []
	try {
		_LAO_ResetOwners()
		_LLM_Menu := Map("enabled", true, "backend", "ollama")
		_LLM_InstalledTagsCacheAt := 777
		DeleteOwner := LLM_AuxBegin("menu_delete:model-a",
			_LAO_Context("http://localhost:11434", "model-a"))
		_LLM_Menu_RecordDeleteReconcile(DeleteOwner, "Model A", "model-a")
		if !WasSuspended
			Suspend(1)
		AssertTrue(_LLM_OllamaInvokeAuxResult(DeleteOwner,
			(Ok) => _LLM_Menu_OnDeleteCachedModelDone("Model A", "model-a", Ok,
				DeleteOwner, (*) => Builds.Push("delete"),
				(*) => Warnings.Push("delete")), false),
			"the transport must terminally consume a current result during Suspend")
		AssertEqual(0, _LLM_InstalledTagsCacheAt,
			"a suspended delete completion must expire the stale installed-tags cache")
		AssertEqual(0, Builds.Length,
			"a delete completion during Suspend must not rebuild the tray")
		AssertEqual(0, Warnings.Length,
			"a discarded suspended completion must not show a live failure warning")
		AssertFalse(LLM_AuxIsCurrent(DeleteOwner),
			"a retained suspended delete result must still finish once")
		if !WasSuspended
			Suspend(0)
		AssertTrue(_LLM_Menu_ServiceDeleteReconcile(
			(*) => Builds.Push("resume"), (*) => Warnings.Push("resume")),
			"resume must consume the retained delete reconciliation")
		AssertEqual(1, Builds.Length,
			"resume must request exactly one installed-tags repaint")
		AssertEqual(1, Warnings.Length,
			"a failed suspended deletion must report its terminal on resume")
		AssertFalse(_LLM_Menu_ServiceDeleteReconcile(
			(*) => Builds.Push("duplicate"), (*) => Warnings.Push("duplicate")),
			"the retained reconciliation must be one-shot")

		if !A_IsSuspended
			Suspend(1)
		_LLM_Menu := Map("enabled", true, "backend", "api", "api_entry_id", "prod",
			"api_entries", [Map("Id", "prod", "Name", "Prod", "Provider", "openai",
				"BaseUrl", "https://b.invalid/v1", "Token", "secret", "Model", "b")])
		ValidationOwner := LLM_AuxBegin("api_validation:prod", Map(
			"backend", "api", "endpoint", "https://b.invalid/v1", "identity", "prod"))
		AssertTrue(_LLMRemote_CompleteReady(ValidationOwner,
			(Reachable) => _LLM_Menu_OnApiValidationDone(Reachable, "Prod", "prod",
				ValidationOwner, (Ok, Name) => Notices.Push(Name)), true),
			"the remote transport must terminally consume its suspended completion")
		AssertEqual(0, Notices.Length,
			"API validation must not publish a TrayTip while suspended")
		AssertFalse(LLM_AuxIsCurrent(ValidationOwner),
			"discarding a suspended API result must not leak its owner")
	} finally {
		if !WasSuspended && A_IsSuspended
			Suspend(0)
		_LLM_Menu := SavedMenu
		_LLM_InstalledTagsCacheAt := HadAt ? SavedAt : unset
		_LLM_Menu_DeleteReconcilePending := HadPending ? SavedPending : unset
	}
}
Test("[ahk-021] suspended delete terminal reconciles once on resume",
	_LAO_CurrentResultsStaySilentDuringSuspend)

_LAO_DeletePublishesWhileDisabled() {
	global _LLM_Menu, _LLM_InstalledTagsCacheAt
	global _LLM_Menu_DeleteReconcilePending
	SavedMenu := _LLM_Menu
	SavedAt := _LLM_InstalledTagsCacheAt
	HadPending := IsSet(_LLM_Menu_DeleteReconcilePending)
	SavedPending := HadPending ? _LLM_Menu_DeleteReconcilePending : 0
	_LLM_Menu_DeleteReconcilePending := Map()
	Builds := []
	Warnings := []
	try {
		_LAO_ResetOwners()
		_LLM_Menu := Map("enabled", false, "backend", "ollama")
		_LLM_InstalledTagsCacheAt := 888
		Owner := LLM_AuxBegin("menu_delete:model-b",
			_LAO_Context("http://localhost:11434", "model-b"))
		_LLM_Menu_RecordDeleteReconcile(Owner, "Model B", "model-b")
		AssertTrue(_LLM_Menu_OnDeleteCachedModelDone("Model B", "model-b", false,
			Owner, (*) => Builds.Push("build"), (*) => Warnings.Push("warning")),
			"a current delete must publish while generation is disabled")
		AssertEqual(0, _LLM_InstalledTagsCacheAt,
			"the disabled-state completion must expire installed tags")
		AssertEqual(1, Builds.Length,
			"the configurable disabled menu must repaint exactly once")
		AssertEqual(1, Warnings.Length,
			"a failed disabled-state deletion must report its failure")
		AssertEqual(0, _LLM_Menu_DeleteReconcilePending.Count,
			"a published terminal must consume its retained obligation")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_InstalledTagsCacheAt := SavedAt
		_LLM_Menu_DeleteReconcilePending := HadPending ? SavedPending : unset
	}
}
Test("[ahk-021] delete terminal publishes while LLM is disabled",
	_LAO_DeletePublishesWhileDisabled)

_LAO_SuspendInvalidationRetainsDeleteReconcile() {
	global _LLM_Menu, _LLM_InstalledTagsCacheAt
	global _LLM_Menu_DeleteReconcilePending
	SavedMenu := _LLM_Menu
	SavedAt := _LLM_InstalledTagsCacheAt
	HadPending := IsSet(_LLM_Menu_DeleteReconcilePending)
	SavedPending := HadPending ? _LLM_Menu_DeleteReconcilePending : 0
	Builds := []
	try {
		_LAO_ResetOwners()
		_LLM_Menu := Map("enabled", true, "backend", "ollama")
		_LLM_InstalledTagsCacheAt := 999
		_LLM_Menu_DeleteReconcilePending := Map()
		Owner := LLM_AuxBegin("menu_delete:model-c",
			_LAO_Context("http://localhost:11434", "model-c"))
		_LLM_Menu_RecordDeleteReconcile(Owner, "Model C", "model-c")
		LLM_AuxInvalidate("suspend")
		AssertFalse(LLM_AuxIsCurrent(Owner),
			"suspend must retire the exact delete transport owner")
		AssertEqual(1, _LLM_Menu_DeleteReconcilePending.Count,
			"transport cancellation must retain the cache obligation")
		AssertTrue(_LLM_Menu_ServiceDeleteReconcile((*) => Builds.Push("resume")),
			"resume must reconcile even when cancellation prevented a callback")
		AssertEqual(0, _LLM_InstalledTagsCacheAt,
			"resume must expire cache after a cancelled delete")
		AssertEqual(1, Builds.Length,
			"cancelled delete reconciliation must request exactly one repaint")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_InstalledTagsCacheAt := SavedAt
		_LLM_Menu_DeleteReconcilePending := HadPending ? SavedPending : unset
	}
}
Test("[ahk-021] suspend cancellation retains delete reconciliation",
	_LAO_SuspendInvalidationRetainsDeleteReconcile)

_LAO_EndpointInvalidationResetsDerivedState() {
	global _LLM_Menu, _LLM_InstalledTagsCache, _LLM_InstalledTagsCacheAt
	SavedMenu := _LLM_Menu
	HadCache := IsSet(_LLM_InstalledTagsCache)
	HadAt := IsSet(_LLM_InstalledTagsCacheAt)
	SavedCache := HadCache ? _LLM_InstalledTagsCache : 0
	SavedAt := HadAt ? _LLM_InstalledTagsCacheAt : 0
	try {
		_LAO_ResetOwners()
		_LLM_Menu := Map("enabled", true, "backend", "ollama",
			"last_health_probe_tick", 12345, "last_health_status", "ok")
		_LLM_InstalledTagsCache := ["old-endpoint-model"]
		_LLM_InstalledTagsCacheAt := 54321
		LLM_AuxBegin("menu_health", _LAO_Context("http://localhost:11434"))
		LLM_AuxInvalidate("backend_lifecycle", _LLM_Menu_ResetOllamaAuxState)
		AssertEqual(0, _LLM_Menu["last_health_probe_tick"],
			"endpoint transfer must reset the old health throttle")
		AssertEqual("", _LLM_Menu["last_health_status"],
			"endpoint transfer must not label the new endpoint with old readiness")
		AssertEqual(0, _LLM_InstalledTagsCacheAt,
			"endpoint transfer must expire the installed-tags cache")
		AssertEqual(0, _LLM_InstalledTagsCache.Length,
			"endpoint transfer must not retain the old endpoint's installed set")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_InstalledTagsCache := HadCache ? SavedCache : unset
		_LLM_InstalledTagsCacheAt := HadAt ? SavedAt : unset
	}
}
Test("[ahk-008-aux-owner] endpoint invalidation resets readiness cache and throttle",
	_LAO_EndpointInvalidationResetsDerivedState)

_LAO_OllamaPortIsLiveSemanticState() {
	global _LLM_Engine, _I18nLocale, LLM_OLLAMA_PORT, LLM_OLLAMA_BASE_URL
	SavedEngine := _LLM_Engine
	SavedLocale := _I18nLocale
	SavedPort := LLM_OLLAMA_PORT
	SavedBaseUrl := LLM_OLLAMA_BASE_URL
	try {
		_LAO_ResetOwners()
		LLM_OLLAMA_PORT := 11434
		LLM_OLLAMA_BASE_URL := "http://localhost:11434"
		OldPing := LLM_AuxBegin("ollama_ping", _LAO_Context())
		_LLM_Engine := SavedEngine.Clone()
		_I18nLocale := "en"
		LLM_Engine_Init(Map("language", "en", "ollama_port", 11434))
		OldRequestId := _LLM_Engine["request_id"]
		OldSignature := _LLM_Engine["semantic_config_signature"]
		PrepareState := Map("steps", [])
		Prepared := _LLM_Menu_PrepareOllamaPortCandidate(
			Map("ollama_port", 12434),
			_LAO_RecordPortPrepareStep.Bind(PrepareState, "stop"),
			_LAO_RecordPortPrepareStep.Bind(PrepareState, "invalidate"),
			_LAO_RecordPortPrepareStep.Bind(PrepareState, "cancel"))
		Assert(Prepared is Map,
			"the endpoint transaction must retire old ownership before publication")
		AssertEqual(3, PrepareState["steps"].Length,
			"port preparation must execute every ownership boundary")
		AssertEqual("stop", PrepareState["steps"][1],
			"prediction generation must stop before endpoint publication")
		AssertEqual("invalidate", PrepareState["steps"][2],
			"backend lifecycle intent must retire after prediction")
		AssertEqual("cancel", PrepareState["steps"][3],
			"auxiliary resources must retire before endpoint publication")
		AssertFalse(LLM_AuxIsCurrent(OldPing),
			"the old endpoint owner must be gone before the new port can publish")
		AssertTrue(LLM_Ollama_SetPort(12434),
			"the endpoint setter must accept the new validated port")
		LLM_Engine_Init(Map("language", "en", "ollama_port", 12434))
		AssertEqual(12434, _LLM_Engine["ollama_port"],
			"LLM_Engine_Init must publish the validated Ollama port")
		Assert(_LLM_Engine["request_id"] > OldRequestId,
			"a port change must retire callbacks dispatched against the old endpoint")
		AssertFalse(_LLM_Engine_SignaturesEqual(OldSignature,
			_LLM_Engine["semantic_config_signature"]),
			"the endpoint port must change the canonical request signature")
	} finally {
		_LLM_Engine := SavedEngine
		_I18nLocale := SavedLocale
		LLM_OLLAMA_PORT := SavedPort
		LLM_OLLAMA_BASE_URL := SavedBaseUrl
	}
}
Test("[ahk-008-aux-owner] Ollama port changes invalidate live prediction identity",
	_LAO_OllamaPortIsLiveSemanticState)
