; tests/unit/test_shell_runner_tree_close_recovery.ahk

; ==============================================================================
; MODULE: Tree Native Close Recovery Tests
; DESCRIPTION:
; Real protected handles refuse close without losing their validity. Exercise
; launch-thread, natural-process and terminal-job ownership through recovery.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRTCR_CloseRecovery(Kind, Forced) {
	static ProtectFromClose := 0x0002
	AssertEqual(0, _SR_TreeOwnedTasks.Count)
	AssertEqual(0, _SR_TreeNativeDebts.Count)
	AssertEqual(0, _SR_ActiveTasks.Count)
	AssertEqual(0, _SR_PendingCallbacks.Count)
	Scope := {State: 0, Protected: 0, Results: []}
	WasSuspended := A_IsSuspended
	PreviousCritical := Critical("On")
	Observe(State, Native) {
		Scope.State := State
		Value := Native[Kind]
		if !DllCall("Kernel32\SetHandleInformation", "Ptr", Value,
			"UInt", ProtectFromClose, "UInt", ProtectFromClose, "Int")
			throw OSError(A_LastError, "SetHandleInformation")
		Scope.Protected := Value
	}
	Done(Code, *) {
		Scope.Results.Push(Code)
	}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", A_ScriptDir . "\support\legacy_exit_code_child.ahk", "37"], Done, , Observe)
	try {
		Suspend(true)
		AssertTrue(Handle.start())
		AssertEqual(Scope.Protected, Scope.State[Kind], "launch must retain each protected capability")
		AssertTrue(_SRTOW_WaitForExactProcessExit(Scope.State["ProcessHandle"]))
		Suspend(false)
		if Forced {
			AssertFalse(Handle.requestTerminate(), "protected native ownership must remain pending")
			Claim := Scope.State["TerminalClaim"]
			AssertEqual(Scope.Protected, Claim[Kind])
			AssertEqual(37, Claim["ExitCode"], "the first attempt must retain the real exit receipt")
			AssertTrue(_SR_TreeNativeDebts.Has(ObjPtr(Claim)))
		} else {
			_SR_TreePoll()
			Owner := Scope.State["TerminalClaimed"] ? Scope.State["TerminalClaim"] : Scope.State
			AssertEqual(Scope.Protected, Owner[Kind], "natural polling must retain or transfer the refused close")
			AssertTrue(Scope.State["TerminalClaimed"] ? _SR_TreeNativeDebts.Has(ObjPtr(Owner))
				: _SR_TreeOwnedTasks.Has(Scope.State["TaskId"]), "the exact owner must remain registered")
		}
		AssertEqual(0, Scope.Results.Length, "refused release must not publish completion")
		Flags := 0
		AssertTrue(DllCall("Kernel32\GetHandleInformation", "Ptr", Scope.Protected, "UInt*", &Flags, "Int"))
		AssertTrue((Flags & ProtectFromClose) != 0, "the retained capability must remain valid and protected")
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope.Protected,
			"UInt", ProtectFromClose, "UInt", 0, "Int"))
		Scope.Protected := 0
		Started := A_TickCount
		while !Scope.Results.Length && TickElapsed(Started) < SRTOW_EXIT_SIGNAL_SETTLE_MS {
			_SR_TreePoll()
			Sleep(SRTOW_PID_POLL_MS)
		}
		AssertEqual(1, Scope.Results.Length, "the retry owner must deliver after release recovers")
		AssertEqual(37, Scope.Results[1], "a release retry must preserve the observed process exit code")
		AssertEqual(0, _SR_TreeNativeDebts.Count)
		AssertEqual(0, Scope.State["TerminalClaim"]["OwnerState"], "completed ownership must not retain a reference cycle")
		_SR_TreePoll()
		AssertEqual(1, Scope.Results.Length)
	} finally {
		try {
			if Scope.Protected {
				AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope.Protected,
					"UInt", ProtectFromClose, "UInt", 0, "Int"))
				Scope.Protected := 0
			}
		} finally {
			try {
				try Handle.detach()
				finally AssertTrue(Handle.terminate(), "the exact fixture owner must finish cleanup")
				_SR_TreePoll()
			} finally {
				Suspend(WasSuspended)
				Critical(PreviousCritical)
			}
		}
	}
}

Test("shell runner: protected launch thread close recovers (shell-tree-native-refusal)",
	_SRTCR_CloseRecovery.Bind("ThreadHandle", false))
Test("shell runner: protected natural process close recovers (shell-tree-native-refusal)",
	_SRTCR_CloseRecovery.Bind("ProcessHandle", false))
Test("shell runner: protected terminal job close preserves exit code (shell-tree-native-refusal)",
	_SRTCR_CloseRecovery.Bind("JobHandle", true))

_SRTCR_UnpublishedCloseRecovery() {
	static ProtectFromClose := 0x0002
	AssertEqual(0, _SR_TreeNativeDebts.Count)
	AssertEqual(0, _SR_TreeOwnedTasks.Count)
	AssertEqual(0, _SR_ActiveTasks.Count)
	AssertEqual(0, _SR_PendingCallbacks.Count)
	Scope := {Protected: 0}
	Create(Application, Command, Flags, Startup, ProcessInfo) {
		PLC_CreateProcessWithInheritedHandles(Application, Command, Flags, Startup, ProcessInfo)
		Scope.Protected := NumGet(ProcessInfo, 0, "Ptr")
		if !DllCall("Kernel32\SetHandleInformation", "Ptr", Scope.Protected,
			"UInt", ProtectFromClose, "UInt", ProtectFromClose, "Int") {
			NativeError := A_LastError
			; Creation has succeeded even if fixture setup cannot return its receipt
			_SR_TreeQuiesceNative(Map("ProcessHandle", Scope.Protected,
				"ThreadHandle", NumGet(ProcessInfo, A_PtrSize, "Ptr"),
				"JobHandle", 0, "Assigned", false), true)
			Scope.Protected := 0
			throw OSError(NativeError, "SetHandleInformation")
		}
	}
	RejectStreamClose(*) {
		; Force the existing pre-adoption rollback boundary, not native close success
		return false
	}
	Claim := 0
	try {
		Failure := 0
		try _SR_TreeCreateSuspended(A_ComSpec, '"' . A_ComSpec . '" /d /c exit 37',
			"", false, Create, RejectStreamClose)
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "CloseHandle(input) failed")
		AssertTrue(Scope.Protected != 0)
		AssertEqual(1, _SR_TreeNativeDebts.Count, "unpublished creation rollback must retain native close debt")
		for Identity, Owner in _SR_TreeNativeDebts
			Claim := Owner
		AssertEqual(Scope.Protected, Claim["ProcessHandle"])
		AssertFalse(Claim.Has("OwnerState"), "an unpublished native bundle has no callback owner")
		AssertTrue(_SRTOW_WaitForExactProcessExit(Scope.Protected), "rollback must stop the exact suspended root")
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope.Protected,
			"UInt", ProtectFromClose, "UInt", 0, "Int"))
		Scope.Protected := 0
		_SR_TreePoll()
		AssertEqual(0, Claim["ProcessHandle"])
		AssertEqual(0, _SR_TreeNativeDebts.Count)
	} finally {
		try {
			if Scope.Protected {
				; Recover the exact registered owner even if an earlier assertion failed
				if !IsObject(Claim)
					for Identity, Owner in _SR_TreeNativeDebts
						if Owner["ProcessHandle"] = Scope.Protected
							Claim := Owner
				AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope.Protected,
					"UInt", ProtectFromClose, "UInt", 0, "Int"))
			}
		} finally {
			if IsObject(Claim)
				AssertTrue(_SR_TreeQuiesceNative(Claim, true))
			_SR_TreePoll()
		}
	}
}

Test("shell runner: unpublished launch close refusal retains retry ownership (shell-tree-native-refusal)",
	_SRTCR_UnpublishedCloseRecovery)
