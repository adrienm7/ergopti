; static/ergopti_plus/windows/tests/unit/infra/lifecycle/test_uninstall.ahk
;
; ==============================================================================
; MODULE: Uninstall Authorization Tests
; DESCRIPTION:
; Exercises cancellation and terminal authorization through real kernel events.
; No worker is launched and no executable or personal file is removed.
; ==============================================================================

_TestUninstallSuperseded() {
	State := UninstallState()
	State["Owner"] := Map("Phase", "Ready")
	AssertFalse(UninstallCommit("Reload"))
	AssertFalse(State.Has("Owner"), "a reload permanently revokes removal")
	UninstallCancel()
	AssertTrue(UninstallCommit("Exit"), "an ordinary exit has no pending removal")
}
Test("Uninstall: reload revokes the pending removal (menu-uninstall)", _TestUninstallSuperseded)

_TestUninstallBinaryIdentity() {
	Bytes := Buffer(3)
	NumPut("UChar", 0, "UChar", 255, "UChar", 97, Bytes)
	AssertEqual("da8509555ad27dac0593c6952d947eff96058cb6e81376f852f54ef9caf7e652",
		CryptoSha256Bytes(Bytes), "binary identity retains NUL and non-UTF8 bytes")
}
Test("Uninstall: executable identity hashes raw bytes (menu-uninstall)", _TestUninstallBinaryIdentity)

_TestUninstallCommitEvent() {
	Name := "Local\ErgoptiPlus.Uninstall.Test." . PLC_CurrentProcessId() . "." . A_TickCount
	Event := PLC_CreateNamedManualResetEvent(Name)
	Observer := DllCall("Kernel32\OpenEventW", "UInt", 0x100000, "Int", false, "Str", Name, "Ptr")
	AssertTrue(Observer != 0)
	; SYNCHRONIZE grants observation only; even a cancellation defect cannot
	; terminate this test process through the handle placed in the owner.
	Info := Buffer(A_PtrSize * 2 + 8, 0)
	NumPut("Ptr", PLC_OpenCurrentProcessHandle(0x100000), Info, 0)
	State := UninstallState()
	State["Owner"] := Map("Phase", "Ready", "Commit", Event, "ProcessInfo", Info)
	try {
		AssertEqual(0x102, PLC_WaitHandle(Observer, 0), "preparation is not authorization")
		AssertTrue(UninstallCommit("Exit"))
		AssertEqual(0, PLC_WaitHandle(Observer, 0), "terminal exit signals COMMIT")
		AssertFalse(State.Has("Owner"), "authorization is consumed once")
	} finally {
		UninstallCancel()
		PLC_CloseNativeHandle(Observer)
	}
}
Test("Uninstall: terminal exit signals its native capability once (menu-uninstall)", _TestUninstallCommitEvent)

/** Fake capabilities exercise READY timing without launching or removing anything. */
_TestUninstallClock(Started, Scenario, FirstElapsed := 0) {
	Info := Buffer(A_PtrSize * 2 + 8, 0)
	NumPut("Ptr", 22, Info, 0)
	Owner := Map("Ready", 11, "ProcessInfo", Info)
	Waited := []
	Sleeps := []
	ClockCalls := 0
	Ready := Scenario == "immediate"
	Revoked := false
	Clock() {
		ClockCalls += 1
		Elapsed := ClockCalls == 1 ? 0 : Sleeps.Length == 0 ? FirstElapsed : Max(FirstElapsed + 1, 10001)
		if Scenario == "revoked" && Sleeps.Length > 0
			Elapsed := 10000
		return Started + Elapsed
	}
	Wait(Handle, Milliseconds) {
		AssertEqual(0, Milliseconds)
		Waited.Push(Handle)
		if Revoked
			AssertEqual(0, Handle, "every poll must reread the revoked native capability")
		if Handle == 11
			return Ready ? 0 : 0x102
		if Handle == 22
			return Scenario == "process-exit" ? 0 : 0x102
		AssertEqual(0, Handle, "no unrelated native handle may be observed")
		return 0xFFFFFFFF
	}
	Nap(Milliseconds) {
		AssertEqual(20, Milliseconds, "the original polling cadence remains intact")
		Sleeps.Push(Milliseconds)
		if Sleeps.Length > 2
			throw Error("Independent iteration guard: the deadline did not stop polling")
		if Scenario == "late-ready"
			Ready := true
		if Scenario == "revoked" {
			Owner["Ready"] := 0
			NumPut("Ptr", 0, Info, 0)
			Revoked := true
		}
	}
	Caught := 0
	Result := false
	try Result := _UninstallAwaitReady(Owner, Info, Clock, Wait, Nap)
	catch as Err
		Caught := Err
	if Scenario == "immediate" || Scenario == "late-ready" {
		AssertEqual(0, Caught, "READY wins before the timeout check")
		AssertTrue(Result)
		AssertEqual(Scenario == "immediate" ? 1 : 2, ClockCalls,
			"READY admission must not sample the deadline after the signal")
		AssertEqual(Scenario == "immediate" ? 1 : 3, Waited.Length,
			"READY admission must not inspect the worker after the signal")
		AssertEqual(Scenario == "immediate" ? 0 : 1, Sleeps.Length)
	} else {
		AssertTrue(IsObject(Caught), "pending or revoked capabilities must refuse readiness")
		AssertTrue(InStr(Caught.Message, "The removal worker did not become ready"),
			"the real deadline or exact worker state must refuse, rather than the iteration guard")
		if FirstElapsed > 10000
			AssertEqual(1, Waited.Length, "timeout must short-circuit the worker poll")
		ExpectedSleeps := Scenario == "process-exit" || FirstElapsed > 10000 ? 0 : 1
		AssertEqual(ExpectedSleeps, Sleeps.Length, "strict expiry preserves the exact-boundary poll")
		if Scenario == "revoked" {
			AssertEqual(0, Waited[-1], "the process handle is reread after cancellation")
			AssertEqual(0, Waited[-2], "the READY handle is reread after cancellation")
		}
	}
}
Test("Uninstall ready-clock-native64: ordinary immediate READY", (*) => _TestUninstallClock(100, "immediate"))
Test("Uninstall ready-clock-native64: DWORD-boundary immediate READY", (*) => _TestUninstallClock(0xFFFFFFF0, "immediate"))
Test("Uninstall ready-clock-native64: ordinary overdue READY wins", (*) => _TestUninstallClock(100, "late-ready", 10000))
Test("Uninstall ready-clock-native64: DWORD-boundary overdue READY wins", (*) => _TestUninstallClock(0xFFFFFFF0, "late-ready", 10000))
Test("Uninstall ready-clock-native64: ordinary deadline minus one", (*) => _TestUninstallClock(100, "pending", 9999))
Test("Uninstall ready-clock-native64: DWORD-boundary deadline minus one", (*) => _TestUninstallClock(0xFFFFFFF0, "pending", 9999))
Test("Uninstall ready-clock-native64: ordinary exact deadline", (*) => _TestUninstallClock(100, "pending", 10000))
Test("Uninstall ready-clock-native64: DWORD-boundary exact deadline", (*) => _TestUninstallClock(0xFFFFFFF0, "pending", 10000))
Test("Uninstall ready-clock-native64: ordinary deadline plus one", (*) => _TestUninstallClock(100, "pending", 10001))
Test("Uninstall ready-clock-native64: DWORD-boundary deadline plus one", (*) => _TestUninstallClock(0xFFFFFFF0, "pending", 10001))
Test("Uninstall ready-clock-native64: ordinary process exit", (*) => _TestUninstallClock(100, "process-exit", 100))
Test("Uninstall ready-clock-native64: DWORD-boundary process exit", (*) => _TestUninstallClock(0xFFFFFFF0, "process-exit", 100))
Test("Uninstall ready-clock-native64: ordinary cancellation revokes both handles", (*) => _TestUninstallClock(100, "revoked", 100))
Test("Uninstall ready-clock-native64: DWORD-boundary cancellation revokes both handles", (*) => _TestUninstallClock(0xFFFFFFF0, "revoked", 100))

for Started in [100, 0x100000064]
	for Elapsed in [0x100000000, 0x10000270F, 0x100002710, 0x100002711]
		Test("Uninstall ready-clock-native64: long pending origin=" . Started . " elapsed=" . Elapsed,
			_TestUninstallClock.Bind(Started, "pending", Elapsed))


; A real native READY result is not a capability after its owner retires.
; Only the Wait port observes the actual native return and then triggers the
; same public cancellation called by every shutdown-refusal gate.

_R7UR_RevokedReadyReturn() {
	State := UninstallState()
	AssertFalse(State.Has("Owner"), "a foreign uninstall transaction cannot be detached by this fixture")
	PreviousCritical := Critical("On")
	Event := 0, Owner := 0, Observed := 0, WaitReturned := false, Result := false, Caught := 0
	try {
		Name := "Local\ErgoptiPlus.Uninstall.ReadyRetirement." . PLC_CurrentProcessId() . "." . A_TickCount
		Event := PLC_CreateNamedManualResetEvent(Name)
		AssertTrue(PLC_SetEventHandle(Event), "the actual private kernel READY event must be signaled")
		Info := Buffer(A_PtrSize * 2 + 8, 0)
		Owner := Map("Phase", "Preparing", "Ready", Event, "ProcessInfo", Info)
		State["Owner"] := Owner
		Wait(Handle, Milliseconds) {
			NativeResult := PLC_WaitHandle(Handle, Milliseconds)
			if Handle == Event && NativeResult == 0 {
				Observed += 1
				UninstallCancel()
				WaitReturned := true
			}
			return NativeResult
		}
		try Result := _UninstallAwaitReady(Owner, Info, () => A_TickCount, Wait)
		catch as Err
			Caught := Err
		AssertEqual(1, Observed, "the real wait must have observed the actual READY event before cancellation")
		AssertTrue(WaitReturned, "cancellation must return normally instead of manufacturing the expected refusal")
		AssertFalse(State.Has("Owner"), "public cancellation consumes the original transaction identity")
		AssertEqual(0, Owner.Get("Ready", 0), "public cancellation withdraws the exact native READY capability")
		AssertTrue(IsObject(Caught), "a revoked native READY receipt must refuse instead of admitting continuation")
		AssertFalse(Result, "withdrawn removal ownership cannot become ready")
	} finally {
		if State.Get("Owner", 0) == Owner
			UninstallCancel()
		else if IsObject(Owner)
			_UninstallClose(Owner, true)
		else if Event
			PLC_CloseNativeHandle(Event)
		Critical(PreviousCritical)
	}
}
Test("Uninstall: retirement after native READY return cannot admit continuation (uninstall-ready-retirement)",
	_R7UR_RevokedReadyReturn)


_R7NB_DiagnosticAssertionHeadline() {
	Output := "node:assert:150`n  throw new AssertionError(obj);`n  ^`n`n"
		. "AssertionError [ERR_ASSERTION]: The native worker refused cleanup.`n"
		. "Foreign startup shortcut removed`n    at Object.<anonymous> (native-policy.cjs:149:9)`n"
	Headline := NativeCliFailureHeadline(Output)
	AssertEqual("AssertionError [ERR_ASSERTION]: The native worker refused cleanup. Foreign startup shortcut removed", Headline)
	Caught := 0
	try AssertEqual(0, 1, "native uninstall policy output: " . Headline)
	catch as Err
		Caught := Err
	AssertTrue(IsObject(Caught), "the real status assertion must remain a failure")
	FirstLine := StrSplit(Caught.Message, "`n")[1]
	AssertTrue(InStr(FirstLine, "Foreign startup shortcut removed"), "the actual cause must survive the annotation's first-line boundary")
	AssertFalse(InStr(FirstLine, "node:assert:150"), "bootstrap frames cannot hide the actual assertion message")
}
Test("Uninstall native policy diagnostics: assertion cause survives the first-line annotation (uninstall-native-policy-diagnostic)",
	_R7NB_DiagnosticAssertionHeadline)

_R7NB_DiagnosticRuntimeHeadline() {
	AssertEqual("Error: native policy process could not start", NativeCliFailureHeadline("`nError: native policy process could not start`n    at start (native-policy.cjs:1:1)`n"))
	LongOutput := "AssertionError [ERR_ASSERTION]: "
	Loop 2000
		LongOutput .= "x"
	Headline := NativeCliFailureHeadline(LongOutput)
	AssertTrue(StrLen(Headline) > 0 && StrLen(Headline) < StrLen(LongOutput), "the annotation must remain bounded without losing the assertion identity")
	AssertTrue(InStr(Headline, "AssertionError [ERR_ASSERTION]: ") == 1)
}
Test("Uninstall native policy diagnostics: runtime errors remain visible and bounded (uninstall-native-policy-diagnostic)",
	_R7NB_DiagnosticRuntimeHeadline)

; The common JavaScript lane is Linux. Register its Windows-only policy CLI in
; the native driver suite so an OS skip cannot certify native uninstall policy.
_R7NB_NativeUninstallPolicy() {
	global _DriverDir, _SR_TreeOwnedTasks, _SR_TreeCaptureDebts
	Repo := FSResolveDirectoryPath(_DriverDir . "\..\..\..")
	Script := Repo . "\tools\test\test-windows-uninstall.cjs"
	AssertTrue(FileExist(Script), "the actual native uninstall policy CLI must be present")
	Observed := [], Control := Map(), Handle := 0
	Capture(State, Native) {
		Control["state"] := State
		Control["capture_file"] := State["TmpFile"]
		Control["capture_directory"] := State["CaptureDir"]
	}
	try {
		Handle := ShellRunner_SpawnTreeOwned("node.exe", [Script],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "output", Out)), , Capture, 16384)
		AssertTrue(Handle.start(), "the actual Windows Node policy process must start")
		Started := A_TickCount
		while !TickExpired64(Started, 45000) {
			_SR_TreePoll()
			if Observed.Length == 1 && Control.Has("state") {
				Claim := Control["state"]["TerminalClaim"]
				if Claim is Map && Claim["TreeQuiesced"]
						&& !FileExist(Claim["TmpFile"]) && !DirExist(Claim["CaptureDir"])
					break
			}
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the actual native uninstall policy must settle within its bound")
		if Observed[1]["exit"] != 0
			NativeCliPrintFailureOutput("native uninstall policy", Observed[1]["output"])
		AssertEqual(0, Observed[1]["exit"], "native uninstall policy output: " . NativeCliFailureHeadline(Observed[1]["output"]))
		Marker := "[OK] Windows uninstall requires confirmation, exact process exit and an unchanged owned executable."
		Markers := 0
		for Line in StrSplit(StrReplace(Observed[1]["output"], "`r`n", "`n"), "`n")
			if Line == Marker
				Markers += 1
		AssertEqual(1, Markers, "a platform SKIP or missing native policy cannot replace the actual Windows success receipt")
		AssertTrue(Control.Has("state"), "the real native construction observer must retain its exact owner")
		State := Control["state"], Claim := State["TerminalClaim"]
		AssertTrue(Control["capture_file"] != "" && Control["capture_directory"] != "", "the native CLI must own its actual bounded capture")
		AssertEqual(Control["capture_file"], Claim["TmpFile"], "completion cannot erase capture identity instead of retiring its file")
		AssertEqual(Control["capture_directory"], Claim["CaptureDir"], "completion retains the original capture directory identity")
		AssertTrue(Claim is Map && Claim["TreeQuiesced"], "the exact Node and PowerShell process tree must be physically retired")
		AssertFalse(State["FinalizationPending"], "native finalization cannot remain pending after policy success")
		for Key in ["ProcessHandle", "ThreadHandle", "JobHandle"] {
			AssertEqual(0, State[Key], "the original construction owner must release " . Key)
			AssertEqual(0, Claim[Key], "the terminal owner must release " . Key)
		}
		AssertEqual(0, Claim["NativeErrors"].Length, "the actual native retirement must acknowledge all resources")
		AssertFalse(_SR_TreeOwnedTasks.Has(State["TaskId"]), "the completed policy cannot retain an active native owner")
		AssertFalse(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)), "the completed policy cannot retain private capture cleanup debt")
		AssertFalse(FileExist(Claim["TmpFile"]), "the private native policy capture must be removed")
		AssertFalse(DirExist(Claim["CaptureDir"]), "the private native policy capture directory must be removed")
	} finally {
		if IsObject(Handle) {
			Acknowledged := Handle.terminate()
			if !Acknowledged {
				AssertTrue(Control.Has("state"), "an unacknowledged task cannot lose its exact cleanup owner")
				State := Control["state"]
				AssertTrue(State["TreeQuiesced"] && !State["FinalizationPending"],
					"an already completed task must retain its genuine physical retirement receipt")
			}
		}
	}
}
Test("Uninstall native policy: actual Windows CLI executes the removal and startup controls (uninstall-native-policy-cli)",
	_R7NB_NativeUninstallPolicy)

; Native allocation refusal and the exact public cancellation handoff.
_R7UA_WorkerAllocation(Foreign) {
	State := UninstallState()
	AssertFalse(State.Has("Owner"), "fixture cannot retire a foreign uninstall transaction")
	Owner := 0
	Root := A_Temp . "\ergopti_r7_uninstall_allocation_" . PLC_CurrentProcessId() . "_" . A_TickCount
	Source := Root . "\worker-source.ps1", Script := Root . "\ergopti-uninstall-0123456789abcdef.ps1"
	try {
		_RIT_WriteFile(Source, "owned worker source`n")
		if Foreign
			AssertTrue(FSWriteCreateDurable(Script, "foreign existing stage`n"))
		Owner := Map("Phase", "Preparing", "Script", Script, "ScriptCopied", false)
		State["Owner"] := Owner
		Caught := 0
		try {
			FileCopy(Source, Script, false)
			Owner["ScriptCopied"] := true
		}
		catch as Err
			Caught := Err
		if Foreign {
			AssertTrue(IsObject(Caught), "the actual create-only copy must refuse the occupied stage")
			AssertEqual("foreign existing stage`n", FSReadUtf8Exact(Script), "native refusal must leave the foreign file unchanged")
		} else {
			AssertEqual(0, Caught, "the actual create-only copy must acquire an absent stage")
			AssertEqual("owned worker source`n", FSReadUtf8Exact(Script))
		}
		UninstallCancel()
		AssertFalse(State.Has("Owner"), "public cancellation must retire this handoff")
		if Foreign {
			AssertTrue(FileExist(Script), "a refused native create never grants deletion authority to public cancellation")
			AssertEqual("foreign existing stage`n", FSReadUtf8Exact(Script))
		} else
			AssertFalse(FileExist(Script), "an acquired worker copy must be retired on cancellation")
	} finally {
		if State.Has("Owner") && State["Owner"] == Owner
			State.Delete("Owner")
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("Uninstall worker allocation: actual acquired copy retires on public cancel (uninstall-worker-allocation)", _R7UA_WorkerAllocation.Bind(false))
Test("Uninstall worker allocation: actual refused copy retains foreign file (uninstall-worker-allocation)", _R7UA_WorkerAllocation.Bind(true))
