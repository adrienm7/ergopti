; tests/unit/adapters/test_process_lifecycle_app_events.ahk

; ==============================================================================
; MODULE: ProcessLifecycle Launch and Quit Events
; DESCRIPTION:
; The ProcessLifecycle port fires onAppLaunch and onAppQuit with the
; executable name. The Windows adapter accepted those callbacks and never
; called them, while the Linux and macOS adapters do. A real, uniquely named
; child process must now be reported once when it starts and once when it
; exits. Snapshot failures and pauses must never be read as an empty machine:
; neither may replay every process as quit and then launched again.
; ==============================================================================

#Requires AutoHotkey v2.0

_PLCAE_Record(Events, Kind, Name, Target) {
	if Name = Target
		Events.Push(Kind)
}

_PLCAE_AwaitEvent(Events, Kind, TimeoutMs) {
	Begin := A_TickCount
	while TickElapsed(Begin) < TimeoutMs {
		for Event in Events
			if Event == Kind
				return true
		Sleep(50)
	}
	return false
}

_PLCAE_RealChildIsReported() {
	global PLC_Running
	AssertFalse(PLC_Running, "the fixture requires an idle process lifecycle adapter")
	Root := A_Temp . "\ergopti_plc_events_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	DirCreate(Root)
	Name := "ergopti_plc_probe_" . A_TickCount . ".exe"
	Executable := Root . "\" . Name
	FileCopy(A_AhkPath, Executable)
	Script := Root . "\probe.ahk"
	FileAppend("#NoTrayIcon`nSleep(4000)`nExitApp(0)`n", Script, "UTF-8")
	Events := []
	Pid := 0
	try {
		PLC_OnAppLaunch(_PLCAE_Record.Bind(Events, "launch", , Name))
		PLC_OnAppQuit(_PLCAE_Record.Bind(Events, "quit", , Name))
		AssertTrue(PLC_Start(), "the adapter must start its poller")
		; Let the first snapshot become the baseline before the child exists.
		Sleep(500)
		Run('"' . Executable . '" "' . Script . '"', Root, "Hide", &Pid)
		AssertTrue(_PLCAE_AwaitEvent(Events, "launch", 10000), "the launch of a new executable must be reported")
		AssertTrue(ProcessWaitClose(Pid, 15) == 0, "the probe child must exit on its own")
		Pid := 0
		AssertTrue(_PLCAE_AwaitEvent(Events, "quit", 10000), "the exit of its last process must be reported")
		AssertEqual(2, Events.Length, "each transition must be reported exactly once")
	} finally {
		PLC_Stop()
		if Pid
			ProcessClose(Pid)
		ProcessWaitClose(Name, 5)
		DirDelete(Root, true)
	}
}
Test("ProcessLifecycle: a real child is reported once on launch and once on quit (plc-app-events)",
	_PLCAE_RealChildIsReported)

class _PLCAE_Snapshots {
	__New(Sequence) {
		this.Sequence := Sequence
		this.Index := 0
	}
	Call() {
		this.Index += 1
		return this.Sequence[this.Index]
	}
}

_PLCAE_Set(Names*) {
	Set := Map()
	Set.CaseSense := "Off"
	for Name in Names
		Set[Name] := true
	return Set
}

_PLCAE_Step(Names) {
	global PLC_LastProcessTick
	PLC_LastProcessTick := 0
	_PLC_PollProcesses()
}

; A refused snapshot and a pause both drop to "no knowledge", never "no process".
_PLCAE_FailuresAreNotAnEmptyMachine() {
	global PLC_PROCESS_SNAPSHOT_DRIVER, PLC_LastProcesses, PLC_LastProcessTick
	SavedDriver := PLC_PROCESS_SNAPSHOT_DRIVER
	Events := []
	try {
		PLC_OnAppLaunch((Name) => Events.Push("launch:" . Name))
		PLC_OnAppQuit((Name) => Events.Push("quit:" . Name))
		PLC_PROCESS_SNAPSHOT_DRIVER := _PLCAE_Snapshots([_PLCAE_Set("a.exe", "b.exe"), 0,
			_PLCAE_Set("A.EXE", "b.exe", "c.exe"), _PLCAE_Set("a.exe", "b.exe", "c.exe", "d.exe"),
			_PLCAE_Set("a.exe", "c.exe", "d.exe")])
		_PLCAE_Step("baseline")
		AssertEqual(0, Events.Length, "the first snapshot is a baseline, not a launch of everything")
		_PLCAE_Step("refused")
		AssertEqual(0, Events.Length, "a refused snapshot must not report every process as quit")
		_PLCAE_Step("recovered")
		AssertEqual(1, Events.Length, "only the genuinely new executable is reported after recovery")
		AssertEqual("launch:c.exe", Events[1], "executable names compare case-insensitively")
		Suspend(1)
		try PLC_Poll()
		finally Suspend(0)
		_PLCAE_Step("after pause")
		AssertEqual(1, Events.Length, "a pause re-baselines instead of replaying what changed during it")
		_PLCAE_Step("quit")
		AssertEqual(2, Events.Length, "the exit of a known executable is reported")
		AssertEqual("quit:b.exe", Events[2])
	} finally {
		PLC_PROCESS_SNAPSHOT_DRIVER := SavedDriver
		PLC_Stop()
	}
}
Test("ProcessLifecycle: refused snapshots and pauses never replay every process (plc-app-events)",
	_PLCAE_FailuresAreNotAnEmptyMachine)
