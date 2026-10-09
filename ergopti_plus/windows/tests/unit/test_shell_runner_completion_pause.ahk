; tests/unit/test_shell_runner_completion_pause.ahk

; ==============================================================================
; MODULE: Legacy Completion Pause Boundary Tests
; DESCRIPTION:
; A poll snapshot does not authorize every callback for the rest of the tick.
; A first completion can suspend the driver before a second completion is due.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRCP_PauseBetweenCompletions(Tree := false) {
	AssertEqual(0, _SR_ActiveTasks.Count, "global polling fixture requires no foreign legacy tasks")
	AssertEqual(0, _SR_TreeOwnedTasks.Count, "global polling fixture requires no foreign tree tasks")
	AssertEqual(0, _SR_PendingCallbacks.Count, "global polling fixture requires no foreign deliveries")
	Handles := [], States := [], Observers := [], Results := []
	Registry := Tree ? _SR_TreeOwnedTasks : _SR_ActiveTasks
	Spawn := Tree ? ShellRunner_SpawnTreeOwned : ShellRunner_Spawn
	Poll := Tree ? _SR_TreePoll : _SR_Poll
	Codes := Tree ? [37, 42] : [37, 259]
	PreviousSuspend := A_IsSuspended
	PreviousCritical := Critical("On")
	OnDone(Code, Output, Diagnostic) {
		Results.Push({Code: Code, Output: Output, Diagnostic: Diagnostic, Paused: A_IsSuspended})
		if Results.Length = 1
			Suspend(true)
	}
	try {
		Suspend(true)
		for Code in Codes {
			Handle := Spawn.Call(A_AhkPath,
				["/ErrorStdOut", A_ScriptDir . "\support\legacy_exit_code_child.ahk", Code . ""], OnDone)
			Handles.Push(Handle)
			AssertTrue(Handle.start())
			Found := false
			for TaskId, State in Registry {
				if State["Pid"] != Handle.processId()
					continue
				States.Push(State)
				Observers.Push(_SRTOW_DuplicateNativeHandle(Tree ? State["ProcessHandle"]
					: State["Native"]["ProcessHandle"]))
				Found := true
				break
			}
			AssertTrue(Found, "the public launch must publish its exact native state")
		}
		for Observer in Observers
			AssertTrue(_SRTOW_WaitForExactProcessExit(Observer), "both children must exit before polling")
		if Tree {
			; Additional process references prevent Windows job accounting from draining
			for Position, Observer in Observers {
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Observer, "Int"))
				Observers[Position] := 0
			}
		}
		AssertEqual(0, Results.Length)
		Suspend(false)
		Poll.Call()
		AssertTrue(A_IsSuspended, "the first completion must suspend this poll tick")
		AssertEqual(1, Results.Length, "a stale poll snapshot must not deliver the second callback while paused")
		Poll.Call()
		AssertEqual(1, Results.Length, "repeated suspended polling must retain the second completion")
		Suspend(false)
		Poll.Call()
		AssertEqual(2, Results.Length, "resume must deliver the retained completion exactly once")
		Seen := Map()
		for Result in Results {
			AssertFalse(Result.Paused)
			AssertFalse(Seen.Has(Result.Code), "each result belongs to a distinct child")
			Seen[Result.Code] := true
			AssertEqual("legacy-exit-" . Result.Code, Result.Output)
			AssertEqual("", Result.Diagnostic)
		}
		AssertTrue(Seen.Has(Codes[1]) && Seen.Has(Codes[2]))
		Poll.Call()
		AssertEqual(2, Results.Length)
	} finally {
		try {
			for Handle in Handles
				Handle.detach()
			for Observer in Observers {
				if !Observer
					continue
				if _SRTOW_ExactProcessWait(Observer) = SRTOW_WAIT_TIMEOUT {
					AssertTrue(DllCall("Kernel32\TerminateProcess", "Ptr", Observer,
						"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"))
					AssertTrue(_SRTOW_WaitForExactProcessExit(Observer))
				}
			}
			Suspend(false)
			Poll.Call()
			for State in States {
				AssertFalse(Registry.Has(State["TaskId"]), "fixture states must be reaped")
				AssertFalse(DirExist(State["CaptureDir"]) != "", "fixture captures must be removed")
			}
		} finally {
			try {
				for Observer in Observers
					if Observer
						AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Observer, "Int"))
			} finally {
				Suspend(PreviousSuspend)
				Critical(PreviousCritical)
			}
		}
	}
}
Test("shell runner: completion suspension revokes the remaining poll snapshot (shell-completion-pause)",
	_SRCP_PauseBetweenCompletions)
Test("shell runner: tree completion suspension revokes the remaining poll snapshot (shell-completion-pause)",
	_SRCP_PauseBetweenCompletions.Bind(true))
