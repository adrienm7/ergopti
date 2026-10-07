; tests/unit/test_managed_terminal_failure.ahk
; Independent controls drive actual terminal sessions and production owner fences.
; Native GUI construction and networking remain separately UNRUN.
_MTF_Scope(Body) {
	Owners := ManagedNetworkTerminalFailure.Owners
	Intents := ManagedNetworkTerminalFailure.Intents
	ManagedNetworkTerminalFailure.Owners := Map()
	ManagedNetworkTerminalFailure.Intents := Map()
	try _MNW_Scope(Body)
	finally {
		ManagedNetworkTerminalFailure.Owners := Owners
		ManagedNetworkTerminalFailure.Intents := Intents
	}
}
_MTF_Report() {
	return ManagedNetworkFailureWindows_Classify(_MNW_ProxyReceipt(), () => true)
}
_MTF_Present(State, Report, Owner, CurrentFn, RetryFn, ClosedFn, FallbackFn) {
	Session := ManagedDownloadFailureSession()
	State["terminal_session"] := Session
	State["terminal_closed"] := ClosedFn
	State["terminal_owner"] := Owner
	return Session.PublishReport(Report, Owner, CurrentFn, RetryFn)
}
_MTF_Payload(Session, Id) {
	return Map("action", "failure_action", "id", Id, "session", Session.Id, "epoch", Session.Epoch)
}
_MTF_FreshActions(State) {
	Report := _MTF_Report()
	Report["actions"] := [Map("id", "alternative_backend", "label_key", "private.counterfeit")]
	AssertTrue(ManagedNetworkTerminalFailure.Publish("control", Report, () => true,
		"download_window.window_title", () => true, _MTF_Present.Bind(State)))
	Session := State["terminal_session"]
	AssertFalse(Session.Handle(_MTF_Payload(Session, "alternative_backend")), "copied report rows cannot manufacture a Windows capability")
	AssertTrue(Session.Handle(_MTF_Payload(Session, "proxy_settings")), "actual dispatch admits the freshly observed proxy settings capability")
	AssertEqual(1, State["opens"].Length, "one exact current native action executes")
	Report["message_key"] := "private.counterfeit"
	AssertFalse(ManagedNetworkTerminalFailure.Publish("control", Report, () => true,
		"download_window.window_title", 0, _MTF_Present.Bind(State)), "a contradictory canonical cause cannot transfer")
}
Test("managed terminal failures: canonical transfer rebuilds actual capabilities", (*) => _MTF_Scope(_MTF_FreshActions))
_MTF_Replaced(State) {
	Present := _MTF_Present.Bind(State)
	AssertTrue(ManagedNetworkTerminalFailure.Publish("control", _MTF_Report(), () => true, "download_window.window_title", () => true, Present))
	Old := State["terminal_session"], OldPayload := _MTF_Payload(Old, "proxy_settings"), OldClosed := State["terminal_closed"]
	AssertTrue(ManagedNetworkTerminalFailure.Publish("control", _MTF_Report(), () => true, "download_window.window_title", () => true, Present))
	Current := State["terminal_session"]
	OldClosed.Call()
	AssertFalse(Old.Handle(OldPayload), "queued old session cannot borrow a replacement terminal owner")
	AssertTrue(Current.Handle(_MTF_Payload(Current, "proxy_settings")), "old close cannot invalidate a new exact terminal owner")
	State["proxy_available"] := false
	AssertFalse(Current.Handle(_MTF_Payload(Current, "proxy_settings")), "current session rechecks the live native capability before an effect")
	AssertEqual(1, State["opens"].Length)
}
Test("managed terminal failures: replacement and current native availability fence effects", (*) => _MTF_Scope(_MTF_Replaced))
_MTF_Retry(State) {
	Present := _MTF_Present.Bind(State)
	Retry := () => _MTF_RetrySuccessor(State, Present)
	AssertTrue(ManagedNetworkTerminalFailure.Publish("control", _MTF_Report(), () => true, "download_window.window_title", Retry, Present))
	Old := State["terminal_session"], Payload := _MTF_Payload(Old, "retry")
	AssertTrue(Old.Handle(Payload), "actual session retry consumes the old intent before user code")
	AssertTrue(State["retry_consumed"], "broker and private session are both retired before the retry callback")
	AssertFalse(Old.Handle(Payload), "a duplicated old retry cannot execute")
	AssertTrue(State["terminal_session"].Handle(_MTF_Payload(State["terminal_session"], "proxy_settings")), "reentrant retry's successor remains current")
}
_MTF_RetrySuccessor(State, Present) {
	State["retry_consumed"] := State["terminal_session"].Owner == 0 && !ManagedNetworkTerminalFailure.Owners.Has("control")
	return ManagedNetworkTerminalFailure.Publish("control", _MTF_Report(), () => true, "download_window.window_title", 0, Present)
}
Test("managed terminal failures: actual retry consumes once and retains a reentrant successor", (*) => _MTF_Scope(_MTF_Retry))
_MTF_NativeSender(State) {
	AssertTrue(ManagedNetworkTerminalFailure.Publish("control", _MTF_Report(), () => true, "download_window.window_title", 0, _MTF_Present.Bind(State)))
	Host := ManagedNativeFailureWindow()
	Host.AppId := "download_window", Host.Epoch := 7, Host.Gui := Map(), Host.ResetDone := false
	Host.Failure := State["terminal_session"]
	Button := Map(), Other := Map(), Payload := _MTF_Payload(Host.Failure, "proxy_settings")
	ManagedDownloadFailureWindow.Current := Host
	WebViewHost._Instances[Host.AppId] := Host
	try {
		AssertFalse(Host.NativeAction(7, Host.Gui, Button, Payload, Other), "a foreign control sender cannot execute")
		AssertFalse(Host.NativeAction(6, Host.Gui, Button, Payload, Button), "a queued old native GUI generation cannot execute")
		AssertTrue(Host.NativeAction(7, Host.Gui, Button, Payload, Button), "the actual captured native control executes through shared dispatch")
		AssertEqual(1, State["opens"].Length)
	} finally {
		ManagedDownloadFailureWindow.Current := 0
		WebViewHost._Instances.Delete(Host.AppId)
	}
}
Test("managed terminal failures: actual native callback binds control and GUI generation", (*) => _MTF_Scope(_MTF_NativeSender))
_MTF_ApiOwner(State) {
	global _LLM_Menu, _LLM_Menu_ApiFailureEpoch, _LLM_Menu_ApiPrivateAuthorityGeneration
	Saved := _LLM_Menu, SavedEpoch := _LLM_Menu_ApiFailureEpoch
	try {
		Entry := Map("Id", "test", "Name", "name", "Provider", "openai", "BaseUrl", "https://private.invalid", "Token", "secret", "Model", "model")
		_LLM_Menu := Map("api_entries", [Entry])
		_LLM_Menu_ApiFailureEpoch += 1
		Owner := Map("api_failure_epoch", _LLM_Menu_ApiFailureEpoch, "api_failure_authority", _LLM_Menu_ApiPrivateAuthorityGeneration,
			"backend_generation", LLM_AuxGeneration(), "endpoint_generation", LLM_AuxGeneration(), "lifecycle_generation", LLM_AuxGeneration(), "api_failure_snapshot", Entry.Clone())
		AssertTrue(_LLM_Menu_ShowApiManagedFailure(Owner, Map("network_report", _MTF_Report()), 0, _MTF_Present.Bind(State)), "the actual completed API owner transfers a safe cause")
		Session := State["terminal_session"], Payload := _MTF_Payload(Session, "proxy_settings")
		Entry["Token"] := "edited"
		AssertFalse(Session.Handle(Payload), "editing an actual captured entry revokes a queued action")
		Entry["Token"] := "secret"
		_LLM_Menu_ApiFailureEpoch += 1
		AssertFalse(Session.Handle(Payload), "a newer actual API test revokes an older terminal intent")
		AssertEqual(0, State["opens"].Length)
	} finally {
		_LLM_Menu := Saved
		_LLM_Menu_ApiFailureEpoch := SavedEpoch
	}
}
Test("managed terminal failures: actual API entry edit and test replacement revoke actions", (*) => _MTF_Scope(_MTF_ApiOwner))
_MTF_DiagnosticsOwner(State) {
	global _HC_WindowEpoch, _HC_ResetDone, _HC_Session, _HC_ProbeRun
	Saved := [_HC_WindowEpoch, _HC_ResetDone, _HC_Session, _HC_ProbeRun]
	try {
		Result := Map("state", "error")
		_HC_WindowEpoch := 91, _HC_ResetDone := false
		_HC_Session := Map("snapshot", Map("probes", Map("github_api", Result)))
		_HC_ProbeRun := {Cancelled: false}
		AssertTrue(_HC_ShowManagedFailure(91, "github_api", Result, _MTF_Report(), _MTF_Present.Bind(State)), "the actual diagnostics result owns one terminal presentation")
		Session := State["terminal_session"], Payload := _MTF_Payload(Session, "proxy_settings")
		_HC_ProbeRun := {Cancelled: false}
		AssertFalse(Session.Handle(Payload), "a restarted real probe run revokes the queued terminal action")
		AssertEqual(0, State["opens"].Length)
	} finally {
		_HC_WindowEpoch := Saved[1], _HC_ResetDone := Saved[2], _HC_Session := Saved[3], _HC_ProbeRun := Saved[4]
	}
}
Test("managed terminal failures: actual diagnostics run replacement revokes actions", (*) => _MTF_Scope(_MTF_DiagnosticsOwner))

_MTF_RetireAdmission(State) {
	if ManagedNetworkTerminalFailure.Intents.Has("control") && !State.Get("admission_retired", false) {
		State["admission_retired"] := true
		ManagedNetworkTerminalFailure.Retire("control")
	}
	return true
}
_MTF_CancelAdmission(State) {
	AssertFalse(ManagedNetworkTerminalFailure.Publish("control", _MTF_Report(), _MTF_RetireAdmission.Bind(State),
		"download_window.window_title", 0, _MTF_Present.Bind(State)), "retirement during actual source admission revokes the reserved publication")
	AssertTrue(State["admission_retired"])
	AssertFalse(State.Has("terminal_session"), "a cancelled pending intent cannot create an actionable presenter")
	AssertFalse(ManagedNetworkTerminalFailure.Owners.Has("control"))
}
Test("managed terminal failures: explicit retirement revokes reentrant pending admission", (*) => _MTF_Scope(_MTF_CancelAdmission))
_MTF_UpdaterOwner(State) {
	global _UC_ResetDone, _UC_WindowEpoch, _UC_RequestId, _UC_State
	global _UpdaterPauseGeneration, _UpdaterRequestCounter, UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := [_UC_ResetDone, _UC_WindowEpoch, _UC_RequestId, _UC_State, _UpdaterPauseGeneration, _UpdaterRequestCounter]
	try {
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UC_ResetDone := false, _UC_WindowEpoch := 73, _UC_RequestId := Request.RequestId
		_UC_State := Map("state", "error")
		AssertTrue(_UpdateCheck_ShowManagedFailure(Request, _UC_State, _MTF_Report(), _MTF_Present.Bind(State)), "the actual manual updater context transfers the terminal cause")
		Session := State["terminal_session"], Payload := _MTF_Payload(Session, "proxy_settings")
		AssertTrue(Session.Handle(Payload), "the exact manual request admits the shared native action")
		_UpdaterPauseGeneration += 1
		AssertFalse(Session.Handle(Payload), "the actual pause generation revokes the queued updater action")
		_UpdaterPauseGeneration := Saved[5]
		_UC_State := Map("state", "error")
		AssertFalse(Session.Handle(Payload), "an equal-looking replacement updater result cannot borrow the old owner")
		AssertEqual(1, State["opens"].Length)
	} finally {
		_UC_ResetDone := Saved[1], _UC_WindowEpoch := Saved[2], _UC_RequestId := Saved[3], _UC_State := Saved[4]
		_UpdaterPauseGeneration := Saved[5], _UpdaterRequestCounter := Saved[6]
	}
}
Test("managed terminal failures: actual updater policy and state identity revoke actions", (*) => _MTF_Scope(_MTF_UpdaterOwner))
_MTF_ReleaseClassify(State, Receipt, CurrentFn, RetryFn) {
	global _ReleaseInstallCurrent, _ReleaseInstallTerminal, _ReleaseInstallOperation, _ReleaseInstallTag, RELEASE_INSTALL_REASONS
	Mode := State.Get("classifier_reentry", "")
	State["classifier_reentry"] := ""
	if Mode != "" {
		Successor := Map("id", ++_ReleaseInstallOperation, "tag", "vtest", "deps", State["release_deps"], "release", {Tag: "vtest"})
		_ReleaseInstallCurrent := Successor
		_ReleaseInstallTag := "vtest"
		State["successor"] := Successor
		_ReleaseInstall_OnPhase(State["release_deps"], "vtest", "", "failed", RELEASE_INSTALL_REASONS["download"], _MNW_ProxyReceipt(), Successor)
		if Mode == "throw"
			throw Error("controlled classifier completion failure")
	}
	return _MTF_Report()
}
_MTF_ReleaseClassifierReentry(State, Mode) {
	global _ReleaseInstallCurrent, _ReleaseInstallTerminal, _ReleaseInstallOperation, _ReleaseInstallTag, _ReleaseInstallFailureEpoch, RELEASE_INSTALL_REASONS
	Saved := [_ReleaseInstallCurrent, _ReleaseInstallTerminal, _ReleaseInstallOperation, _ReleaseInstallTag, _ReleaseInstallFailureEpoch]
	try {
		State["release_reports"] := []
		Deps := Map("failure_stage_owner", (*) => 0, "failure_classify", _MTF_ReleaseClassify.Bind(State),
			"report", (Message) => State["release_reports"].Push(Message.Clone()), "failure_current", (*) => true,
			"blocked", (*) => "", "busy", (*) => false)
		State["release_deps"] := Deps
		Current := Map("id", ++_ReleaseInstallOperation, "tag", "vtest", "deps", Deps, "release", {Tag: "vtest"})
		_ReleaseInstallCurrent := Current, _ReleaseInstallTerminal := 0, _ReleaseInstallTag := "vtest"
		State["classifier_reentry"] := Mode
		AssertFalse(_ReleaseInstall_OnPhase(Deps, "vtest", "", "failed", RELEASE_INSTALL_REASONS["download"], _MNW_ProxyReceipt(), Current), "the old classifier cannot publish after a same-tag successor starts")
		AssertTrue(_ReleaseInstallCurrent == State["successor"], "actual successor transaction remains current")
		AssertTrue(_ReleaseInstallTerminal == State["successor"], "classifier exception cannot erase the actual successor terminal")
		AssertEqual(1, State["release_reports"].Length, "only the real reentrant successor terminal is published")
		AssertEqual(State["successor"]["id"], State["release_reports"][1]["operation"], "public metadata binds the successor's exact operation")
		AssertFalse(Current.Has("failure_report"), "the stale private transaction cannot adopt the new classification")
	} finally {
		_ReleaseInstallCurrent := Saved[1], _ReleaseInstallTerminal := Saved[2], _ReleaseInstallOperation := Saved[3]
		_ReleaseInstallTag := Saved[4], _ReleaseInstallFailureEpoch := Saved[5]
	}
}
Test("managed terminal failures: actual installer classifier successor fences late publication", (*) => _MTF_Scope((State) => _MTF_ReleaseClassifierReentry(State, "normal")))
Test("managed terminal failures: actual installer classifier throw preserves successor terminal", (*) => _MTF_Scope((State) => _MTF_ReleaseClassifierReentry(State, "throw")))
_MTF_RestorableSeed(State) {
	global _ConfigDir
	Saved := _ConfigDir
	Root := A_Temp . "\ergopti_managed_seed_" . A_TickCount
	try {
		_ConfigDir := Root . "\cfg"
		_RIT_WriteFile(_ConfigDir . "\config.toml", "[original]`n")
		Rules := ConfigBackup_Rules()
		Record := ConfigBackup_Create(_ConfigDir, "pre_install", "vtest", "vprevious", Rules,
			() => Map("stamp", "20261007-120001", "iso", "2026-10-07T12:00:01Z"))
		Script := _CLW_InstallSeed()
		AssertTrue(RegExMatch(Script, "window\.__restorable_backup=(\{[^;]+\});", &Match), "actual Versions seed publishes a restorable backup object")
		Seed := JsonParse(Match[1])
		AssertEqual(Record["id"], Seed["id"], "actual serializer preserves the backup identity used by the restore click")
		AssertEqual(Record["created_at"], Seed["created_at"], "actual serializer preserves the backup date displayed by the page")
		FileDelete(_ConfigDir . "\config.toml")
		_RIT_WriteFile(_ConfigDir . "\config.toml", "[changed]`n")
		Result := ConfigBackup_Restore(_ConfigDir, Seed["id"], Rules,
			() => Map("stamp", "20261007-120002", "iso", "2026-10-07T12:00:02Z"))
		AssertTrue(Result["ok"], "the actual backup restore consumer accepts the seed's exact identity")
		AssertEqual("[original]`n", FileRead(_ConfigDir . "\config.toml", "UTF-8"))
	} finally {
		_ConfigDir := Saved
		try DirDelete(Root, true)
	}
}
Test("managed terminal failures: actual Versions seed preserves the restorable backup identity", (*) => _MTF_Scope(_MTF_RestorableSeed))
