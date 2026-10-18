; tests/unit/ui/healthcheck/test_diagnostics_window_control.ahk

; ==============================================================================
; MODULE: Diagnostics Window Control
; DESCRIPTION:
; The diagnostics window opens through one deferred request, rejects wrong
; targets and messages, fences withdrawal and retains throwing timers and
; uncertain listeners; the actual native timer runs one-shot only.
; ==============================================================================

#Requires AutoHotkey v2.0





/** Supplies deterministic boundaries while retaining the actual control owner. */
_TestHC_WindowControlState() {
	State := {Message: 0xC001, Ready: true, Opened: 0, Listeners: [], Timers: [],
		ThrowListen: false, ThrowArm: false, ThrowCancel: false, ThrowShow: false,
		WithdrawReady: false, WithdrawArm: false, WithdrawMessage: false,
		WithdrawListen: false, ReenterShow: false}
	State.Control := HealthCheckWindowControl(Message, Listen, Timer, Show, Ready, 101, 202, 303)
	return State
	Message() {
		if State.WithdrawMessage
			State.Control.Stop()
		return State.Message
	}
	Listen(Id, Callback, Threads) {
		State.Listeners.Push([Id, Callback, Threads])
		if State.WithdrawListen && Threads == 1
			State.Control.Stop()
		if State.ThrowListen
			throw Error("Injected listener boundary failure.")
	}
	Timer(Callback, Period) {
		State.Timers.Push([Callback, Period])
		if Period < 0 && State.WithdrawArm
			State.Control.Stop()
		if (Period < 0 && State.ThrowArm) || (Period == 0 && State.ThrowCancel)
			throw Error("Injected timer boundary failure.")
	}
	Ready() {
		if State.WithdrawReady
			State.Control.Stop()
		return State.Ready
	}
	Show() {
		State.Opened += 1
		if State.ThrowShow
			throw Error("Injected window construction failure.")
		if State.ReenterShow
			AssertEqual(1, State.Control.OnMessage(202, 303, State.Message, 101))
	}
}

_TestHC_WindowControlDeferred() {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	AssertEqual(1, State.Listeners.Length)
	AssertEqual(1, State.Listeners[1][3])
	AssertEqual(1, Control.OnMessage(202, 303, State.Message, 101))
	AssertEqual(0, State.Opened, "A synchronous Win32 sender never enters WebView2.")
	AssertEqual(1, Control.OnMessage(202, 303, State.Message, 101))
	AssertEqual(1, State.Timers.Length, "Pending window requests coalesce.")
	AssertEqual(-1, State.Timers[1][2])
	AssertTrue(Control.Open())
	AssertEqual(1, State.Opened)
	AssertFalse(Control.Open(), "An already spent callback cannot open another window.")
	Control.Stop()
	AssertEqual(0, State.Listeners[2][3])
}
Test("Diagnostics control opens through one deferred request (diagnostics-control)", _TestHC_WindowControlDeferred)

_TestHC_WindowControlWrongTarget(Scenario) {
	State := _TestHC_WindowControlState(), Control := State.Control
	if Scenario != "unstarted"
		Control.Start()
	if Scenario == "not-ready"
		State.Ready := false
	AssertEqual(0, Control.OnMessage(Scenario == "wparam" ? 1 : 202,
		Scenario == "lparam" ? 1 : 303, Scenario == "message" ? 0xC002 : State.Message,
		Scenario == "window" ? 102 : 101))
	AssertEqual(0, State.Timers.Length)
	AssertEqual(0, State.Opened)
	Control.Stop()
}
for _HCControlWrong in ["unstarted", "not-ready", "wparam", "lparam", "message", "window"]
	Test("Diagnostics control rejects " . _HCControlWrong . " (diagnostics-control)",
		_TestHC_WindowControlWrongTarget.Bind(_HCControlWrong))

_TestHC_WindowControlInvalidMessage(Value) {
	State := _TestHC_WindowControlState(), State.Message := Value
	AssertThrows(() => State.Control.Start())
	AssertEqual(0, State.Listeners.Length)
	AssertFalse(State.Control.Active)
	State.Control.Stop()
}
for _HCControlMessage in [0, -1, "49153", 0xBFFF, 0x10000]
	Test("Diagnostics control refuses message " . _HCControlMessage . " (diagnostics-control)",
		_TestHC_WindowControlInvalidMessage.Bind(_HCControlMessage))

_TestHC_WindowControlWithdrawal(Phase) {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	if Phase == "ready"
		State.WithdrawReady := true
	if Phase == "arm"
		State.WithdrawArm := true
	Ack := Control.OnMessage(202, 303, State.Message, 101)
	if Phase == "pending"
		Control.Stop()
	if Phase == "not-ready"
		State.Ready := false
	AssertEqual(Phase == "ready" || Phase == "arm" ? 0 : 1, Ack)
	AssertFalse(Control.Open(), "A withdrawn request cannot open a successor window.")
	AssertEqual(0, State.Opened)
	Control.Stop()
	AssertThrows(() => Control.Start(), "A retired owner cannot be initialized again.")
}
for _HCControlPhase in ["ready", "arm", "pending", "not-ready"]
	Test("Diagnostics control fences " . _HCControlPhase . " withdrawal (diagnostics-control)",
		_TestHC_WindowControlWithdrawal.Bind(_HCControlPhase))

_TestHC_WindowControlRetainedTimer() {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start(), State.ThrowArm := true
	AssertEqual(0, Control.OnMessage(202, 303, State.Message, 101))
	AssertFalse(Control.Active)
	AssertTrue(Control.Pending, "A throwing arm can still own the callback.")
	State.ThrowCancel := true
	AssertThrows(() => Control.Stop())
	AssertTrue(Control.Pending, "Unknown cancellation cannot release the callback.")
	AssertFalse(Control.Listening, "Listener retirement is attempted even after cancellation fails.")
	AssertFalse(Control.Open())
	AssertEqual(0, State.Opened)
	State.ThrowCancel := false
	Control.Stop()
	AssertFalse(Control.Pending)
}
Test("Diagnostics control retains a throwing timer acquisition (diagnostics-control)", _TestHC_WindowControlRetainedTimer)

_TestHC_WindowControlRetainedListener() {
	State := _TestHC_WindowControlState(), Control := State.Control
	State.ThrowListen := true
	AssertThrows(() => Control.Start())
	AssertFalse(Control.Active)
	AssertTrue(Control.Listening)
	AssertThrows(() => Control.Stop())
	AssertTrue(Control.Listening, "Unknown unregistration retains its original listener.")
	AssertEqual(0, Control.OnMessage(202, 303, State.Message, 101))
	State.ThrowListen := false
	Control.Stop()
	AssertFalse(Control.Listening)
}
Test("Diagnostics control retains an uncertain listener (diagnostics-control)", _TestHC_WindowControlRetainedListener)

_TestHC_WindowControlShow(Scenario) {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	AssertThrows(() => Control.Start(), "Duplicate initialization is rejected.")
	State.ThrowShow := Scenario == "throw", State.ReenterShow := Scenario == "reenter"
	AssertEqual(1, Control.OnMessage(202, 303, State.Message, 101))
	if State.ThrowShow
		AssertThrows(() => Control.Open())
	else
		AssertTrue(Control.Open())
	AssertEqual(1, State.Opened)
	AssertFalse(Control.Opening)
	AssertFalse(Control.Pending)
	AssertEqual(1, State.Timers.Length, "A reentrant request cannot schedule a duplicate opener.")
	Control.Stop()
}
for _HCControlShow in ["throw", "reenter"]
	Test("Diagnostics control owns a " . _HCControlShow . " window call (diagnostics-control)",
		_TestHC_WindowControlShow.Bind(_HCControlShow))

_TestHC_WindowControlStartWithdrawal(Phase) {
	State := _TestHC_WindowControlState(), Control := State.Control
	State.WithdrawMessage := Phase == "message", State.WithdrawListen := Phase == "listen"
	AssertThrows(() => Control.Start())
	AssertFalse(Control.Active)
	AssertTrue(Control.Closed)
	AssertEqual(Phase == "message" ? 0 : 2, State.Listeners.Length,
		"A resolved message cannot register after its owner was already retired.")
	AssertFalse(Control.Listening)
	AssertEqual(0, Control.OnMessage(202, 303, State.Message, 101))
	Control.Stop()
}
for _HCControlStartPhase in ["message", "listen"]
	Test("Diagnostics control fences " . _HCControlStartPhase . " startup withdrawal (diagnostics-control)",
		_TestHC_WindowControlStartWithdrawal.Bind(_HCControlStartPhase))

_TestHC_WindowControlUnboundRequest() {
	State := _TestHC_WindowControlState(), Control := State.Control
	Control.Start()
	try {
		AssertEqual(0, Control.OnMessage(0, 0, State.Message, 101),
			"A recycled HWND cannot grant an unbound request to another receiver.")
		AssertEqual(0, State.Timers.Length)
		AssertEqual(0, State.Opened)
	} finally {
		Control.Stop()
	}
}
Test("Diagnostics control refuses an unbound request (diagnostics-control-unbound)", _TestHC_WindowControlUnboundRequest)

/** Receives the actual production timer collaborator, including native cancellation. */
_TestHC_ActualControlTimer(Scenario) {
	global _HealthCheckWindowControl
	AssertFalse(IsObject(_HealthCheckWindowControl), "the actual diagnostics endpoint must have no prior owner")
	Count := 0
	Callback := (*) => Count += 1
	HealthCheck_StartWindowControl()
	Control := _HealthCheckWindowControl
	try {
		if Scenario == "repeating" {
			AssertThrows(() => Control.TimerFn.Call(Callback, 100),
				"the production diagnostics control must refuse a repeating timer")
		} else if Scenario == "cancelled" {
			PreviousCritical := A_IsCritical
			Critical("On")
			try {
				Control.TimerFn.Call(Callback, -1)
				Control.TimerFn.Call(Callback, 0)
			} finally Critical(PreviousCritical)
			Sleep(100)
			AssertEqual(0, Count, "actual native cancellation must withdraw the exact callback")
		} else {
			AssertEqual("one-shot", Scenario, "the authored native scenario must be known")
			Control.TimerFn.Call(Callback, -1)
			Started := A_TickCount
			while Count == 0 && A_TickCount - Started < 2000
				Sleep(10)
			AssertEqual(1, Count, "the actual deferred callback must run")
			Sleep(100)
			AssertEqual(1, Count, "the actual callback must remain one-shot")
		}
	} finally {
		try Control.TimerFn.Call(Callback, 0)
		finally HealthCheck_StopWindowControl()
	}
	AssertFalse(IsObject(_HealthCheckWindowControl), "the actual production listener must retire")
}
Test("Diagnostics native timer: repeating periods are refused (diagnostics-control-native-timer)", _TestHC_ActualControlTimer.Bind("repeating"))
Test("Diagnostics native timer: actual one-shot executes once (diagnostics-control-native-timer)", _TestHC_ActualControlTimer.Bind("one-shot"))
Test("Diagnostics native timer: actual cancellation retires its callback (diagnostics-control-native-timer)", _TestHC_ActualControlTimer.Bind("cancelled"))
