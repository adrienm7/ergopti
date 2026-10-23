; tests/unit/modules/keylogger/metrics/test_metrics_native_sender_identity.ahk

; ==============================================================================
; MODULE: Native Metrics Sender Identity Regression
; DESCRIPTION:
; A tree-owned standalone child loads real WebView2 vendors without altering
; availability or class identity in the common unit runner.
; ==============================================================================

#Requires AutoHotkey v2.0

_MVSP_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_MVSP_NativeSender(Mode := "") {
	global _DriverDir
	static Serial := 0, RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "a prior unretired native probe forbids another browser launch")
	Fixture := _DriverDir . "\tests\fixtures\webview_metrics_sender_fixture.ahk"
	Host := _DriverProductionFileForSymbol("KLWV_OnWebMessage")
	AssertTrue(Host != "" && FSStrictExists(Fixture), "the actual host and standalone native fixture must exist")
	FixtureHash := CryptoSha256Bytes(FSReadBytesStrict(Fixture))
	HostHash := CryptoSha256Bytes(FSReadBytesStrict(Host))
	RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
	for Hash in [FixtureHash, HostHash, RuntimeHash]
		AssertTrue(RegExMatch(Hash, "^[0-9a-f]{64}$"), "every actual launch input needs its exact binary digest")
	Root := A_Temp . "\ergopti_metrics_sender_parent_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	Token := A_ScriptHwnd . "_" . Serial
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	Handle := 0, Primary := 0, Retired := false, NativePid := 0
	PreviousCritical := Critical("Off")
	try {
		; The default keeps five String arguments. Only the explicit other-core
		; mode adds a sixth, without a runner flag or ambient environment marker.
		Args := ["/ErrorStdOut=UTF-8", Fixture, Root . "\subject", Token, FixtureHash, HostHash, RuntimeHash]
		if Mode != ""
			Args.Push(Mode)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, Args, _MVSP_Complete.Bind(State))
		AssertTrue(Handle.start(), "the exact native WebView child must start")
		NativePid := Handle.processId()
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 60000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the owned native child did not settle: " . State.ErrorText . State.Output)
		Receipts := []
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1 {
				_TestPrint("# native-webview-sender " . Line)
				Receipts.Push(JsonParse(SubStr(Line, 9)))
			}
		AssertEqual(1, Receipts.Length, "native creation/source/COM prerequisites failed before a causal receipt: " . State.ErrorText . State.Output)
		Receipt := Receipts[1]
		AssertEqual(NativePid, Receipt["child_pid"], "the receipt must belong to the actual supervised child")
		AssertEqual(FixtureHash, Receipt["fixture_sha256"])
		AssertEqual(HostHash, Receipt["host_sha256"])
		AssertEqual(RuntimeHash, Receipt["runtime_sha256"])
		AssertEqual(A_AhkVersion, Receipt["runtime_version"])
		for Key in ["core_identity_equal", "iunknown_identity_equal", "native_source_equal", "current_epoch",
			"same_entry", "not_suspended", "browser_retired", "profile_retired"]
			AssertTrue(Receipt[Key], "the real callback prerequisite or physical retirement was not proved: " . Key)
		if Mode == "other-core" {
			for Key in ["other_callback_identity_equal", "other_identity_distinct", "other_same_url",
				"other_current_entry", "other_not_suspended", "shared_browser_process", "other_controller_closed"]
				AssertTrue(Receipt[Key], "the genuine other-core prerequisite or retirement is missing: " . Key)
			AssertEqual(Receipt["browser_pid"], Receipt["other_browser_pid"], "the two controllers must share the supervised private browser")
			AssertEqual(1, Receipt["other_native_callbacks"])
			AssertEqual(0, Receipt["other_worker_spawns"], "another native core at the same URL must not launch a worker")
			AssertFalse(Receipt["other_worker_reserved"], "another native core cannot reserve the current page worker")
			AssertEqual(1, Receipt["primary_worker_spawns"], "the genuine current core must remain admitted after rejecting the other")
		}
		AssertEqual(1, Receipt["native_callbacks"])
		AssertEqual(0, State.Code, "the genuine native message was not admitted: " . State.ErrorText . State.Output)
		AssertEqual(1, Receipt["worker_spawns"], "the actual request_refresh must reach the sole external process boundary")
		AssertEqual(1, Receipt["worker_starts"])
		AssertEqual(1, Receipt["worker_stops"])
		AssertEqual("", State.ErrorText)
	} catch as Failure {
		Primary := Failure
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Accepted := Handle.terminate()
				Retired := Accepted is Integer && Accepted == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if !Retired
			RetirementDebt := Handle
		else if !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the exact native child must physically retire before a passing result")
}

Test("Metrics native sender: the current COM core reaches the real refresh host (metrics-native-sender-identity)",
	_MVSP_NativeSender)

Test("Metrics native sender: another COM core at the same URL is refused before the current core succeeds (metrics-native-other-core)",
	_MVSP_NativeSender.Bind("other-core"))
