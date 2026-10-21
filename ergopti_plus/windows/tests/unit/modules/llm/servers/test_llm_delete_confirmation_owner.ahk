; tests/unit/modules/llm/servers/test_llm_delete_confirmation_owner.ahk

; ==============================================================================
; MODULE: Model-delete confirmation ownership regression tests
; DESCRIPTION:
; Pumps real suspend and auxiliary lifecycle transitions through the confirmation
; port, then follows the real asynchronous DELETE transport through passive
; process/poll ports. No child process or network request is emitted.
; ==============================================================================

#Requires AutoHotkey v2.0

_LDCO_Confirm(State, Body, Title, Options) {
	global _LLM_Menu, LLM_OLLAMA_BASE_URL
	State.ConfirmCalls += 1
	AssertTrue(Body != "" && Title != "", "The actual delete confirmation must have localized content.")
	AssertEqual("YesNo Icon!", Options, "The real Yes/No contract must reach the confirmation port.")
	if State.Mode == "pause" {
		Suspend(true)
		LLM_AuxInvalidate("suspend")
	} else if State.Mode == "retired" {
		LLM_AuxInvalidate("backend_replacement")
		State.Successor := _LLM_Menu_BeginOllamaAux("menu_delete:" . State.Tag, State.Tag)
	} else if State.Mode == "backend"
		_LLM_Menu["backend"] := "api"
	else if State.Mode == "endpoint"
		LLM_OLLAMA_BASE_URL := "http://localhost:12435"
	else if State.Mode == "confirm-error"
		throw Error("injected confirmation failure")
	return State.Mode == "no" ? "No" : "Yes"
}

_LDCO_Write(State, Path, Content) {
	global LLM_OLLAMA_BASE_URL
	State.WriteCalls += 1
	State.Payload := Content
	if State.Mode == "payload-endpoint"
		LLM_OLLAMA_BASE_URL := "http://localhost:12435"
	return FSWrite(Path, Content)
}

_LDCO_Run(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State.RunCalls += 1
	AssertTrue(Command is Map, "The real transport must build its owned child command.")
	Curl := Command["environment"]["_ERGOPTI_CURL_COMMAND"]
	AssertTrue(InStr(Curl, "-X DELETE") > 0, "The positive control must reach the destructive DELETE transport.")
	AssertTrue(InStr(Curl, "http://localhost:12434/api/delete") > 0,
		"The command must retain the daemon shown by the original confirmation.")
	Pid := 12434
	ProcessOwner := Map("pid", Pid, "handle", 92434, "released", false)
}

_LDCO_Poll(State, ProcessOwner, Payload, Output, Status, ExitPath, Tag, Callback, Started, Owner, Port) {
	global LLM_OLLAMA_BASE_URL
	State.PollCalls += 1
	State.Owner := Owner
	AssertEqual(State.Tag, Tag, "The actual transport must retain the confirmed model tag.")
	AssertTrue(LLM_OllamaOriginCustodyCurrent(Owner["origin_custody"], Owner["endpoint"]),
		"The transport must inherit the original lexical origin capability.")
	if State.Mode == "poll-endpoint"
		LLM_OLLAMA_BASE_URL := "http://localhost:12435"
}

_LDCO_Release(State, Operation, Handle) {
	AssertEqual(92434, Handle, "Cleanup must target only the exact passive child handle.")
	if Operation == "terminate"
		State.TerminateCalls += 1
	else
		State.CloseCalls += 1
	return true
}

_LDCO_ConfirmationRetainsOwner(Mode) {
	global _LLM_Menu, LLM_OLLAMA_BASE_URL, _LLM_ManagedBootstrap
	global _LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners
	global _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	global _LLM_Menu_DeleteReconcilePending
	HadPending := IsSet(_LLM_Menu_DeleteReconcilePending)
	SavedPending := HadPending ? _LLM_Menu_DeleteReconcilePending : unset
	Saved := { Menu: _LLM_Menu, Origin: LLM_OLLAMA_BASE_URL, Managed: _LLM_ManagedBootstrap,
		Generation: _LLM_AuxGeneration, Counter: _LLM_AuxOwnerCounter, Owners: _LLM_AuxOwners,
		Debt: _LLM_AuxCleanupDebt, DebtCounter: _LLM_AuxCleanupDebtCounter,
		Suspended: A_IsSuspended }
	PreviousCritical := Critical("On")
	Dir := _LTATO_UniqueDir("delete_confirmation")
	State := { Mode: Mode, Tag: "private-confirmed-model:latest", ConfirmCalls: 0,
		WriteCalls: 0, RunCalls: 0, PollCalls: 0, TerminateCalls: 0, CloseCalls: 0, Payload: "", Owner: 0, Successor: 0 }
	try {
		Suspend(false)
		_LLM_Menu := Map("backend", "ollama", "enabled", Mode != "disabled")
		LLM_OLLAMA_BASE_URL := "http://localhost:12434"
		_LLM_ManagedBootstrap := 0
		_LLM_AuxGeneration := 991
		_LLM_AuxOwnerCounter := 0
		_LLM_AuxOwners := Map()
		_LLM_AuxCleanupDebt := Map()
		_LLM_AuxCleanupDebtCounter := 0
		_LLM_Menu_DeleteReconcilePending := Map()
		Port := Map("temp_dir", (*) => Dir, "write", _LDCO_Write.Bind(State),
			"delete", FSDelete, "run", _LDCO_Run.Bind(State), "poll", _LDCO_Poll.Bind(State),
			"tick", (*) => 992, "terminate_process", _LDCO_Release.Bind(State, "terminate"),
			"wait_process", (*) => 0, "close_process", _LDCO_Release.Bind(State, "close"))
		Accepted := false
		ConfirmationError := ""
		try Accepted := _LLM_Menu_PromptDeleteCachedModel(State.Tag, _LDCO_Confirm.Bind(State), Port)
		catch as Err
			ConfirmationError := Err.Message
		AssertEqual(Mode == "confirm-error" ? "injected confirmation failure" : "", ConfirmationError,
			"A confirmation exception must propagate after ownership cleanup, retaining the original API contract.")
		AssertEqual(1, State.ConfirmCalls, "Every scenario must reach the actual confirmation boundary.")
		Retained := Mode == "yes" || Mode == "disabled"
		Launched := Retained || Mode == "poll-endpoint"
		AssertEqual(Launched, State.RunCalls, "Only a current Yes may launch the real DELETE transport.")
		AssertEqual(Launched, State.PollCalls, "Only a launched DELETE may hand ownership to its poller.")
		AssertEqual(Launched || Mode == "payload-endpoint", State.WriteCalls,
			"A stale confirmation must be refused before transport setup, not merely at completion.")
		AssertEqual(Launched || Mode == "payload-endpoint", Accepted,
			"The UI must distinguish cancellation/refusal from an accepted transport handoff.")
		AssertEqual(Mode == "poll-endpoint", State.TerminateCalls,
			"An origin revoked after launch must terminate its exact child before releasing its handle.")
		AssertEqual(Mode == "poll-endpoint", State.CloseCalls,
			"Only the revoked launched child may release its passive handle before fixture cleanup.")
		if Retained {
			AssertTrue(LLM_AuxIsCurrent(State.Owner), "The positive transport handoff must retain its exact owner.")
			AssertTrue(InStr(State.Payload, State.Tag) > 0, "The actual JSON payload must name the confirmed model.")
			AssertEqual(1, _LLM_Menu_DeleteReconcilePending.Count, "Accepted deletion must retain its reconciliation debt.")
		} else {
			AssertEqual(0, _LLM_Menu_DeleteReconcilePending.Count, "An unlaunched delete must not leave reconciliation debt.")
			AssertEqual(Mode == "retired" ? 1 : 0, _LLM_AuxOwners.Count,
				"Refusal must retire only its own request, preserving any successor.")
			if Mode == "retired"
				AssertTrue(LLM_AuxIsCurrent(State.Successor), "The old popup must not consume its successor's owner.")
		}
	} finally {
		LLM_AuxInvalidate("delete_confirmation_fixture")
		if DirExist(Dir)
			_LTATO_DeleteDir(Dir)
		_LLM_Menu := Saved.Menu
		LLM_OLLAMA_BASE_URL := Saved.Origin
		_LLM_ManagedBootstrap := Saved.Managed
		_LLM_AuxGeneration := Saved.Generation
		_LLM_AuxOwnerCounter := Saved.Counter
		_LLM_AuxOwners := Saved.Owners
		_LLM_AuxCleanupDebt := Saved.Debt
		_LLM_AuxCleanupDebtCounter := Saved.DebtCounter
		_LLM_Menu_DeleteReconcilePending := HadPending ? SavedPending : unset
		Suspend(Saved.Suspended)
		Critical(PreviousCritical)
	}
	AssertEqual(HadPending, IsSet(_LLM_Menu_DeleteReconcilePending),
		"The fixture must preserve whether production initialized reconciliation state.")
	if HadPending
		AssertTrue(_LLM_Menu_DeleteReconcilePending == SavedPending,
			"The fixture must restore the exact pre-existing reconciliation owner.")
}
for _LDCO_Mode in ["yes", "disabled", "no", "pause", "retired", "backend", "endpoint", "payload-endpoint", "poll-endpoint", "confirm-error"]
	Test("Ollama delete confirmation: " . _LDCO_Mode . " (llm-delete-confirmation-owner)",
		_LDCO_ConfirmationRetainsOwner.Bind(_LDCO_Mode))
