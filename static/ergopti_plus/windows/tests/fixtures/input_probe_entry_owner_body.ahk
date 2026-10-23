; tests/fixtures/input_probe_entry_owner_body.ahk

; ==============================================================================
; MODULE: Input Probe Native Entry Child
; DESCRIPTION:
; The entire real public HookOrder probe retains its real native hook, hotkey,
; and existing sleeps. Observed send primitives call the actual builtin with
; unchanged arguments and return. Every send requires a focused private Edit.
; Native pause is not a claim of complete desktop lifecycle teardown. Close
; exercises the current default Hide behavior; a future destruction is also
; admissible retirement, without claiming either outcome before native execution.
; ==============================================================================

#Requires AutoHotkey v2.0

_IPES_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) {
	global _IPES
	return Key == "input_probe.title" ? _IPES.Title : Key
}

WindowTitle(Label := "") => Label

_IPES_OwnsFocus(WindowHwnd, FieldHwnd) {
	return DllCall("User32\IsWindow", "Ptr", WindowHwnd, "Int")
		&& DllCall("User32\IsWindowVisible", "Ptr", WindowHwnd, "Int")
		&& DllCall("User32\GetForegroundWindow", "Ptr") == WindowHwnd
		&& DllCall("User32\GetFocus", "Ptr") == FieldHwnd
		&& DllCall("User32\IsChild", "Ptr", WindowHwnd, "Ptr", FieldHwnd, "Int")
}

_IPES_SendInput(Keys) => _IPES_Send("SendInput", Keys)
_IPES_SendEvent(Keys) => _IPES_Send("SendEvent", Keys)

_IPES_Send(Mode, Keys) {
	global _IPES, INPUT_PROBE_HOOK_KEYS, _InputProbeBusy
	if IsObject(_IPES.Failure)
		throw _IPES.Failure
	_IPES_Require(Keys == INPUT_PROBE_HOOK_KEYS && _InputProbeBusy,
		"Only the actual probe's unchanged synthetic key may reach a native send.")
	if _IPES.NativeCalls == 0 {
		_IPES.TargetHwnd := DllCall("User32\GetForegroundWindow", "Ptr")
		_IPES.TargetFieldHwnd := DllCall("User32\GetFocus", "Ptr")
		_IPES.Target := GuiFromHwnd(_IPES.TargetHwnd)
		Field := GuiCtrlFromHwnd(_IPES.TargetFieldHwnd)
		_IPES_Require(IsObject(_IPES.Target) && IsObject(Field) && Field.Type == "Edit"
			&& Field.Gui == _IPES.Target && WinGetTitle("ahk_id " . _IPES.TargetHwnd) == _IPES.Title,
			"The first real send requires the actual probe's private native Edit.")
	} else {
		_IPES.NextAttempts += 1
		_IPES.BoundaryBeforeNext := _IPES.BoundaryReturned
		_IPES_Require(_IPES.BoundaryReturned, "The actual native boundary must return before any second send.")
	}
	TargetFocus := _IPES_OwnsFocus(_IPES.TargetHwnd, _IPES.TargetFieldHwnd)
	KeeperFocus := _IPES_OwnsFocus(_IPES.KeeperHwnd, _IPES.KeeperFieldHwnd)
	_IPES_Require(TargetFocus || KeeperFocus,
		"A foreign foreground or focus is a prerequisite failure before native injection.")
	Paused := A_IsSuspended
	Hidden := !DllCall("User32\IsWindowVisible", "Ptr", _IPES.TargetHwnd, "Int")
	; These are the actual builtins. The observer never fabricates their result
	; or mutates the probe's counters, return Map, hook callback, or verdict.
	Value := Mode == "SendInput" ? SendInput(Keys) : SendEvent(Keys)
	_IPES.NativeCalls += 1
	if TargetFocus
		_IPES.TargetSends += 1
	if KeeperFocus
		_IPES.KeeperSends += 1
	if Paused
		_IPES.PausedSends += 1
	if Hidden
		_IPES.HiddenTargetSends += 1
	if _IPES.NativeCalls == 1 {
		_IPES.FirstNativeReturned := true
		SetTimer(_IPES.BoundaryTimer, -1)
	}
	return Value
}

_IPES_Boundary() {
	global _IPES
	_IPES.BoundaryEntries += 1
	try {
		_IPES_Require(_IPES.FirstNativeReturned && _IPES.NativeCalls == 1
			&& !_IPES.BoundaryReturned && _IPES.BoundaryEntries == 1
			&& _IPES_OwnsFocus(_IPES.TargetHwnd, _IPES.TargetFieldHwnd),
			"Only the genuine existing post-send sleep can admit this native boundary.")
		if _IPES.Mode == "pause" {
			Suspend(true)
			_IPES_Require(A_IsSuspended, "The real native paused flag must be active before the old probe continues.")
			_IPES.PauseObserved := true
		}
		if _IPES.Mode == "close" {
			_IPES_Require(DllCall("User32\IsWindow", "Ptr", _IPES.TargetHwnd, "Int"),
				"The original native window must still exist before its real Close message.")
			DllCall("User32\SendMessageW", "Ptr", _IPES.TargetHwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Ptr")
			Started := A_TickCount
			while DllCall("User32\IsWindow", "Ptr", _IPES.TargetHwnd, "Int")
				&& DllCall("User32\IsWindowVisible", "Ptr", _IPES.TargetHwnd, "Int")
				&& !IsObject(_IPES.Failure) && TickElapsed(Started) < 1000
				Sleep(5)
			if IsObject(_IPES.Failure)
				throw _IPES.Failure
			Exists := DllCall("User32\IsWindow", "Ptr", _IPES.TargetHwnd, "Int")
			Visible := Exists && DllCall("User32\IsWindowVisible", "Ptr", _IPES.TargetHwnd, "Int")
			_IPES.CloseWaitMs := TickElapsed(Started)
			_IPES.CloseObserved := !Exists || !Visible
			_IPES.CloseWasHide := Exists && !Visible
			_IPES.CloseWasDestroyed := !Exists
			_IPES_Require(_IPES.CloseObserved, "Actual WM_CLOSE must retire the original visible target before the next send.")
			_IPES.Keeper.Show("w600")
			WinActivate("ahk_id " . _IPES.KeeperHwnd)
			_IPES_Require(WinWaitActive("ahk_id " . _IPES.KeeperHwnd, , 3),
				"Only the private keeper window may receive focus after the probe target hides.")
			_IPES.KeeperField.Focus()
			_IPES_Require(_IPES_OwnsFocus(_IPES.KeeperHwnd, _IPES.KeeperFieldHwnd),
				"The exact private keeper Edit must own focus before returning to the old probe.")
			_IPES.KeeperObserved := true
		}
	} catch as Failure {
		if !IsObject(_IPES.Failure)
			_IPES.Failure := Failure
	} finally _IPES.BoundaryReturned := true
}

_IPES_OnError(Failure, Mode) {
	global _IPES
	if !IsObject(_IPES.Failure)
		_IPES.Failure := Failure is Error ? Failure : Error("A native probe boundary failed asynchronously.")
	try FileAppend("DIAG input-probe-entry type=" . Type(Failure) . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

_IPES_Log(Line) {
	global _IPES
	if InStr(Line, "[ERROR]") && !IsObject(_IPES.Failure)
		_IPES.Failure := Error("The real probe emitted an error before its business oracle.")
}

_IPES_Report(Result) {
	global _IPES, _InputProbeBusy, _IPES_ObservedSites
	FileAppend("RECEIPT input-probe-entry mode=" . _IPES.Mode . " native_calls=" . _IPES.NativeCalls
		. " target_sends=" . _IPES.TargetSends . " keeper_sends=" . _IPES.KeeperSends
		. " paused_sends=" . _IPES.PausedSends . " hidden_target_sends=" . _IPES.HiddenTargetSends
		. " boundary_entries=" . _IPES.BoundaryEntries . " boundary_returned=" . _IPES.BoundaryReturned
		. " first_native_returned=" . _IPES.FirstNativeReturned . " pause_observed=" . _IPES.PauseObserved
		. " close_retired_observed=" . _IPES.CloseObserved . " close_hide_observed=" . _IPES.CloseWasHide
		. " close_destroy_observed=" . _IPES.CloseWasDestroyed . " close_wait_ms=" . _IPES.CloseWaitMs
		. " next_send_attempts=" . _IPES.NextAttempts . " boundary_before_next_send=" . _IPES.BoundaryBeforeNext
		. " keeper_focus_observed=" . _IPES.KeeperObserved
		. " state=" . (IsObject(Result) ? Result["state"] : "UNKNOWN")
		. " native_suspended=" . A_IsSuspended . " busy=" . _InputProbeBusy
		. " builtin_sites=" . _IPES_ObservedSites . " boundary_failure=" . IsObject(_IPES.Failure)
		. "`n", "*", "UTF-8")
}

_IPES_Main() {
	global _IPES, _InputProbeBusy
	if A_Args.Length != 3
		ExitApp(2)
	Persistent(true)
	_IPES := {Mode: A_Args[1], Title: "ergopti-input-probe-entry-" . A_ScriptHwnd,
		Target: 0, TargetHwnd: 0, TargetFieldHwnd: 0, Keeper: 0, KeeperField: 0,
		KeeperHwnd: 0, KeeperFieldHwnd: 0, NativeCalls: 0, TargetSends: 0, KeeperSends: 0,
		PausedSends: 0, HiddenTargetSends: 0, BoundaryEntries: 0, BoundaryReturned: false,
		FirstNativeReturned: false, PauseObserved: false, CloseObserved: false, CloseWasHide: false, CloseWasDestroyed: false,
		CloseWaitMs: 0, NextAttempts: 0, BoundaryBeforeNext: -1, KeeperObserved: false, Failure: 0}
	_IPES.BoundaryTimer := _IPES_Boundary
	OnError(_IPES_OnError)
	LoggerSetTestSink(_IPES_Log)
	Primary := 0, Result := 0, Observed := false, InheritedCritical := A_IsCritical
	try {
		_IPES_Require(!A_IsSuspended && !_InputProbeBusy, "No earlier probe or paused state may be borrowed.")
		Suspend(true)
		Refused := InputProbe_RunHookOrder()
		_IPES_Require(Refused["state"] == "aborted" && Refused["reason"] == "paused"
			&& !_InputProbeBusy && _IPES.NativeCalls == 0 && WinGetList(_IPES.Title).Length == 0,
			"The unchanged public entry must already refuse a new probe under native pause.")
		Suspend(false)
		_IPES.Keeper := Gui("", "ergopti-input-probe-keeper-" . A_ScriptHwnd)
		_IPES.KeeperField := _IPES.Keeper.AddEdit("w560 r6")
		_IPES.Keeper.Show("Hide w600")
		_IPES.KeeperHwnd := _IPES.Keeper.Hwnd
		_IPES.KeeperFieldHwnd := _IPES.KeeperField.Hwnd
		Result := InputProbe_RunHookOrder()
		_IPES_Report(Result), Observed := true
		if IsObject(_IPES.Failure)
			throw _IPES.Failure
		_IPES_Require(_IPES.FirstNativeReturned && _IPES.BoundaryEntries == 1 && _IPES.BoundaryReturned
			&& _IPES.TargetSends >= 1 && !_InputProbeBusy,
			"The real public run must reach native first delivery, boundary return and its own cleanup.")
		if _IPES.Mode == "current" {
			_IPES_Require(_IPES.NativeCalls == 4 && _IPES.TargetSends == 4 && _IPES.KeeperSends == 0
				&& _IPES.PausedSends == 0 && _IPES.HiddenTargetSends == 0 && Result["state"] == "done",
				"The affirmative current control must complete four genuine sends into its exact private Edit.")
		} else if _IPES.Mode == "pause" {
			_IPES_Require(_IPES.PauseObserved && A_IsSuspended, "The pause prerequisite must remain real through the oracle.")
			_IPES_Require(_IPES.PausedSends == 0,
				"A probe started running must stop native injection after native pause.")
		} else {
			_IPES_Require(_IPES.Mode == "close" && _IPES.CloseObserved && _IPES.KeeperObserved,
				"The exact old target retirement and private successor focus must be observed before judging sends.")
			_IPES_Require(_IPES.HiddenTargetSends == 0 && _IPES.KeeperSends == 0,
				"A probe must stop native injection when its original private target has closed and hidden.")
		}
	} catch as Failure {
		Primary := IsObject(_IPES.Failure) ? _IPES.Failure : Failure
	} finally {
		if !Observed {
			try _IPES_Report(Result)
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			SetTimer(_IPES.BoundaryTimer, 0)
			if IsObject(_IPES.Target)
				_IPES.Target.Destroy()
			if IsObject(_IPES.Keeper)
				_IPES.Keeper.Destroy()
			_IPES_Require(!_InputProbeBusy, "The genuine public run must release its own busy admission.")
			if _IPES.TargetHwnd
				_IPES_Require(!DllCall("User32\IsWindow", "Ptr", _IPES.TargetHwnd, "Int"),
					"The exact private native target must retire before child exit.")
			if _IPES.KeeperHwnd
				_IPES_Require(!DllCall("User32\IsWindow", "Ptr", _IPES.KeeperHwnd, "Int"),
					"The exact private keeper must retire before child exit.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			Suspend(false)
			LoggerClearTestSink()
			OnError(_IPES_OnError, 0)
			_IPES.BoundaryTimer := 0
			Critical(InheritedCritical)
		}
	}
	if !IsObject(Primary) && IsObject(_IPES.Failure)
		Primary := _IPES.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS input-probe-entry " . _IPES.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_IPES_Main()
