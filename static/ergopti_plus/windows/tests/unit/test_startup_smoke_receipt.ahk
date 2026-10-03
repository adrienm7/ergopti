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
