; tests/unit/modules/gestures/test_system_actions_confirmed_targets.ahk

; ==============================================================================
; MODULE: System Actions Confirmed Targets
; DESCRIPTION:
; SystemControl probes, pause boundaries of deferred and confirmed actions,
; and the confirmed target owner: the original window, UWP PID and native
; queries cannot be retargeted between the question and the effect.
; ==============================================================================

#Requires AutoHotkey v2.0





_SysActions_ControlProbes() {
	Adapter := SystemControl()
	AssertTrue(Adapter.CurrentUserKeyExists("Software"), "HKEY_CURRENT_USER\Software exists")
	AssertFalse(Adapter.CurrentUserKeyExists("Software\ErgoptiTests\Absent_" . A_TickCount),
		"an absent key is reported absent, not as a failure")
	AssertTrue(_TouchpadRegistryKeyExists("HKEY_CURRENT_USER\Software"),
		"the touchpad owner probes its key through the adapter")
	AssertThrows(() => _TouchpadRegistryKeyExists("HKEY_LOCAL_MACHINE\Software"),
		"the touchpad owner refuses a key outside HKEY_CURRENT_USER")
	Expected := 0
	AssertTrue(DllCall("ProcessIdToSessionId", "UInt", DllCall("GetCurrentProcessId", "UInt"),
		"UInt*", &Expected), "the test must know its session")
	AssertEqual(Expected, Adapter.SessionId(), "the script's own session")
}
Test("system actions: SystemControl probes a registry key and names the session", _SysActions_ControlProbes)

_SysActions_PauseReceipt(Replay, Fragment) {
	global _LOGGER_INFO_ENABLED
	PriorPause := A_IsSuspended
	PriorInfo := _LOGGER_INFO_ENABLED
	Entries := []
	_LOGGER_INFO_ENABLED := true
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		Suspend(true)
		Replay.Call()
	} finally {
		Suspend(PriorPause)
		LoggerClearTestSink()
		_LOGGER_INFO_ENABLED := PriorInfo
	}
	Found := 0
	for Entry in Entries {
		if InStr(Entry, Fragment)
			Found += 1
	}
	return Found
}

_SysActions_PausedDeferredDispatch() {
	Fake := _SysActionsFake()
	Runner := _GestureMakeSystemRunner("clear_clipboard", GestureSysClearClipboard.Bind(Fake), Fake)
	Runner.Call()
	Receipts := _SysActions_PauseReceipt(Fake.Deferred[1], "cancelled before its deferred execution")
	AssertEqual(0, _SysActions_CallsNamed(Fake, "ClearClipboard").Length,
		"a callback admitted before pause cannot clear the clipboard while paused")
	AssertEqual(1, Receipts, "the deferred action cancellation is logged once")
}
Test("system actions: deferred clipboard action cancels during pause (system-action-pause-boundaries)",
	_SysActions_PausedDeferredDispatch)

_SysActions_PausedDelayedSleep() {
	Fake := _SysActionsFake()
	GestureSysSleepDisplays(Fake)
	Receipts := _SysActions_PauseReceipt(Fake.Deferred[1], "Display sleep was cancelled")
	AssertEqual(0, _SysActions_CallsNamed(Fake, "PostBroadcast").Length,
		"the second display timer must not power monitors off after pause")
	AssertEqual(1, Receipts, "the delayed display cancellation is logged once")
}
Test("system actions: delayed display sleep cancels during pause (system-action-pause-boundaries)",
	_SysActions_PausedDelayedSleep)

_SysActions_PausedConfirmationAdmission() {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	GestureInvokeAction("force_quit_frontmost", "keyboard__pause_probe", Fake)
	Receipts := _SysActions_PauseReceipt(Fake.Deferred[1], "cancelled before its confirmation")
	AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length,
		"a queued confirmation must not open a dialog after pause")
	AssertEqual(1, Receipts, "the confirmation cancellation is logged once")
}
Test("system actions: deferred confirmation cancels before Ask during pause (system-action-pause-boundaries)",
	_SysActions_PausedConfirmationAdmission)

class _SysActions_PausingFocus extends _SysActionsFake {
	Activate(Hwnd) {
		this._Log("Activate", Hwnd)
		Suspend(true)
		return true
	}
}

_SysActions_PausedDuringFocusRestore() {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS["force_quit_frontmost"]
	Ran := []
	Fake := _SysActions_PausingFocus()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: () => Ran.Push("ran") }
	PriorPause := A_IsSuspended
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__pause_probe", Fake)
		Fake.Deferred[1].Call()
		AssertEqual(0, Ran.Length, "a pause during activation cannot dispatch a confirmed extension")
	} finally {
		Suspend(PriorPause)
		GESTURE_ACTIONS["force_quit_frontmost"] := Saved
	}
}
Test("system actions: confirmation rechecks pause after focus restoration (system-action-pause-boundaries)",
	_SysActions_PausedDuringFocusRestore)
; All actual process effects stay inside the existing recording adapter.
_SysActions_InstallOwnedForce(Fake) {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS["force_quit_frontmost"]
	Entry := { Fn: _GestureMakeSystemRunner("force_quit_frontmost", GestureSysForceQuitFrontmost.Bind(Fake), Fake) }
	if Saved.HasOwnProp("ConfirmedFn")
		Entry.ConfirmedFn := Saved.ConfirmedFn
	GESTURE_ACTIONS["force_quit_frontmost"] := Entry
	return Saved
}

_SysActions_TargetCase(Race) {
	global GESTURE_ACTIONS, GESTURE_SYS_APP_FRAME_CLASS
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	if Race == "missing"
		Fake.Active := ""
	else if Race == "own"
		Fake.Active.Pid := Fake.OwnPidValue
	else if Race == "shell"
		Fake.Active.Class := "Shell_TrayWnd"
	else if Race == "shared"
		Fake.ShellPidValue := 812
	else if Race == "uwp" || Race == "uwp_changed" || Race == "uwp_missing" {
		Fake.Active.Class := GESTURE_SYS_APP_FRAME_CLASS
		Fake.FramedApp := Race == "uwp_missing" ? 0 : 7001
	}
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		if Race == "missing" || Race == "own" || Race == "shell" || Race == "shared" || Race == "uwp_missing" {
			AssertEqual(0, Fake.Deferred.Length, Race . ": no destructive question is admitted")
			return
		}
		if Race == "question_absent"
			(Fake.Snapshots.Delete(0x100), Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "Notepad" })
		else if Race == "question_pid" || Race == "question_class"
			Fake.Active := Fake.Snapshots[0x100] := { Hwnd: 0x100, Pid: Race == "question_pid" ? 913 : 812,
				Class: Race == "question_class" ? "OtherWindow" : "Notepad" }
		Fake.Deferred.RemoveAt(1).Call()
		if InStr(Race, "question_") == 1 {
			AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length, Race . ": stale source cannot open a question")
			AssertEqual(0, Fake.Deferred.Length)
			return
		}
		AssertEqual(1, Fake.Deferred.Length, "the actual registered runner retains its second deferral")
		if Race == "foreground"
			Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "Notepad" }
		else if Race == "effect_absent"
			(Fake.Snapshots.Delete(0x100), Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "Notepad" })
		else if Race == "effect_pid" || Race == "effect_class"
			Fake.Active := Fake.Snapshots[0x100] := { Hwnd: 0x100, Pid: Race == "effect_pid" ? 913 : 812,
				Class: Race == "effect_class" ? "OtherWindow" : "Notepad" }
		else if Race == "uwp_changed"
			Fake.FramedApp := 7002
		Fake.Deferred.RemoveAt(1).Call()
		Killed := _SysActions_CallsNamed(Fake, "CloseProcess")
		Refused := InStr(Race, "effect_") == 1 || Race == "uwp_changed"
		AssertEqual(Refused ? 0 : 1, Killed.Length, Race . ": only a currently owned source may be terminated")
		if !Refused
			AssertEqual(Race == "uwp" ? 7001 : 812, Killed[1][2], "the approved source PID is never replaced by the new foreground PID")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}

; A factory binds a function parameter, never the loop variable.
_SysActions_TargetTest(Race) => () => _SysActions_TargetCase(Race)
for _SysTargetCase in ["foreground", "missing", "question_absent", "question_pid", "question_class",
	"effect_absent", "effect_pid", "effect_class", "own", "shell", "shared", "uwp_missing", "uwp", "uwp_changed", "unchanged"]
	Test("system actions: native confirmed target " . _SysTargetCase . " (confirmed-target-owner)", _SysActions_TargetTest(_SysTargetCase))

class _SysActions_TargetChangingAsk extends _SysActionsFake {
	Ask(Text, Title) {
		this._Log("Ask", Text, Title)
		this.Snapshots[0x100] := { Hwnd: 0x100, Pid: 913, Class: "Notepad" }
		this.Active := this.Snapshots[0x100]
		return "OK"
	}
}

_SysActions_SourceChangesDuringQuestion() {
	global GESTURE_ACTIONS
	Fake := _SysActions_TargetChangingAsk()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(1, _SysActions_CallsNamed(Fake, "Ask").Length)
		AssertEqual(0, _SysActions_CallsNamed(Fake, "Activate").Length, "a replaced window is refused before activation")
		AssertEqual(0, Fake.Deferred.Length, "OK cannot authorize the replacement process")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
Test("system actions: original window changes during question (confirmed-target-owner)", _SysActions_SourceChangesDuringQuestion)

_SysActions_ConfirmedExtensionKeepsNoArguments() {
	global GESTURE_ACTIONS
	Saved := GESTURE_ACTIONS["force_quit_frontmost"]
	Ran := []
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: () => Ran.Push("zero_args") }
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(1, Ran.Length, "ordinary extensions retain strict zero-argument calls")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
Test("system actions: confirmed extension retains zero arguments (confirmed-target-owner)", _SysActions_ConfirmedExtensionKeepsNoArguments)

_SysActions_HiddenWindowSnapshot() {
	Adapter := SystemControl()
	Window := Gui()
	PriorHidden := A_DetectHiddenWindows
	try {
		DetectHiddenWindows(false)
		Snapshot := Adapter.WindowSnapshot(Window.Hwnd)
		AssertTrue(IsObject(Snapshot), "hidden owned window is captured without activation")
		AssertEqual(Window.Hwnd, Snapshot.Hwnd)
		AssertEqual(Adapter.OwnPid(), Snapshot.Pid)
		AssertEqual("AutoHotkeyGUI", Snapshot.Class)
		AssertFalse(A_DetectHiddenWindows, "the native read restores its caller's policy")
		Hwnd := Window.Hwnd
		Window.Destroy()
		AssertEqual("", Adapter.WindowSnapshot(Hwnd), "destroyed HWND has no source receipt")
		AssertFalse(A_DetectHiddenWindows)
	} finally {
		DetectHiddenWindows(PriorHidden)
		try Window.Destroy()
	}
}
Test("system actions: hidden native source capture is read only (confirmed-target-owner)", _SysActions_HiddenWindowSnapshot)

class _SysActions_SourceChangingFocus extends _SysActionsFake {
	Activate(Hwnd) {
		this._Log("Activate", Hwnd)
		this.Active := this.Snapshots[Hwnd] := { Hwnd: Hwnd, Pid: 913, Class: "Notepad" }
		return true
	}
}

_SysActions_SourceChangesDuringFocus() {
	global GESTURE_ACTIONS
	Fake := _SysActions_SourceChangingFocus()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	Fake.Answer := "OK"
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		AssertEqual(1, _SysActions_CallsNamed(Fake, "Activate").Length)
		AssertEqual(0, Fake.Deferred.Length, "activation cannot replace the approved source receipt")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
Test("system actions: original source changes during focus restoration (confirmed-target-owner)", _SysActions_SourceChangesDuringFocus)

_SysActions_ConfirmedExplorerKeepsSource() {
	global GESTURE_ACTIONS
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "CabinetWClass" }
	Fake.Answer := "OK"
	Fake.Shell := _SysActions_Shell(0x100, "C:\original", ["C:\original\\approved.txt"])
	Saved := GESTURE_ACTIONS["unblock_file_selection"]
	Entry := { Fn: _GestureMakeSystemRunner("unblock_file_selection", GestureSysUnblockFileSelection.Bind(Fake), Fake) }
	if Saved.HasOwnProp("ConfirmedFn")
		Entry.ConfirmedFn := Saved.ConfirmedFn
	GESTURE_ACTIONS["unblock_file_selection"] := Entry
	try {
		GestureInvokeAction("unblock_file_selection", "keyboard__target_probe", Fake)
		Fake.Deferred.RemoveAt(1).Call()
		Fake.Active := { Hwnd: 0x200, Pid: 913, Class: "CabinetWClass" }
		Fake.Deferred.RemoveAt(1).Call()
		Deleted := _SysActions_CallsNamed(Fake, "DeleteZoneIdentifier")
		AssertEqual(1, Deleted.Length, "the explicit approved Explorer window remains the selection owner")
		AssertEqual("C:\original\\approved.txt", Deleted[1][2])
	} finally GESTURE_ACTIONS["unblock_file_selection"] := Saved
}
Test("system actions: confirmed Explorer mutation retains its original window (confirmed-target-owner)", _SysActions_ConfirmedExplorerKeepsSource)


class _SysActions_AlternatingFrame extends _SysActionsFake {
	FramedAppPid(FrameHwnd) {
		this._Log("FramedAppPid", FrameHwnd)
		return this.FrameReads.RemoveAt(1)
	}
}

_SysActions_ApprovedUwpPidCannotChange() {
	Fake := _SysActions_AlternatingFrame()
	Fake.FrameReads := [7001, 7002, 7001]
	Target := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow", TargetPid: 7001 }
	if Target.HasOwnProp("TargetPid")
		Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	GestureSysForceQuitFrontmost(Fake, Target)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length,
		"a transiently resolved replacement PID cannot become approved effect authority")
}
Test("system actions: UWP approved PID refuses transient retarget (confirmed-target-review)", _SysActions_ApprovedUwpPidCannotChange)

_SysActions_MissingApprovedUwpPidRefuses() {
	Fake := _SysActionsFake()
	Fake.FramedApp := 7001
	Target := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow" }
	if Target.HasOwnProp("TargetPid")
		Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	GestureSysForceQuitFrontmost(Fake, Target)
	AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length,
		"a confirmed receipt without its approved process cannot authorize a fresh process")
}
Test("system actions: confirmed UWP requires approved PID (confirmed-target-review)", _SysActions_MissingApprovedUwpPidRefuses)

class _SysActions_ThrowingNativeQuery extends _SysActionsFake {
	FramedAppPid(FrameHwnd) {
		if this.ThrowQuery && this.Query == "frame"
			throw TargetError("injected native frame disappearance")
		return 7001
	}
	WindowSnapshot(Hwnd) {
		if this.ThrowQuery && this.Query == "window"
			throw TargetError("injected native window disappearance")
		return super.WindowSnapshot(Hwnd)
	}
}

_SysActions_NativeQueryFailureIsContained(Phase, Query) {
	global GESTURE_ACTIONS
	Fake := _SysActions_ThrowingNativeQuery()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow" }
	Fake.Answer := "OK"
	Fake.Query := Query
	Fake.ThrowQuery := Phase == "preflight"
	Saved := _SysActions_InstallOwnedForce(Fake)
	Entries := []
	Threw := false
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		try {
			GestureInvokeAction("force_quit_frontmost", "keyboard__target_probe", Fake)
			if Phase == "callback" {
				Fake.ThrowQuery := true
				Fake.Deferred.RemoveAt(1).Call()
			}
		} catch {
			Threw := true
		}
		AssertEqual(false, Threw, "native target queries remain inside their owning dispatch boundary")
		AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length, "failed ownership cannot ask a destructive question")
		AssertEqual(0, _SysActions_CallsNamed(Fake, "CloseProcess").Length)
		AssertEqual(0, Fake.Deferred.Length, "query failure schedules no later effect")
		Errors := 0
		for Entry in Entries {
			if InStr(Entry, "failed during confirmation " . Phase) && InStr(Entry, "injected native")
				Errors += 1
		}
		AssertEqual(1, Errors, "the original native query failure has exactly one contained diagnostic")
	} finally {
		LoggerClearTestSink()
		GESTURE_ACTIONS["force_quit_frontmost"] := Saved
	}
}

_SysActions_NativeQueryTest(Phase, Query) => () => _SysActions_NativeQueryFailureIsContained(Phase, Query)
for _SysQueryPhase in ["preflight", "callback"] {
	for _SysQueryKind in ["frame", "window"]
		Test("system actions: native query " . _SysQueryPhase . " " . _SysQueryKind . " is contained (confirmed-target-review)",
			_SysActions_NativeQueryTest(_SysQueryPhase, _SysQueryKind))
}


_SysActions_ApprovedUwpStillRuns() {
	Fake := _SysActions_AlternatingFrame()
	Fake.FrameReads := [7001, 7001, 7001]
	Target := { Hwnd: 0x100, Pid: 812, Class: "ApplicationFrameWindow", TargetPid: 7001 }
	if Target.HasOwnProp("TargetPid")
		Target.ProcessLease := Fake.AcquireProcessTarget(Target.TargetPid)
	Fake.Snapshots[0x100] := Target.Clone()
	GestureSysForceQuitFrontmost(Fake, Target)
	Killed := _SysActions_CallsNamed(Fake, "CloseProcess")
	AssertEqual(1, Killed.Length, "an unchanged approved UWP source runs exactly once")
	AssertEqual(7001, Killed[1][2], "the captured approved app PID reaches the effect")
}
Test("system actions: unchanged approved UWP remains executable (confirmed-target-review)", _SysActions_ApprovedUwpStillRuns)

_SysActions_DirectLegacyForceStillRuns() {
	Fake := _SysActionsFake()
	Fake.Active := { Hwnd: 0x100, Pid: 812, Class: "Notepad" }
	GestureSysForceQuitFrontmost(Fake)
	Killed := _SysActions_CallsNamed(Fake, "CloseProcess")
	AssertEqual(1, Killed.Length, "the direct unconfirmed adapter API remains available")
	AssertEqual(812, Killed[1][2], "direct legacy execution uses its current source PID")
}
Test("system actions: direct legacy force API keeps its contract (confirmed-target-review)", _SysActions_DirectLegacyForceStillRuns)
