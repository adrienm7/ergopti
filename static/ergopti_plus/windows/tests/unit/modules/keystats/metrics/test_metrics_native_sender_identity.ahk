; tests/unit/modules/keystats/metrics/test_metrics_native_sender_identity.ahk

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

; Waits for a tree-owned child to settle. Completion is claimable only once its
; Job holds no process, so a child that exits with its causal message (the
; fixture's 30 s deadline) while a descendant it launched lives on (a WebView2
; browser whose controller never resolved, never supervised by the child)
; delivers nothing: dev CI reported only "did not settle" after 60 s. At the
; budget the tree is killed with its completion kept, and the diagnosis names
; whether the root had exited and what the child wrote.
; @param Handle {Object} The started ShellRunner_SpawnTreeOwned handle.
; @param State {Object} The _MVSP_Complete state.
; @param BudgetMs {Integer} How long the child may take.
; @returns {String} "" once settled within the budget, else the diagnosis.
_MVSP_AwaitSettled(Handle, State, BudgetMs) {
	Started := A_TickCount
	while State.Calls == 0 && TickElapsed(Started) < BudgetMs {
		_SR_TreePoll()
		Sleep(10)
	}
	if State.Calls != 0
		return ""
	RootExited := Handle.processId() == 0
	Tail := Handle.outputTail(8192)
	Handle.requestTerminate()
	Killed := A_TickCount
	while State.Calls == 0 && TickElapsed(Killed) < 10000 {
		_SR_TreePoll()
		Sleep(10)
	}
	return "no completion within " . BudgetMs . " ms; the child "
		. (RootExited ? "had exited and a descendant kept its Job alive" : "was still running")
		. "; it wrote: " . _MVSP_Cause(State.Calls ? State.ErrorText . "`n" . State.Output : Tail)
}

; What a child wrote besides its receipt: the receipt is long and a failure
; message is cut short, so the cause must come first and alone.
; @param Text {String} The child's captured output.
; @returns {String} Its non-receipt lines, joined by " | ".
_MVSP_Cause(Text) {
	Cause := ""
	for Line in StrSplit(Text, "`n", "`r")
		if Line != "" && InStr(Line, "RECEIPT ") != 1
			Cause .= (Cause == "" ? "" : " | ") . Line
	return Cause
}

; A child that writes its cause and exits while its descendant lives on is
; reported with that cause, not as a silent stall.
_MVSP_SurvivorDiagnosisCase() {
	global _DriverDir
	Fixture := _DriverDir . "\tests\fixtures\tree_survivor_child.ahk"
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Fixture],
		_MVSP_Complete.Bind(State))
	try {
		AssertTrue(Handle.start(), "the survivor fixture must start")
		Diagnosis := _MVSP_AwaitSettled(Handle, State, 3000)
		AssertContains(Diagnosis, "had exited and a descendant kept its Job alive")
		AssertContains(Diagnosis, "survivor fixture: deadline before the controller")
	} finally AssertTrue(Handle.terminate() == true, "the survivor tree must retire")
}
Test("Metrics native sender: a child whose descendant outlives it reports its cause (metrics-native-sender-identity)",
	_MVSP_SurvivorDiagnosisCase)

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
		; The child's 30 s prerequisite deadline, then up to 40 s each for the
		; browser exit and the profile deletion on a saturated runner.
		Unsettled := _MVSP_AwaitSettled(Handle, State, 150000)
		for Line in StrSplit(Unsettled, "`n", "`r")
			if Line != ""
				_TestPrint("# native-webview-sender unsettled: " . Line)
		AssertEqual("", Unsettled, "the owned native child did not settle")
		AssertEqual(1, State.Calls, "the owned native child did not settle: " . State.ErrorText . State.Output)
		Receipts := []
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1 {
				_TestPrint("# native-webview-sender " . Line)
				Receipts.Push(JsonParse(SubStr(Line, 9)))
			} else if Line != ""
				; An assertion message is cut short; the child's own cause is not.
				_TestPrint("# native-webview-sender child: " . Line)
		for Line in StrSplit(State.ErrorText, "`n", "`r")
			if Line != ""
				_TestPrint("# native-webview-sender child: " . Line)
		AssertEqual(1, Receipts.Length, "native creation/source/COM prerequisites failed before a causal receipt: " . State.ErrorText . State.Output)
		Receipt := Receipts[1]
		AssertEqual(NativePid, Receipt["child_pid"], "the receipt must belong to the actual supervised child")
		AssertEqual(FixtureHash, Receipt["fixture_sha256"])
		AssertEqual(HostHash, Receipt["host_sha256"])
		AssertEqual(RuntimeHash, Receipt["runtime_sha256"])
		AssertEqual(A_AhkVersion, Receipt["runtime_version"])
		for Key in ["core_identity_equal", "iunknown_identity_equal", "native_source_equal", "current_epoch",
			"same_entry", "not_suspended", "browser_retired", "profile_retired"]
			AssertTrue(Receipt[Key], "the real callback prerequisite or physical retirement was not proved: " . Key
				. "; the child wrote: " . _MVSP_Cause(State.ErrorText . "`n" . State.Output))
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
