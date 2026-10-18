; tests/unit/modules/gestures/test_system_actions_process_lease.ahk

; ==============================================================================
; MODULE: System Actions Process Lease and Direct Force
; DESCRIPTION:
; A retained UWP process lease refuses fresh authority and releases exactly
; once, direct force and selection actions honour a pause, and the process
; PID domain refuses invalid values.
; ==============================================================================

#Requires AutoHotkey v2.0





; The native process port has handle authority; the numeric PID registry can
; change independently while a confirmation or one of its timers is waiting.
class _SysActions_ProcessLeaseFake extends _SysActionsFake {
	__New(Mode, Uwp := false) {
		super.__New()
		this.Mode := Mode
		this.Active := { Hwnd: 0x100, Pid: Uwp ? 812 : 7001,
			Class: Uwp ? "ApplicationFrameWindow" : "Notepad" }
		this.FramedApp := 7001
		this.Answer := "OK"
		this.Instance := "approved-A"
		this.Leases := []
		this.Effects := []
		this.Releases := 0
		this.DeferCount := 0
		this.ExtensionCalls := 0
	}
	Retire() {
		this.Instance := "replacement-B"
		for Lease in this.Leases
			Lease.Alive := false
	}
	AcquireProcessTarget(Pid) {
		if this.Mode == "acquire_error"
			throw Error("injected process acquisition failure")
		if this.Mode == "acquire_window_change" {
			this.Instance := "replacement-B"
			this.Snapshots[this.Active.Hwnd] := { Hwnd: this.Active.Hwnd, Pid: 8002, Class: this.Active.Class }
		}
		Lease := { Pid: Pid, Handle: 1, Instance: this.Instance, Alive: true }
		this.Leases.Push(Lease)
		if this.Mode == "acquire_exit"
			this.Retire()
		return Lease
	}
	ProcessTargetIsLive(Lease) {
		if this.Mode == "query_error"
			throw Error("injected retained process query failure")
		return Lease.Handle != 0 && Lease.Alive
	}
	CloseProcess(Pid) {
		if this.Mode == "effect_replacement"
			this.Retire()
		this.Effects.Push({ Pid: Pid, Instance: this.Instance })
		return true
	}
	TerminateProcessTarget(Lease) {
		if this.Mode == "effect_replacement"
			this.Retire()
		if this.Mode == "effect_error"
			throw Error("injected retained process effect failure")
		if this.Mode == "effect_refused"
			return false
		if !Lease.Handle || !Lease.Alive
			return false
		this.Effects.Push({ Pid: Lease.Pid, Instance: Lease.Instance })
		return true
	}
	ReleaseProcessTarget(Lease) {
		if !Lease.Handle
			throw Error("process lease released twice")
		Lease.Handle := 0
		this.Releases += 1
		if this.Mode == "release_error"
			throw Error("injected process release failure")
		if this.Mode == "release_reentry"
			_GestureReleaseProcessTarget(this.CapturedTarget, this)
	}
	Ask(Text, Title) {
		this._Log("Ask", Text, Title)
		this.ApprovalLeaseCount := this.Leases.Length
		if this.Mode == "question_replacement"
			this.Retire()
		if this.Mode == "question_pause"
			Suspend(true)
		if this.Mode == "question_error"
			throw Error("injected process confirmation failure")
		return this.Mode == "cancel" ? "Cancel" : "OK"
	}
	Activate(Hwnd) {
		if this.Mode == "activation_refused"
			return false
		return super.Activate(Hwnd)
	}
	Defer(Fn, Delay := 1) {
		this.DeferCount += 1
		if this.Mode == "first_defer_error" || (this.Mode == "second_defer_error" && this.DeferCount == 2)
			throw Error("injected process scheduling failure")
		if this.Mode == "defer_reentry"
			return Fn.Call()
		return super.Defer(Fn, Delay)
	}
}

_SysActions_ProcessLeaseCase(Mode, Uwp := false) {
	global GESTURE_ACTIONS
	Fake := _SysActions_ProcessLeaseFake(Mode, Uwp)
	Saved := _SysActions_InstallOwnedForce(Fake)
	PriorPause := A_IsSuspended
	Entries := []
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		Suspend(false)
		if Mode == "extension"
			GESTURE_ACTIONS["force_quit_frontmost"] := { Fn: () => Fake.ExtensionCalls += 1 }
		GestureInvokeAction("force_quit_frontmost", "keyboard__process_lease", Fake)
		if Mode == "pre_question_replacement"
			Fake.Retire()
		while Fake.Deferred.Length {
			if Fake.DeferCount == 2 {
				if Mode == "second_timer_replacement"
					Fake.Retire()
				if Mode == "second_timer_pause"
					Suspend(true)
			}
			Fake.Deferred.RemoveAt(1).Call()
		}
		for Effect in Fake.Effects
			AssertEqual("approved-A", Effect.Instance,
				"confirmation cannot authorize a replacement process that reused the approved PID")
		ExpectedEffects := Mode == "unchanged" || Mode == "defer_reentry" || Mode == "release_error" ? 1 : 0
		AssertEqual(ExpectedEffects, Fake.Effects.Length, "only the originally admitted process can receive the effect")
		ExpectedLeases := Mode == "acquire_error" ? 0 : 1
		AssertEqual(ExpectedLeases, Fake.Leases.Length, "acquire one process capability before the question")
		AssertEqual(ExpectedLeases, Fake.Releases, "every terminal path releases the retained process exactly once")
		for Lease in Fake.Leases
			AssertEqual(0, Lease.Handle, "released capabilities cannot be used by later callbacks")
		if Fake.HasOwnProp("ApprovalLeaseCount")
			AssertEqual(1, Fake.ApprovalLeaseCount, "the native capability is acquired before destructive approval")
		if Mode == "acquire_window_change" || Mode == "acquire_exit"
			AssertEqual(0, _SysActions_CallsNamed(Fake, "Ask").Length,
				"an acquisition that lost its original window or process never opens confirmation")
		if Mode == "extension"
			AssertEqual(1, Fake.ExtensionCalls, "a synchronous extension retains its exact zero-argument contract")
		if InStr(Mode, "error") {
			Diagnostics := 0
			for Entry in Entries
				if InStr(Entry, "injected process") || InStr(Entry, "injected retained")
					Diagnostics += 1
			AssertEqual(1, Diagnostics, "the native failure is contained and reported exactly once")
		}
	} finally {
		Suspend(PriorPause)
		LoggerClearTestSink()
		GESTURE_ACTIONS["force_quit_frontmost"] := Saved
	}
}
_SysActions_ProcessLeaseTest(Mode, Uwp) => () => _SysActions_ProcessLeaseCase(Mode, Uwp)
for _SysActions_ProcessLeaseMode in ["effect_replacement", "question_replacement", "pre_question_replacement",
	"second_timer_replacement", "unchanged", "cancel", "question_pause", "second_timer_pause",
	"question_error", "acquire_error", "acquire_exit", "acquire_window_change", "query_error", "first_defer_error",
	"second_defer_error", "activation_refused", "effect_error", "effect_refused", "release_error",
	"defer_reentry", "extension"] {
	Test("system actions: retained process " . _SysActions_ProcessLeaseMode . " (confirmed-process-lease)",
		_SysActions_ProcessLeaseTest(_SysActions_ProcessLeaseMode, false))
}
for _SysActions_ProcessLeaseMode in ["effect_replacement", "question_replacement", "second_timer_replacement", "unchanged"]
	Test("system actions: retained UWP process " . _SysActions_ProcessLeaseMode . " (confirmed-process-lease)",
		_SysActions_ProcessLeaseTest(_SysActions_ProcessLeaseMode, true))

_SysActions_BareConfirmedProcessRefuses() {
	Fake := _SysActions_ProcessLeaseFake("unchanged")
	Target := { Hwnd: 0x100, Pid: 7001, Class: "Notepad", TargetPid: 7001 }
	Fake.Snapshots[Target.Hwnd] := Target.Clone()
	Entries := []
	LoggerSetTestSink((Entry) => Entries.Push(Entry))
	try {
		GestureSysForceQuitFrontmost(Fake, Target)
		AssertEqual(0, Fake.Effects.Length, "a bare confirmed PID never authorizes a newly opened process")
		AssertEqual(0, Fake.Leases.Length, "incomplete approval cannot acquire replacement authority")
		Diagnostics := 0
		for Entry in Entries
			if InStr(Entry, "already-owned process lease")
				Diagnostics += 1
		AssertEqual(1, Diagnostics, "an incomplete confirmed receipt has an explicit ownership diagnostic")
	} finally LoggerClearTestSink()
}
Test("system actions: bare confirmed process refuses fresh authority (confirmed-process-lease)",
	_SysActions_BareConfirmedProcessRefuses)

_SysActions_ProcessReleaseReentry() {
	Fake := _SysActions_ProcessLeaseFake("release_reentry")
	Target := { Hwnd: 0x100, Pid: 7001, Class: "Notepad", TargetPid: 7001,
		ProcessLease: Fake.AcquireProcessTarget(7001) }
	Fake.CapturedTarget := Target
	_GestureReleaseProcessTarget(Target, Fake)
	_GestureReleaseProcessTarget(Target, Fake)
	AssertEqual(1, Fake.Releases, "reentrant cancellation claims the native cleanup debt only once")
}
Test("system actions: process release reentry is exactly once (confirmed-process-lease)",
	_SysActions_ProcessReleaseReentry)

_SysActions_InvalidApprovedLease(Released) {
	Fake := _SysActions_ProcessLeaseFake("unchanged")
	Lease := Fake.AcquireProcessTarget(Released ? 7001 : 9000)
	if Released
		Fake.ReleaseProcessTarget(Lease)
	Target := { Hwnd: 0x100, Pid: 7001, Class: "Notepad", TargetPid: 7001, ProcessLease: Lease }
	Fake.Snapshots[Target.Hwnd] := Target.Clone()
	try {
		GestureSysForceQuitFrontmost(Fake, Target)
		AssertEqual(0, Fake.Effects.Length, "a released or mismatched process capability cannot authorize an effect")
		AssertEqual(1, Fake.Leases.Length, "invalid approval cannot acquire a new capability")
	} finally {
		if Lease.Handle
			Fake.ReleaseProcessTarget(Lease)
	}
}
Test("system actions: invalid approved lease is already released (confirmed-process-lease)",
	() => _SysActions_InvalidApprovedLease(true))
Test("system actions: invalid approved lease belongs to another PID (confirmed-process-lease)",
	() => _SysActions_InvalidApprovedLease(false))

_SysActions_ResolvedGuard(TargetPid, Mode) {
	global GESTURE_ACTIONS
	Fake := _SysActions_ProcessLeaseFake("unchanged", true)
	Fake.ShellPidValue := 6000
	Fake.FramedApp := TargetPid
	Protected := TargetPid == Fake.OwnPidValue || TargetPid == Fake.ShellPidValue
	if Mode == "resolver" {
		Resolved := GestureSysForceQuitTarget(Fake.Active, Fake)
		AssertEqual(Protected, Resolved.Refusal != "", "the resolved app PID obeys the same self and shell refusal as its frame")
		AssertEqual(Protected ? 0 : TargetPid, Resolved.Pid, "a refused resolved process has no effect authority")
		return
	}
	Saved := _SysActions_InstallOwnedForce(Fake)
	try {
		if Mode == "confirmed" {
			GestureInvokeAction("force_quit_frontmost", "keyboard__resolved_guard", Fake)
			while Fake.Deferred.Length
				Fake.Deferred.RemoveAt(1).Call()
			AssertEqual(Protected ? 0 : 1, _SysActions_CallsNamed(Fake, "Ask").Length,
				"a resolved protected process is refused before destructive confirmation")
		} else {
			GestureSysForceQuitFrontmost(Fake)
		}
		AssertEqual(Protected ? 0 : 1, Fake.Effects.Length, "neither confirmed nor direct execution can terminate a resolved self or shell PID")
		AssertEqual(Protected ? 0 : 1, Fake.Leases.Length, "a protected child process never acquires termination authority")
		AssertEqual(Fake.Leases.Length, Fake.Releases, "the accepted UWP capability still releases exactly once")
	} finally GESTURE_ACTIONS["force_quit_frontmost"] := Saved
}
_SysActions_ResolvedGuardTest(Pid, Mode) => () => _SysActions_ResolvedGuard(Pid, Mode)
for _SysActions_ResolvedGuardMode in ["resolver", "confirmed", "direct"] {
	for _SysActions_ResolvedGuardPid in [4000, 6000, 7001]
		Test("system actions: resolved process " . _SysActions_ResolvedGuardMode . " " . _SysActions_ResolvedGuardPid . " (resolved-process-guards)",
			_SysActions_ResolvedGuardTest(_SysActions_ResolvedGuardPid, _SysActions_ResolvedGuardMode))
}

class _SysActions_DirectForcePause extends _SysActions_ProcessLeaseFake {
	__New(At, Pauses) {
		super.__New("unchanged")
		this.At := At
		this.Pauses := Pauses
		this.TerminationAttempts := 0
	}
	PauseAt(Phase) {
		if this.Pauses && this.At == Phase
			Suspend(true)
	}
	ShellPid() {
		Pid := super.ShellPid()
		this.PauseAt("shell")
		return Pid
	}
	AcquireProcessTarget(Pid) {
		Lease := super.AcquireProcessTarget(Pid)
		this.PauseAt("acquire")
		return Lease
	}
	ProcessTargetIsLive(Lease) {
		Alive := super.ProcessTargetIsLive(Lease)
		this.PauseAt("alive")
		return Alive
	}
	TerminateProcessTarget(Lease) {
		this.TerminationAttempts += 1
		return super.TerminateProcessTarget(Lease)
	}
	ReleaseProcessTarget(Lease) {
		super.ReleaseProcessTarget(Lease)
		this.PauseAt("release")
	}
}
_SysActions_DirectForcePauseCase(At, Pauses) {
	Fake := _SysActions_DirectForcePause(At, Pauses)
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		_GestureMakeSystemRunner("force_quit_frontmost", GestureSysForceQuitFrontmost.Bind(Fake), Fake).Call()
		if Pauses && At == "entry"
			Suspend(true)
		Fake.Deferred.RemoveAt(1).Call()
		Expected := Pauses && At != "release" ? 0 : 1
		AssertEqual(Expected, Fake.TerminationAttempts, "a direct runner cannot enter termination after a native query suspended the driver")
		AssertEqual(Expected, Fake.Effects.Length, "only an unpaused effect admission can terminate its retained target")
		ExpectedLeases := Pauses && At == "entry" ? 0 : 1
		AssertEqual(ExpectedLeases, Fake.Leases.Length, "the original deferred admission still refuses pause before acquisition")
		AssertEqual(ExpectedLeases, Fake.Releases, "an acquired direct capability always releases, including during pause")
		for Lease in Fake.Leases
			AssertEqual(0, Lease.Handle, "cancelled direct work leaves no retained native resource")
	} finally Suspend(PriorPause)
}
_SysActions_DirectForcePauseTest(At, Pauses) => () => _SysActions_DirectForcePauseCase(At, Pauses)
for _SysActions_DirectForcePhase in ["shell", "acquire", "alive"] {
	Test("system actions: direct force pause after " . _SysActions_DirectForcePhase . " (direct-force-query-pause)",
		_SysActions_DirectForcePauseTest(_SysActions_DirectForcePhase, true))
	Test("system actions: direct force unchanged " . _SysActions_DirectForcePhase . " (direct-force-query-pause)",
		_SysActions_DirectForcePauseTest(_SysActions_DirectForcePhase, false))
}
Test("system actions: direct force pause before deferred entry (direct-force-query-pause)",
	_SysActions_DirectForcePauseTest("entry", true))
Test("system actions: direct force release completes during pause (direct-force-query-pause)",
	_SysActions_DirectForcePauseTest("release", true))

class _SysActions_DirectSelectionPath {
	__New(Sys, Value) {
		this.Sys := Sys
		this.Value := Value
	}
	Path {
		get {
			this.Sys.PauseAt("path")
			return this.Value
		}
	}
}
class _SysActions_DirectSelectionDoc {
	__New(Sys) => this.Sys := Sys
	SelectedItems() {
		this.Sys.PauseAt("selection")
		return this.Sys.EmptySelection ? [] : [_SysActions_DirectSelectionPath(this.Sys, "C:\owned\a"), _SysActions_DirectSelectionPath(this.Sys, "C:\owned\b")]
	}
}
class _SysActions_DirectQueryFake extends _SysActionsFake {
	__New(Action, At, Pauses, EmptySelection := false) {
		super.__New()
		this.At := At
		this.Pauses := Pauses
		this.EmptySelection := EmptySelection
		this.Active := { Hwnd: 0x100, Pid: 812, Class: Action == "quit_frontmost_app" ? "Notepad" : "CabinetWClass" }
		this.Windows := [0x100, 0x101]
		if Action == "quit_frontmost_app" && At == "shell"
			this.ShellPidValue := 812
	}
	PauseAt(Phase) {
		if this.Pauses && this.At == Phase
			Suspend(true)
	}
	ActiveWindow() {
		Current := super.ActiveWindow()
		this.PauseAt("active")
		return Current
	}
	ShellApplication() {
		this.PauseAt("shell")
		return { Windows: (*) => [{ HWND: this.Active.Hwnd, Document: _SysActions_DirectSelectionDoc(this) }] }
	}
	IsDirectory(Path) {
		this.PauseAt("directory")
		return this.At == "files"
	}
	FilesUnder(Path) {
		this.PauseAt("files")
		return [Path . "\one", Path . "\two"]
	}
	DeleteZoneIdentifier(Path) {
		Result := super.DeleteZoneIdentifier(Path)
		this.PauseAt("deleted")
		return Result
	}
	ShellPid() {
		Pid := super.ShellPid()
		this.PauseAt("shell")
		return Pid
	}
	WindowsOfProcess(Pid) {
		Windows := super.WindowsOfProcess(Pid)
		this.PauseAt("windows")
		return Windows
	}
	PostClose(Hwnd) {
		Result := super.PostClose(Hwnd)
		this.PauseAt("closed")
		return Result
	}
}
_SysActions_DirectQueryCase(Action, At, Pauses, EmptySelection := false) {
	Fake := _SysActions_DirectQueryFake(Action, At, Pauses, EmptySelection)
	PriorPause := A_IsSuspended
	try {
		Suspend(false)
		Fn := Action == "quit_frontmost_app" ? GestureSysQuitFrontmostApp : GestureSysUnblockFileSelection
		_GestureMakeSystemRunner(Action, Fn.Bind(Fake), Fake).Call()
		Fake.Deferred.RemoveAt(1).Call()
		Effect := Action == "quit_frontmost_app" ? "PostClose" : "DeleteZoneIdentifier"
		Expected := EmptySelection ? 0 : (Pauses ? (At == "deleted" || At == "closed" ? 1 : 0) : (At == "shell" && Action == "quit_frontmost_app" ? 1 : (At == "files" ? 4 : 2)))
		AssertEqual(Expected, _SysActions_CallsNamed(Fake, Effect).Length,
			"every direct query boundary admits the next effect only while unpaused; committed earlier effects stay owned")
		AssertEqual(EmptySelection && !Pauses ? 1 : 0, _SysActions_CallsNamed(Fake, "Notify").Length,
			"a paused empty selection cannot publish a deferred notice")
	} finally Suspend(PriorPause)
}
_SysActions_DirectQueryTest(Action, At, Pauses, EmptySelection := false) => () => _SysActions_DirectQueryCase(Action, At, Pauses, EmptySelection)
for _SysActions_DirectSelectionPhase in ["active", "shell", "selection", "path", "directory", "files", "deleted"] {
	for _SysActions_DirectSelectionPauses in [true, false]
		Test("system actions: direct selection " . _SysActions_DirectSelectionPhase . " pause=" . _SysActions_DirectSelectionPauses . " (direct-selection-query-pause)",
			_SysActions_DirectQueryTest("unblock_file_selection", _SysActions_DirectSelectionPhase, _SysActions_DirectSelectionPauses))
}
for _SysActions_DirectSelectionPauses in [true, false]
	Test("system actions: direct empty selection pause=" . _SysActions_DirectSelectionPauses . " (direct-selection-query-pause)",
		_SysActions_DirectQueryTest("unblock_file_selection", "selection", _SysActions_DirectSelectionPauses, true))
for _SysActions_DirectQuitPhase in ["shell", "windows", "closed"] {
	for _SysActions_DirectQuitPauses in [true, false]
		Test("system actions: direct quit " . _SysActions_DirectQuitPhase . " pause=" . _SysActions_DirectQuitPauses . " (direct-quit-query-pause)",
			_SysActions_DirectQueryTest("quit_frontmost_app", _SysActions_DirectQuitPhase, _SysActions_DirectQuitPauses))
}

; A native DWORD must never truncate a supplied process target identifier.
; These probes only acquire, query and release this test process; they never terminate.
_SysActions_ProcessPidDomain(Pid, Valid := false) {
	Adapter := SystemControl()
	Lease := ""
	RejectedType := false
	try {
		try Lease := Adapter.AcquireProcessTarget(Pid)
		catch TypeError
			RejectedType := true
		catch OSError {
			; Native refusal is not the required input-domain refusal.
		}
		if !Valid {
			ObservedPid := IsObject(Lease) ? DllCall("Kernel32\GetProcessId", "Ptr", Lease.Handle, "UInt") : 0
			AssertTrue(RejectedType, "an invalid PID must be rejected before DWORD truncation or native access; requested="
				. Pid . " retained=" . ObservedPid)
			return
		}
		AssertTrue(IsObject(Lease), "a valid owned PID yields a retained native handle")
		if !IsObject(Lease)
			return
		AssertEqual(DllCall("Kernel32\GetProcessId", "Ptr", Lease.Handle, "UInt"), Pid,
			"the native process identity equals the admitted PID")
		AssertTrue(Adapter.ProcessTargetIsLive(Lease), "the owned test process is still live")
	} finally {
		if IsObject(Lease) {
			Adapter.ReleaseProcessTarget(Lease)
			Adapter.ReleaseProcessTarget(Lease)
			AssertEqual(Lease.Handle, 0, "the owned handle release debt is consumed exactly once")
		}
	}
}

for _SysActions_InvalidProcessPid in [0, -1, 1.5, "1", 0x100000000, DllCall("Kernel32\GetCurrentProcessId", "UInt") + 0x100000000]
	Test("system control: invalid process PID " . _SysActions_InvalidProcessPid . " (process-pid-domain)",
		_SysActions_ProcessPidDomain.Bind(_SysActions_InvalidProcessPid))
Test("system control: owned process PID is retained without termination (process-pid-domain)",
	_SysActions_ProcessPidDomain.Bind(DllCall("Kernel32\GetCurrentProcessId", "UInt"), true))
