; tests/unit/test_reload_successor_quiescence.ahk

; ==============================================================================
; MODULE: Reload Successor Physical Quiescence Tests
; DESCRIPTION:
; Separates a termination request from the actual process terminal observation.
; Direct state controls retain authority across several live or failed probes;
; a genuine child verifies that callback delivery observes its owned handle.
; ==============================================================================

#Requires AutoHotkey v2.0

global _RQS_BudgetChildren := Map()





; ============================================
; ============================================
; ======= 1/ Actual process retirement =======
; ============================================
; ============================================

_RQS_RefusedNative(State, Reason) {
	State.Callbacks += 1
	State.Wait := PLC_WaitHandle(State.Successor["handle"], 0)
	State.BundleStillOwned := _ConfigWriteTerminalIsActive()
}

_RQS_NativeTerminate(State, Successor) {
	State.Terminations += 1
	return ReloadSuccessorTerminate(Successor)
}

_RQS_NativeClose(State, Successor) {
	State.Closes += 1
	return ReloadSuccessorClose(Successor)
}

_RQS_NativeLaunch(State) {
	PowerShell := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
	State.Successor := ReloadSuccessorLaunch('"' . PowerShell
		. '" -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"', A_Temp, "Hide")
	return State.Successor
}

_RQS_RealRefusalWaitsForNativeExit() {
	PreviousCritical := Critical("Off")
	Bundle := _RTP_Acquire("quiescence-native")
	State := {Successor: 0, Terminations: 0, Closes: 0, Callbacks: 0,
		Wait: -1, BundleStillOwned: false}
	Record := 0
	Port := ReloadSuccessorPort()
	Port["terminate"] := _RQS_NativeTerminate.Bind(State)
	Port["close"] := _RQS_NativeClose.Bind(State)
	try {
		AssertTrue(ReloadTerminalInvoke(Bundle, 0, _RQS_NativeLaunch.Bind(State), Port,
			0, 0, _RQS_RefusedNative.Bind(State), _ConfigWriteTerminalRelease.Bind(Bundle)))
		Record := ReloadTerminalHandoffPending()
		AssertTrue(Record is Map)
		ReloadTerminalHandoffRefuse(Record, "native regression")
		Started := A_TickCount
		while State.Callbacks == 0 || State.Closes == 0 {
			AssertTrue(A_TickCount - Started < 5000, "The actual owned stop must complete through timer polling.")
			Sleep(10)
		}
		AssertEqual(0, State.Wait, "The real refusal callback sees WAIT_OBJECT_0 on its still-owned process handle.")
		AssertTrue(State.BundleStillOwned, "The caller sees its bundle before release.")
		AssertEqual(1, State.Callbacks)
		AssertEqual(1, State.Terminations)
		AssertEqual(1, State.Closes)
		AssertTrue(Record["stop_acknowledged"] && Record["close_acknowledged"])
		AssertEqual(0, State.Successor["handle"])
	} finally {
		; A failed assertion cannot discard the exact process or its stop owner.
		if State.Successor is Map && State.Successor["handle"] {
			if Record is Map && !Record["stop_requested"]
				ReloadTerminalHandoffRefuse(Record, "native regression cleanup")
			Started := A_TickCount
			while State.Successor["handle"] && A_TickCount - Started < 5000
				Sleep(10)
			AssertEqual(0, State.Successor["handle"], "Native cleanup must retain the case until actual physical retirement.")
		}
		_ConfigWriteTerminalRelease(Bundle)
		Critical(PreviousCritical)
	}
}
Test("reload quiescence: genuine native refusal callback observes terminal handle", _RQS_RealRefusalWaitsForNativeExit)





; ==========================================
; ==========================================
; ======= 2/ Deferred stop ownership =======
; ==========================================
; ==========================================

_RQS_AsyncRefusal() {
	global _RTP_Events, _ReloadTerminalHandoff
	_RTP_Events := []
	Bundle := _RTP_Acquire("quiescence-async")
	Port := _RTP_NewPort()
	try {
		Record := _RTP_Pending(Bundle, Port, 0, _RTP_Record.Bind("commit"),
			_RTP_Record.Bind("abort"), _RTP_Record.Bind("refused"),
			_RTP_Record.Bind("release"), _RTP_Record.Bind("retract"))
		AssertEqual(Record, ReloadTerminalHandoffClaim("Reload"))
		AssertTrue(ReloadTerminalHandoffCommit(Record))
		AssertTrue(ReloadTerminalHandoffRefuse(Record, "asynchronous native stop"))
		loop 3 {
			AssertEqual(Record, _ReloadTerminalHandoff)
			AssertTrue(_ConfigWriteTerminalIsActive())
			AssertTrue(Bundle.authorized && Bundle.shutdown_claimed)
			AssertEqual("launch,commit", _RTP_Join(_RTP_Events))
			AssertEqual(0, Port["probe"]["closed"])
			AssertEqual(1, Port["probe"]["terminated"])
			_RTP_RunArmed(Port)
		}
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		AssertEqual("launch,commit,abort,retract", _RTP_Join(_RTP_Events))
		AssertEqual(Record, _ReloadTerminalHandoff, "The deferred caller still has the exact global owner.")
		AssertTrue(Bundle.authorized && Bundle.shutdown_claimed, "Rearm waits for deferred handback.")
		_RTP_RunArmed(Port)
		AssertEqual("launch,commit,abort,retract,refused,release", _RTP_Join(_RTP_Events))
		AssertFalse(_ReloadTerminalHandoff is Map)
		AssertFalse(Bundle.authorized || Bundle.shutdown_claimed)
		AssertEqual(1, Port["probe"]["closed"])
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: multiple live polls retain claim before deferred refusal", _RQS_AsyncRefusal)

_RQS_StopFailure(Throwing) {
	global _RTP_Events, _ReloadTerminalHandoff
	_RTP_Events := []
	Bundle := _RTP_Acquire(Throwing ? "quiescence-throw" : "quiescence-false")
	Port := _RTP_NewPort()
	Port["probe"]["terminate_result"] := false
	Port["probe"]["terminate_throw"] := Throwing
	try {
		Record := _RTP_Pending(Bundle, Port, 0, 0, _RTP_Record.Bind("abort"),
			_RTP_Record.Bind("refused"), _RTP_Record.Bind("release"))
		AssertFalse(ReloadTerminalHandoffRefuse(Record, "failed native stop"))
		loop 3 {
			_RTP_RunArmed(Port)
			AssertEqual(Record, _ReloadTerminalHandoff)
			AssertTrue(_ConfigWriteTerminalIsActive())
			AssertEqual("launch", _RTP_Join(_RTP_Events))
			AssertEqual(0, Port["probe"]["closed"])
			AssertEqual(1, Port["probe"]["terminated"], "A failed stop is never automatically retried.")
		}
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		_RTP_RunArmed(Port)
		AssertTrue(Record["stop_acknowledged"], "Only later real terminal observation resolves the native debt.")
		AssertEqual("launch,abort,refused,release", _RTP_Join(_RTP_Events))
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: false stop request preserves exact debt until terminal", _RQS_StopFailure.Bind(false))
Test("reload quiescence: throwing stop request preserves exact debt until terminal", _RQS_StopFailure.Bind(true))

_RQS_ProbeFailure() {
	global _RTP_Events, _ReloadTerminalHandoff
	_RTP_Events := []
	Bundle := _RTP_Acquire("quiescence-probe")
	Port := _RTP_NewPort()
	Port["probe"]["alive_throw"] := true
	try {
		Record := _RTP_Pending(Bundle, Port, 0, 0, _RTP_Record.Bind("abort"))
		AssertFalse(ReloadTerminalHandoffRefuse(Record, "unproven native liveness"))
		_RTP_RunArmed(Port)
		AssertEqual(0, Port["probe"]["terminated"])
		AssertEqual(0, Port["probe"]["closed"])
		AssertEqual("launch", _RTP_Join(_RTP_Events))
		AssertEqual(Record, _ReloadTerminalHandoff)
		Port["probe"]["alive_throw"] := false
		_RTP_RunArmed(Port)
		AssertEqual(1, Port["probe"]["terminated"])
		AssertEqual(Record, _ReloadTerminalHandoff)
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		_RTP_RunArmed(Port)
		AssertTrue(Record["stop_acknowledged"])
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: failed probe never acknowledges dead process", _RQS_ProbeFailure)

_RQS_Abandon() {
	global _RTP_Events, _ReloadTerminalHandoff
	_RTP_Events := []
	Bundle := _RTP_Acquire("quiescence-abandon")
	Port := _RTP_NewPort()
	try {
		Record := _RTP_Pending(Bundle, Port, 0, 0, _RTP_Record.Bind("abort"),
			_RTP_Record.Bind("refused"), _RTP_Record.Bind("release"))
		AssertFalse(ReloadTerminalHandoffPrepareAbandon(Record, "Exit"))
		loop 3 {
			_RTP_RunArmed(Port)
			AssertEqual(Record, ReloadTerminalHandoffPending(), "The next ordinary exit borrows this same bundle.")
			AssertEqual("launch", _RTP_Join(_RTP_Events))
			AssertEqual(0, Port["probe"]["closed"])
			AssertEqual(1, Port["probe"]["terminated"])
		}
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		AssertEqual("abandon_ready", Record["state"])
		AssertEqual(Record, _ReloadTerminalHandoff)
		AssertTrue(_ConfigWriteTerminalIsActive())
		AssertTrue(ReloadTerminalHandoffAbandon(Record, "Exit"))
		AssertEqual("launch,abort", _RTP_Join(_RTP_Events))
		AssertEqual(1, Port["probe"]["closed"])
		AssertFalse(_ReloadTerminalHandoff is Map)
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: ordinary exit remains reversible while superseded child lives", _RQS_Abandon)

_RQS_LaunchWithCancel(State) {
	global _ReloadTerminalHandoff
	State.Record := _ReloadTerminalHandoff
	State.Canceled := ReloadTerminalHandoffCancel(State.Record)
	return _RTP_LaunchReturnsAtOnce()
}

_RQS_CancelOnlyUnlaunched() {
	global _ReloadTerminalHandoff
	Bundle := _RTP_Acquire("quiescence-cancel")
	Port := _RTP_NewPort()
	State := {Record: 0, Canceled: true}
	try {
		AssertTrue(ReloadTerminalInvoke(Bundle, 0, _RQS_LaunchWithCancel.Bind(State), Port))
		AssertFalse(State.Canceled, "Cancel cannot return the bundle during native creation.")
		AssertEqual(State.Record, ReloadTerminalHandoffPending())
		AssertFalse(ReloadTerminalHandoffCancel(State.Record), "Cancel cannot discard an acquired process.")
		AssertEqual(State.Record, _ReloadTerminalHandoff)
		AssertTrue(_ConfigWriteTerminalIsActive())
		AssertEqual(0, Port["probe"]["terminated"])
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: Cancel rejects launching and pending native ownership", _RQS_CancelOnlyUnlaunched)

_RQS_UnpublishLaunch(State) {
	global _ReloadTerminalHandoff
	State.Record := _ReloadTerminalHandoff
	_ReloadTerminalHandoff := false
	return _RTP_LaunchReturnsAtOnce()
}

_RQS_UnpublishedProcessStillOwnsBundle() {
	global _RTP_Events, _ReloadTerminalRetirements
	_RTP_Events := []
	Bundle := _RTP_Acquire("quiescence-unpublished")
	Port := _RTP_NewPort()
	State := {Record: 0}
	try {
		AssertTrue(ReloadTerminalInvoke(Bundle, 0, _RQS_UnpublishLaunch.Bind(State), Port,
			0, _RTP_Record.Bind("abort"), _RTP_Record.Bind("refused"), _RTP_Record.Bind("release")),
			"An acquired process transfers the caller bundle even when publication fails.")
		AssertEqual(State.Record, _ReloadTerminalRetirements[State.Record["id"]])
		AssertTrue(ReloadTerminalHandoffActive())
		AssertTrue(_ConfigWriteTerminalIsActive())
		AssertFalse(ReloadTerminalHandoffPrepare(Bundle) is Map)
		_RTP_RunArmed(Port)
		AssertEqual("launch", _RTP_Join(_RTP_Events))
		AssertEqual(0, Port["probe"]["closed"])
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		_RTP_RunArmed(Port)
		AssertEqual("launch,abort,refused,release", _RTP_Join(_RTP_Events))
		AssertEqual(0, _ReloadTerminalRetirements.Count)
		AssertEqual(1, Port["probe"]["closed"])
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: unpublished acquired process retains bundle and exact record", _RQS_UnpublishedProcessStillOwnsBundle)

_RQS_DeferredDeliveryFailure() {
	global _RTP_Events, _ReloadTerminalHandoff
	_RTP_Events := []
	Bundle := _RTP_Acquire("quiescence-delivery")
	Port := _RTP_NewPort()
	try {
		Record := _RTP_Pending(Bundle, Port, 0, 0, _RTP_Record.Bind("abort"),
			_RTP_Record.Bind("refused"), _RTP_Record.Bind("release"))
		Port["probe"]["alive"] := false
		Port["probe"]["delivery_throw"] := true
		AssertTrue(ReloadTerminalHandoffRefuse(Record, "deferred UI delivery"))
		_RTP_RunArmed(Port)
		AssertEqual("launch,abort", _RTP_Join(_RTP_Events), "Arming failure never invokes caller UI synchronously.")
		AssertEqual(Record, _ReloadTerminalHandoff)
		AssertTrue(_ConfigWriteTerminalIsActive())
		AssertEqual(0, Port["probe"]["closed"])
		Port["probe"]["delivery_throw"] := false
		_RTP_RunArmed(Port)
		_RTP_RunArmed(Port)
		AssertEqual("launch,abort,refused,release", _RTP_Join(_RTP_Events))
		AssertEqual(1, Port["probe"]["closed"])
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: unavailable UI timer keeps bundle instead of inline callback", _RQS_DeferredDeliveryFailure)

_RQS_Resume(State, Record) {
	State.Calls += 1
	State.Record := Record
}

_RQS_OnlyAcknowledgedAbandonResumes() {
	Bundle := _RTP_Acquire("quiescence-resume")
	Port := _RTP_NewPort()
	State := {Calls: 0, Record: 0}
	try {
		Record := _RTP_Pending(Bundle, Port)
		AssertFalse(ReloadTerminalHandoffPrepareAbandon(Record, "Exit", _RQS_Resume.Bind(State)))
		_RTP_RunArmed(Port)
		AssertEqual(0, State.Calls, "A still-live successor cannot schedule the owned exit continuation.")
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		AssertEqual(0, State.Calls)
		_RTP_RunArmed(Port)
		AssertEqual(1, State.Calls)
		AssertEqual(Record, State.Record)
		AssertEqual("abandon_ready", Record["state"])
		AssertTrue(Record["stop_acknowledged"])
		AssertTrue(ReloadTerminalHandoffAbandon(Record, "Exit"))
	} finally _RTP_Cleanup(Bundle)
}
Test("reload quiescence: owned exit continuation waits for actual stop acknowledgement", _RQS_OnlyAcknowledgedAbandonResumes)

_RQS_SourceString(Value) {
	return Chr(34) . StrReplace(StrReplace(Value, Chr(96), Chr(96) . Chr(96)),
		Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_RQS_BudgetDone(State, ExitCode, Stdout, Stderr) {
	State.ExitCode := ExitCode
	State.Stdout := Stdout
	State.Stderr := Stderr
	State.Done := true
	if State.TimedOut {
		try _RQS_BudgetRetireFiles(State)
		catch as Err
			State.CleanupFailure := Err
	}
}

_RQS_BudgetRetireFiles(State) {
	global _RQS_BudgetChildren
	if !State.Done
		return false
	for Path in [State.ChildPath, State.ReceiptPath] {
		if FileExist(Path)
			FileDelete(Path)
	}
	if _RQS_BudgetChildren.Get(State.ChildPath, 0) == State
		_RQS_BudgetChildren.Delete(State.ChildPath)
	return true
}

_RQS_ExhaustedBudget(Mode) {
	global _RQS_BudgetChildren
	static Serial := 0
	Serial += 1
	SplitPath(A_LineFile, , &UnitDir)
	Template := FileRead(UnitDir . "/../support/reload_shutdown_budget.template.ahk", "UTF-8")
	Bodies := ""
	for Name in ["LifecycleShutdownVetoHonored", "_LifecycleRefuseShutdown", "_LifecycleRefuseNativeRetirement"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "The actual lifecycle admission function must be source-visible: " . Name)
		Bodies .= Body . "`n"
	}
	ChildPath := A_Temp . "/ergopti-reload-budget-" . DllCall("GetCurrentProcessId") . "-" . Serial . ".ahk"
	ReceiptPath := ChildPath . ".receipt"
	Probe := StrReplace(Template, "@@LEASE@@", UnitDir . "/../../infra/config_write_lease.ahk")
	Probe := StrReplace(Probe, "@@HANDOFF@@", UnitDir . "/../../infra/reload_terminal_handoff.ahk")
	Probe := StrReplace(Probe, "@@BODY@@", Bodies)
	Probe := StrReplace(Probe, "@@MODE@@", _RQS_SourceString(Mode))
	Probe := StrReplace(Probe, "@@RECEIPT@@", _RQS_SourceString(ReceiptPath))
	State := {ChildPath: ChildPath, ReceiptPath: ReceiptPath, Task: 0,
		Done: false, TimedOut: false, StopRequested: false, ExitCode: -1, Stdout: "", Stderr: "",
		FirstFailure: 0, CleanupFailure: 0}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteDurable(ChildPath, Chr(0xFEFF) . Probe))
		State.Task := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", ChildPath],
			_RQS_BudgetDone.Bind(State))
		_RQS_BudgetChildren[ChildPath] := State
		AssertTrue(State.Task.start(), "The child must acquire its actual tree owner.")
		Started := A_TickCount
		while !State.Done {
			if TickExpired(Started, 5000) {
				State.TimedOut := true
				State.StopRequested := true
				State.FirstFailure := Error("The exact budget child exceeded its bound; native retirement remains owned until actual completion.")
				; A deadline marks failure and requests exact retirement; it never
				; releases a live native owner or turns later completion into a pass.
				try State.Task.requestTerminate()
				catch as Err
					State.CleanupFailure := Err
				throw State.FirstFailure
			}
			Sleep(10)
		}
		Diagnostic := FileExist(ReceiptPath) ? FSReadUtf8Exact(ReceiptPath) : "missing child receipt"
		AssertFalse(State.TimedOut)
		AssertEqual(0, State.ExitCode, "The exact lifecycle child failed: " . Diagnostic
			. "`nstdout=" . State.Stdout . "`nstderr=" . State.Stderr)
		AssertEqual("", State.Stdout, "A healthy actual child must not emit warnings or diagnostics on stdout. Actual captured stdout="
			. State.Stdout . "`nstderr=" . State.Stderr . "`nreceipt=" . Diagnostic)
		AssertEqual("", State.Stderr, "A healthy actual child must not emit warnings or diagnostics on stderr. Actual captured stderr="
			. State.Stderr . "`nstdout=" . State.Stdout . "`nreceipt=" . Diagnostic)
		AssertEqual("qualified", FSReadUtf8Exact(ReceiptPath))
	} catch as Err {
		if !(State.FirstFailure is Error)
			State.FirstFailure := Err
	} finally {
		try {
			if State.Done
				_RQS_BudgetRetireFiles(State)
			else if State.Task is Object {
				State.TimedOut := true
				if !State.StopRequested {
					State.StopRequested := true
					State.Task.requestTerminate()
				}
			} else {
				; No acquisition happened; these are still parent-owned artifacts.
				State.Done := true
				_RQS_BudgetRetireFiles(State)
			}
		} catch as Err {
			State.CleanupFailure := Err
		} finally Critical(PreviousCritical)
	}
	if State.FirstFailure is Error
		throw State.FirstFailure
	if State.CleanupFailure is Error
		throw State.CleanupFailure
}
Test("reload quiescence: exhausted earlier READV4 veto preserves pending child", _RQS_ExhaustedBudget.Bind("pending-read"))
Test("reload quiescence: repeated exhausted Exit preserves live stop polls", _RQS_ExhaustedBudget.Bind("timeout"))
Test("reload quiescence: exhausted Exit preserves failed stop debt", _RQS_ExhaustedBudget.Bind("false"))
Test("reload quiescence: exhausted Exit preserves throwing stop debt", _RQS_ExhaustedBudget.Bind("throw"))
Test("reload quiescence: exhausted launch reentry preserves acquisition reservation", _RQS_ExhaustedBudget.Bind("launching"))
