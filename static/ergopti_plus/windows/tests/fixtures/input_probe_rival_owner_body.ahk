; tests/fixtures/input_probe_rival_owner_body.ahk

; ==============================================================================
; MODULE: Input Probe Native Rival Owner Child
; DESCRIPTION:
; Drives the genuine rival scenario and repetition with a real private GUI.
; Built-in observers preserve arguments and delegate only into that owned Edit.
; Native Suspend is established before the old clock call returns; the default
; QPC call is not claimed to pump. No clipboard or foreign window is touched.
; ==============================================================================

#Requires AutoHotkey v2.0

_IPR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerStart(*) {
}
LoggerInfo(*) {
}
LoggerWarn(*) => _IPR_Diagnostic()
LoggerError(*) => _IPR_Diagnostic()
LoggerSuccess(*) {
}
_IPR_Diagnostic() {
	global _IPR
	_IPR.Diagnostics += 1
}

_IPR_KeepFailure(Failure) {
	global _IPR
	if !IsObject(_IPR.Failure)
		_IPR.Failure := Failure
}
_IPR_OnError(Failure, *) {
	_IPR_KeepFailure(Failure)
	return true
}

; The real reader is called and its exact result returned. Scheduling control
; supplies a deterministic witness at a source line already outside Critical.
HotPath_Now() {
	global _IPR
	Value := _IPR_NativeClock()
	_IPR.ClockCalls += 1
	if !_IPR.Armed
		return Value
	_IPR.Armed := false
	try {
		_IPR_Require(!A_IsCritical && !A_IsSuspended && _IP_TargetReady(_IPR.Target),
			"The genuine QPC cutpoint must follow target admission on an eligible running frame.")
		_IPR_Require(_IPR.Sends.Length == 0,
			"Native pause must be scheduled before the admitted old repetition sends anything.")
		_IPR.AdmittedTarget := true
		SetTimer(_IPR.PauseTimer, -1)
		Started := A_TickCount
		while !_IPR.PauseDone && TickElapsed(Started) < 2000
			Sleep(10)
		_IPR_Require(_IPR.PauseDone && _IPR.TimerCalls == 1 && _IPR.PauseObserved && A_IsSuspended,
			"The actual native pause timer must complete before returning the delegated clock value.")
	} catch Any as Failure {
		_IPR_KeepFailure(Failure)
	}
	return Value
}

_IPR_Pause() {
	global _IPR
	try {
		_IPR_Require(!A_IsCritical && !A_IsSuspended && _IP_TargetReady(_IPR.Target),
			"The native timer must interrupt the exact live owned repetition.")
		_IPR.TimerCalls += 1
		Suspend(true)
		_IPR.PauseObserved := A_IsSuspended
		_IPR_Require(_IPR.PauseObserved, "Native Suspend must actually become active.")
	} catch Any as Failure {
		_IPR_KeepFailure(Failure)
	} finally {
		_IPR.PauseDone := true
	}
}

_IPR_SendInput(Keys) => _IPR_ObserveSend("SendInput", Keys)
_IPR_SendEvent(Keys) => _IPR_ObserveSend("SendEvent", Keys)
_IPR_ObserveSend(Mode, Keys) {
	global _IPR
	try {
		_IPR_Require(_IPR.Active && _IP_TargetReady(_IPR.Target),
			"The native observer refuses hardware output outside this exact private target.")
		Burst := Mode == "SendInput" && Keys == _IPR.BurstKeys
		Rival := Mode == "SendEvent" && Keys == "{Text}#"
		_IPR_Require(Burst || Rival, "Every genuine native call must carry its exact known synthetic arguments.")
		Record := {Mode: Mode, Keys: Keys, Paused: A_IsSuspended, Level: A_SendLevel,
			Foreground: DllCall("GetForegroundWindow", "Ptr"), Focus: DllCall("GetFocus", "Ptr"), Returned: false}
		_IPR.Sends.Push(Record)
		if Rival {
			_IPR.RivalCalls += 1
			if Record.Paused
				_IPR.PausedRivals += 1
		}
		; Paused delivery still delegates into the owned target, so the negative
		; oracle observes the actual native effect rather than a fake refusal.
		if Mode == "SendInput"
			SendInput(Keys)
		else
			SendEvent(Keys)
		Record.Returned := true
		return true
	} catch Any as Failure {
		_IPR_KeepFailure(Failure)
		return false
	}
}

; A local String owns the UTF-16 pointer for this diagnostic loop.
_IPR_Units(Text) {
	Result := "", Pointer := StrPtr(Text)
	loop StrLen(Text)
		Result .= Format("{:04X}", NumGet(Pointer, (A_Index - 1) * 2, "UShort"))
	return Result
}
_IPR_Observe() {
	global _IPR
	FileAppend("RECEIPT input-probe-rival-owner mode=" . _IPR.Mode
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " root=" . A_Args[2]
		. " admitted_target=" . _IPR.AdmittedTarget . " timer_calls=" . _IPR.TimerCalls
		. " pause_observed=" . _IPR.PauseObserved . " paused=" . A_IsSuspended
		. " clock_calls=" . _IPR.ClockCalls . " native_calls=" . _IPR.Sends.Length
		. " native_rivals=" . _IPR.RivalCalls . " paused_rivals=" . _IPR.PausedRivals
		. " kind=" . _IPR.Result["kind"] . " diagnostics=" . _IPR.Diagnostics . "`n", "*", "UTF-8-RAW")
	for Record in _IPR.Sends {
		FileAppend("SEND input-probe-rival-owner mode=" . Record.Mode . " paused=" . Record.Paused
			. " level=" . Record.Level . " foreground=" . Record.Foreground . " focus=" . Record.Focus
			. " returned=" . Record.Returned . " keys_utf16=" . _IPR_Units(Record.Keys) . "`n", "*", "UTF-8-RAW")
	}
	FileAppend("EDIT input-probe-rival-owner units=" . _IPR_Units(_IPR.Target["edit"].Value)
		. "`n", "*", "UTF-8-RAW")
}

_IPR_Exercise() {
	global _IPR, _InputProbeBusy
	_IPR_Require(_IP_Admission() == "" && !_InputProbeBusy,
		"The actual module admission must prove an unpaused, modifier-free, nonbusy start.")
	Window := Gui("+AlwaysOnTop", "Private input probe rival fixture")
	_IPR.Target := Map("gui", Window, "edit", Window.AddEdit("w560 r6"))
	Window.Show("w600")
	WinActivate("ahk_id " . Window.Hwnd)
	_IPR_Require(WinWaitActive("ahk_id " . Window.Hwnd, , 2), "The private native GUI must actually become foreground.")
	_IPR.Target["edit"].Focus()
	_IPR_Require(_IP_TargetReady(_IPR.Target), "The true production readiness predicate must admit the owned Edit.")
	Spec := 0
	for Scenario in _IP_Scenarios() {
		if Scenario["id"] == "rival" {
			_IPR_Require(!IsObject(Spec), "Exactly one genuine rival scenario must exist.")
			Spec := Scenario["spec"]
		}
	}
	_IPR_Require(IsObject(Spec) && Spec["prefill"] == "xxxxx" && Spec["expected"] == _IPR.Expected
		&& Spec["rival"] == "#", "The real scenario must expose its exact independent synthetic golden.")
	Frequency := 0
	_IPR_Require(DllCall("QueryPerformanceFrequency", "Int64*", &Frequency) && Frequency > 0,
		"The actual native QPC frequency must be valid before measurement.")
	_IPR.Active := true
	_IPR.Armed := _IPR.Mode == "pause"
	_IPR.Result := _IP_RunRep(_IPR.Target, Spec, "SendInput", Frequency)
	if IsObject(_IPR.Failure)
		throw _IPR.Failure
	_IPR_Require(_IPR.Diagnostics == 0 && _IPR.ClockCalls > 0,
		"An unexpected diagnostic or missing real clock cannot qualify the quiet oracle.")
	for Record in _IPR.Sends
		_IPR_Require(Record.Returned && Record.Foreground == Window.Hwnd
			&& Record.Focus == _IPR.Target["edit"].Hwnd,
			"All observed native arguments must actually return under exact private target ownership.")
	if _IPR.Mode == "pause"
		_IPR_Require(_IPR.AdmittedTarget && _IPR.PauseDone && _IPR.PauseObserved
			&& _IPR.TimerCalls == 1 && !_IPR.Armed && A_IsSuspended,
			"True native pause after admission must precede every business refusal assertion.")
	_IPR_Observe()
	if _IPR.Mode == "pause" {
		_IPR_Require(_IPR.PausedRivals == 0,
			"A scheduled rival must not emit native input after the admitted repetition is paused.")
	} else {
		_IPR_Require(_IPR.Sends.Length == 2 && _IPR.RivalCalls == 1 && _IPR.PausedRivals == 0,
			"The affirmative repetition must perform both the real burst and its real native rival.")
		_IPR_Require(_IPR.Result["kind"] == "ok" || _IPR.Result["kind"] == "interleaved",
			"The real Edit must retain the entire synthetic burst and its rival without loss.")
		Actual := _IPR.Target["edit"].Value
		_IPR_Require(StrReplace(Actual, "#", "") == _IPR.Expected && StrLen(Actual) == StrLen(_IPR.Expected) + 1,
			"Exactly one real native rival must reach the actual private Edit alongside the complete burst.")
	}
}

_IPR_Main() {
	global _IPR
	if A_Args.Length != 2
		ExitApp(2)
	_IPR := {Mode: A_Args[1], Target: 0, Active: false, Armed: false, Failure: 0,
		Diagnostics: 0, ClockCalls: 0, AdmittedTarget: false, TimerCalls: 0,
		PauseObserved: false, PauseDone: false, RivalCalls: 0, PausedRivals: 0, Sends: [], Result: 0,
		Expected: "déjà vu ab€cdefghij", BurstKeys: "{Backspace 5}{Text}déjà vu ab€cdefghij",
		PauseTimer: _IPR_Pause}
	Primary := 0, PreviousSuspend := A_IsSuspended, PreviousCritical := Critical("Off")
	Suspend(false)
	Thread("Interrupt", 0)
	OnError(_IPR_OnError)
	try _IPR_Exercise()
	catch Any as Failure
		Primary := IsObject(_IPR.Failure) ? _IPR.Failure : Failure
	finally {
		_IPR.Active := false
		try SetTimer(_IPR.PauseTimer, 0)
		try SetTimer(_IP_RivalFire, 0)
		OnError(_IPR_OnError, 0)
		Suspend(PreviousSuspend)
		if IsObject(_IPR.Target) {
			Hwnd := _IPR.Target["gui"].Hwnd
			try _IPR.Target["gui"].Destroy()
			if DllCall("IsWindow", "Ptr", Hwnd, "Int") && !IsObject(Primary)
				Primary := Error("The exact private native target did not retire.")
		}
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_IPR.Failure)
		Primary := _IPR.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS input-probe-rival-owner " . _IPR.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_IPR_Main()
