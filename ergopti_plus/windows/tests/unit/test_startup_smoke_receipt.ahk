; tests/unit/test_startup_smoke_receipt.ahk

; ==============================================================================
; MODULE: Native Startup Readiness Receipt Tests
; DESCRIPTION:
; Executes the production receipt writer against an exclusive temporary directory.
; Incomplete readiness and stale artifacts must never manufacture a green boot.
; ==============================================================================

#Requires AutoHotkey v2.0

_SSRT_ReceiptGuards() {
	global _DriverReady, _DriverMenuReady, _DriverBootPhase, BUNDLE_COMMIT, BUNDLE_VERSION
	SavedReady := IsSet(_DriverReady) ? _DriverReady : unset
	SavedMenu := IsSet(_DriverMenuReady) ? _DriverMenuReady : unset
	SavedPhase := IsSet(_DriverBootPhase) ? _DriverBootPhase : unset
	SavedCommit := BUNDLE_COMMIT
	SavedVersion := BUNDLE_VERSION
	Root := A_Temp . "\ergopti_ready_receipt_" . DllCall("GetCurrentProcessId") . "_" . Random(100000, 999999)
	DirCreate(Root)
	Nonce := "abcdef0123456789abcdef0123456789"
	try {
		_DriverReady := true
		_DriverMenuReady := true
		_DriverBootPhase := "ready"
		BUNDLE_COMMIT := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		BUNDLE_VERSION := "0.0.0-dev"
		for InvalidNonce in ["", "bad", StrUpper(Nonce), Nonce . "0"] {
			_SSRT_ExpectRefusal(Root, InvalidNonce, true, "Invalid startup smoke nonce")
			AssertFalse(FileExist(Root . "\ready.json"), "refusal must publish no receipt")
		}
		for Incomplete in ["driver", "menu", "phase", "logs"] {
			_DriverReady := Incomplete != "driver"
			_DriverMenuReady := Incomplete != "menu"
			_DriverBootPhase := Incomplete == "phase" ? "input-init" : "ready"
			_SSRT_ExpectRefusal(Root, Nonce, Incomplete != "logs", "Startup readiness is incomplete")
			AssertFalse(FileExist(Root . "\ready.json"), "incomplete startup must publish no receipt")
		}
		_DriverReady := true
		_DriverMenuReady := true
		_DriverBootPhase := "ready"
		Path := StartupSmokePublishReady(Root, Nonce, true)
		Bytes := FileRead(Path, "UTF-8")
		Receipt := JsonParse(Bytes)
		AssertEqual(Nonce, Receipt["nonce"], "the receipt binds the parent nonce")
		AssertEqual(DllCall("GetCurrentProcessId"), Receipt["pid"], "the receipt comes from the actual native process")
		AssertEqual(A_AhkPath, Receipt["executable"], "source probes identify the actual interpreter")
		AssertFalse(Receipt["compiled"], "an interpreted fixture cannot claim to be a packaged executable")
		AssertEqual(BUNDLE_COMMIT, Receipt["build_commit"], "the receipt retains the build commit")
		AssertEqual(_Bundle_BuildMarker(), Receipt["bundle_identity"], "bundle identity is canonical")
		for Field in ["driver_ready", "menu_ready", "logs_flushed"]
			AssertTrue(Receipt[Field], Field . " must be proven before publication")
		_SSRT_ExpectRefusal(Root, Nonce, true, "receipt could not be created durably")
		AssertEqual(Bytes, FileRead(Path, "UTF-8"), "a stale receipt collision preserves its bytes")
	} finally {
		_DriverReady := IsSet(SavedReady) ? SavedReady : unset
		_DriverMenuReady := IsSet(SavedMenu) ? SavedMenu : unset
		_DriverBootPhase := IsSet(SavedPhase) ? SavedPhase : unset
		BUNDLE_COMMIT := SavedCommit
		BUNDLE_VERSION := SavedVersion
		try DirDelete(Root, true)
	}
}

_SSRT_ExpectRefusal(Directory, Nonce, LogsFlushed, ExpectedMessage) {
	Caught := 0
	try StartupSmokePublishReady(Directory, Nonce, LogsFlushed)
	catch as Err
		Caught := Err
	AssertTrue(IsObject(Caught), "the production writer must reject this invalid contract")
	AssertTrue(InStr(Caught.Message, ExpectedMessage), "refusal must be for the intended contract: " . Caught.Message)
}
Test("startup readiness requires a fresh native process receipt (compiled-ready-receipt)", _SSRT_ReceiptGuards)

_SSRT_ObserverAcknowledgment() {
	Root := A_Temp . "\ergopti_observer_ack_" . DllCall("GetCurrentProcessId") . "_" . Random(100000, 999999)
	DirCreate(Root)
	Nonce := "abcdef0123456789abcdef0123456789"
	AckPath := Root . "\ack.txt"
	try {
		for Scenario in ["missing", "foreign", "invalid"] {
			if Scenario == "foreign"
				FileAppend("0123456789abcdef0123456789abcdef", AckPath, "UTF-8-RAW")
			Caught := 0
			StartedAt := A_TickCount
			try StartupSmokeAwaitObserver(Root, Scenario == "invalid" ? "bad" : Nonce, 30, 1)
			catch as Err
				Caught := Err
			AssertTrue(IsObject(Caught), Scenario . " must refuse readiness acknowledgment")
			Expected := Scenario == "missing" ? "before the timeout" : Scenario == "foreign" ? "another run" : "Invalid startup smoke nonce"
			AssertTrue(InStr(Caught.Message, Expected), "the intended acknowledgment guard must reject " . Scenario)
			AssertTrue(TickElapsed(StartedAt) < 2000, "a missing or foreign observer must remain bounded")
			if FileExist(AckPath)
				FileDelete(AckPath)
		}
		FileAppend(Nonce, AckPath, "UTF-8-RAW")
		AssertTrue(StartupSmokeAwaitObserver(Root, Nonce, 500, 1), "the exact nonce admits the parent observer")
	} finally {
		DirDelete(Root, true)
	}
}
Test("source readiness requires its own bounded observer acknowledgment (startup-observer-ack)", _SSRT_ObserverAcknowledgment)

_SSRT_FullSaveGeneration() {
	global Features, _LLM_Menu, _LLM_Menu_Loaded
	global _DriverMenuReady, _DriverBootPhase, CONFIG_SAVE_OK
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	SavedFeatures := Features
	SavedLLM := _LLM_Menu
	SavedLoaded := IsSet(_LLM_Menu_Loaded) ? _LLM_Menu_Loaded : unset
	SavedMenu := IsSet(_DriverMenuReady) ? _DriverMenuReady : unset
	SavedPhase := IsSet(_DriverBootPhase) ? _DriverBootPhase : unset
	Root := A_Temp . "\ergopti_full_save_receipt_" . DllCall("GetCurrentProcessId") . "_" . Random(100000, 999999)
	DirCreate(Root)
	Path := Root . "\config.toml"
	Nonce := "abcdef0123456789abcdef0123456789"
	try {
		_CFGFS_Prepare(Path)
		_DriverMenuReady := true
		_DriverBootPhase := "ready"
		Features := ManifestBuildFeaturesMap()
		_LLM_Menu := _HSDeepCloneMap(SavedLLM)
		_LLM_Menu["onboarding_seen"] := false
		_LLM_Menu["app_profile_overrides"] := Map()
		_LLM_Menu["user_profiles"] := []
		_LLM_Menu_Loaded := true
		Legacy := '# retained installed dashboard bindings`n[metrics]`nmetrics_shortcut_typing = "Ctrl+Alt+M" # retained typing`nmetrics_shortcut_apps = "Ctrl+Alt+A" # retained apps`nfuture_dashboard = { keep = 9, enabled = false } # retained foreign extension`n'
		AssertTrue(FSWrite(Path, Legacy), "the native old profile is independently authored")
		Caught := 0
		try StartupSmokePublishFullSave(Root, Nonce)
		catch as Err
			Caught := Err
		AssertTrue(IsObject(Caught), "zero accepted generations cannot manufacture a receipt")
		AssertFalse(FileExist(Root . "\full-save.json"), "missing obligation publishes no receipt")
		AssertEqual(0, _ConfigFullSaveCoordinator().requested_generation)
		Generation := _ConfigFullSaveRequest()
		AssertEqual(1, Generation, "the observer uses exactly one already accepted obligation")
		ReceiptPath := StartupSmokePublishFullSave(Root, Nonce)
		ReceiptBytes := FileRead(ReceiptPath, "UTF-8")
		Receipt := JsonParse(ReceiptBytes)
		AssertEqual(Nonce, Receipt["nonce"])
		AssertEqual(DllCall("GetCurrentProcessId"), Receipt["pid"])
		AssertEqual(A_AhkPath, Receipt["executable"])
		AssertFalse(Receipt["compiled"], "the unit process cannot claim compiled acceptance")
		for Field in ["requested", "committed", "settled"]
			AssertEqual(Generation, Receipt[Field], "real collection and WAL publication acknowledged " . Field)
		AssertFalse(Receipt["pending"])
		for Line in StrSplit(Legacy, "`n") {
			if Line != ""
				AssertContains(FSRead(Path), Line . "`n", "the production save preserves the unowned source record")
		}
		AssertEqual("Ctrl+Alt+A", TOML_Read(Path, "metrics", "metrics_shortcut_apps", "missing"))
		Caught := 0
		try StartupSmokePublishFullSave(Root, Nonce)
		catch as Err
			Caught := Err
		AssertTrue(IsObject(Caught), "a foreign occupied receipt is never overwritten")
		AssertEqual(ReceiptBytes, FileRead(ReceiptPath, "UTF-8"))
		AssertEqual(Generation, _ConfigFullSaveCoordinator().requested_generation, "publication creates no successor request")
		FileDelete(ReceiptPath)
		_CFGFS_Prepare(Path, true, true)
		Refused := _ConfigFullSaveRequest()
		State := _ConfigFullSaveCoordinator()
		State.settled_generation := Refused
		Caught := 0
		try StartupSmokePublishFullSave(Root, Nonce)
		catch as Err
			Caught := Err
		AssertTrue(IsObject(Caught), "settled abandonment and native read refusal cannot acknowledge commitment")
		AssertFalse(FileExist(ReceiptPath))
		AssertEqual(Refused, State.requested_generation, "refusal does not manufacture a retry request")
		AssertEqual(0, State.committed_generation)
	} finally {
		Features := SavedFeatures
		_LLM_Menu := SavedLLM
		_LLM_Menu_Loaded := IsSet(SavedLoaded) ? SavedLoaded : unset
		_DriverMenuReady := IsSet(SavedMenu) ? SavedMenu : unset
		_DriverBootPhase := IsSet(SavedPhase) ? SavedPhase : unset
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		try DirDelete(Root, true)
	}
}
Test("startup full save acknowledges the existing native collector/WAL generation (compiled-full-save-receipt)", _SSRT_FullSaveGeneration)
