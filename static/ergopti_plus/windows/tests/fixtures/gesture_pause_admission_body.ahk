; tests/fixtures/gesture_pause_admission_body.ahk

; The real sink below models only the ordinary pre-Critical scheduler window.
; It never pauses from a Critical preparation callback and is not a native
; hotkey-delivery witness. Suspend and this feature's actual release functions
; are real; the complete system suspend reactor is deliberately not simulated.
global _SharedDir := _GPO_SourceShared
global Features := Map("gestures", Map("enabled", true))
global GestureAssignments := Map("tap_3", "none")
global GESTURE_ACTION_CATALOGUE := GestureActionCatalogueData()
global _GPO := {Mode: A_Args[1], Events: [], Stops: [], Hooks: [], Logs: [], Errors: [], PauseHits: 0,
	SinkArmed: false, SinkFailed: false, SinkFailure: 0, PauseCleanup: false, AdminArmed: false,
	AdminExitEntered: false, Finished: false, SavedSuspend: A_IsSuspended, SavedCritical: A_IsCritical,
	NativeHeld: Map("Left", false, "Right", false)}

_GPO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_GPO_Click(Button, Direction) {
	global _GPO
	_GPO_Require(_GPO.NativeHeld.Has(Button) && (Direction == "Down" || Direction == "Up"), "only the actual mouse transport may be bound")
	_GPO.Events.Push(Map("button", Button, "direction", Direction, "suspended", A_IsSuspended))
	_GPO.NativeHeld[Button] := Direction == "Down"
}

_GPO_Stop(Hook) {
	global _GPO
	_GPO.Stops.Push(ObjPtr(Hook))
	Hook.Stop()
}

_GPO_Observe(Phase) {
	global _GPO, GestureKeyboardHook, GestureLeftClickHeld, GestureRightClickHeld
	if GestureKeyboardHook is InputHook {
		Retained := false
		for Hook in _GPO.Hooks
			if Hook == GestureKeyboardHook
				Retained := true
		if !Retained
			_GPO.Hooks.Push(GestureKeyboardHook)
	}
	FileAppend("OBSERVATION " . KL_JsonEncode(Map("phase", Phase, "mode", _GPO.Mode, "critical", A_IsCritical,
		"suspended", A_IsSuspended, "pause_hits", _GPO.PauseHits, "pause_cleanup", _GPO.PauseCleanup,
		"left_held", GestureLeftClickHeld, "right_held", GestureRightClickHeld,
		"current", IsObject(GestureKeyboardHook) ? ObjPtr(GestureKeyboardHook) : 0,
		"in_progress", IsObject(GestureKeyboardHook) ? GestureKeyboardHook.InProgress : false,
		"events", _GPO.Events.Clone(), "stops", _GPO.Stops.Clone(), "logs", _GPO.Logs.Clone())) . "`n", "*")
}

_GPO_Empty() {
	global _GPO, GestureKeyboardHook, GestureLeftClickHeld, GestureRightClickHeld
	_GPO_Require(!GestureLeftClickHeld && !GestureRightClickHeld && GestureKeyboardHook == 0, "the actual feature cleanup must retire both holds and the exact native watcher")
	_GPO_Require(!_GPO.NativeHeld["Left"] && !_GPO.NativeHeld["Right"], "every modeled native mouse debt must be acknowledged")
	for Event in ["mouse_ldown", "mouse_rdown"]
		_GPO_Require(!HookDispatcher._subscribers.Has(Event) || HookDispatcher._subscribers[Event].Length == 0,
			"the private recovery subscriber registry must be empty")
}

_GPO_Sink(Line) {
	global _GPO
	if _GPO.Logs.Length < 100
		_GPO.Logs.Push(Line)
	if RegExMatch(Line, "\s\[ERROR\] \[")
		_GPO.Errors.Push(Line)
	Button := _GPO.Mode == "paused-left" ? "left" : "right"
	Sentinel := "[DEBUG] [gestures] Enabling " . Button . "-click hold mode" . Chr(0x2026)
	if !_GPO.SinkArmed || SubStr(Line, -StrLen(Sentinel)) != Sentinel
		return
	_GPO.SinkArmed := false
	try {
		_GPO.PauseHits += 1
		_GPO_Require(A_IsCritical == 0 && !A_IsSuspended, "the controlled pause must occur before the acquisition's Critical, never inside it")
		_GPO_Require(_GPO.Events.Length == 0, "the observed pause must precede any modeled Down")
		Suspend(true)
		_GPO_Require(A_IsSuspended, "native Suspend must actually complete")
		_GPO_Require(GestureReleaseLeftClick() && GestureReleaseRightClick(), "the feature's genuine pause cleanup must acknowledge both releases")
		_GPO_Empty()
		_GPO.PauseCleanup := true
		_GPO_Observe("pre-critical-pause-cleanup-complete")
	} catch Any as Failure {
		_GPO.SinkFailed := true
		_GPO.SinkFailure := Failure
	}
}

_GPO_Dispatch(Action) {
	global GestureAssignments
	GestureAssignments["tap_3"] := Action
	GestureDispatch("tap_3")
}

_GPO_Paused() {
	global _GPO
	_GPO.SinkArmed := true
	_GPO_Dispatch(_GPO.Mode == "paused-left" ? "left_click_toggle" : "right_click_toggle")
	if _GPO.SinkFailed
		throw _GPO.SinkFailure
	_GPO_Observe("paused-dispatch-returned")
	_GPO_Require(_GPO.PauseHits == 1 && _GPO.PauseCleanup && A_IsSuspended, "the actual logger frontier and completed feature pause are prerequisites")
	_GPO_Require(_GPO.Errors.Length == 0, "the actual route must not hide a prerequisite or action error")
	_GPO_Require(_GPO.Events.Length == 0, "an acquisition resumed after completed pause must emit no late mouse Down")
	_GPO_Empty()
}

_GPO_Current() {
	global _GPO, GestureKeyboardHook, GestureLeftClickHeld, GestureRightClickHeld
	_GPO_Dispatch("left_click_toggle")
	First := GestureKeyboardHook
	_GPO_Require(First is InputHook && First.InProgress && GestureLeftClickHeld, "the actual current left route must admit a native watcher")
	_GPO.Hooks.Push(First)
	_GPO_Dispatch("right_click_toggle")
	Second := GestureKeyboardHook
	_GPO_Require(Second is InputHook && Second.InProgress && GestureRightClickHeld && GestureLeftClickHeld,
		"the actual current right route must preserve both accepted holds")
	_GPO.Hooks.Push(Second)
	_GPO_Require(First != Second && !First.InProgress && _GPO.Events.Length == 2, "actual replacement must retire A before B is published")
	Callback := Second.OnKeyDown
	Callback.Call(Second, 0x41, 0x1E)
	_GPO_Observe("current-callback-returned")
	_GPO_Require(_GPO.Errors.Length == 0, "the current route must not hide a prerequisite or action error")
	_GPO_Empty()
	_GPO_Require(_GPO.Events.Length == 4 && _GPO.Events[3]["direction"] == "Up" && _GPO.Events[4]["direction"] == "Up",
		"the current real route must retain its two matching releases")
}

_GPO_Cleanup() {
	global _GPO, GestureKeyboardHook
	LoggerClearTestSink()
	_GPO.SinkArmed := false
	try {
		_GPO_Require(GestureReleaseLeftClick(), "private left cleanup must settle")
		_GPO_Require(GestureReleaseRightClick(), "private right cleanup must settle")
		for Hook in _GPO.Hooks {
			Hook.Stop()
			_GPO_Require(!Hook.InProgress, "every retained actual native watcher must be stopped")
		}
		_GPO_Empty()
	} finally {
		Suspend(_GPO.SavedSuspend)
		Critical(_GPO.SavedCritical)
	}
}

_GPO_Receipt(AdminExit := false) {
	global _GPO, _GPO_ActualOwnerHash
	FileAppend("RECEIPT " . KL_JsonEncode(Map("pid", DllCall("GetCurrentProcessId", "UInt"), "mode", _GPO.Mode,
		"source_sha256", A_Args[3], "runtime_sha256", A_Args[4], "click_owner_sha256", _GPO_ActualOwnerHash,
		"callback_delivery", "controlled", "mouse_injected", false, "hooks_retired", true, "subscriptions_retired", true,
		"suspended", A_IsSuspended, "pause_hits", _GPO.PauseHits, "catalogue_genuine", true,
		"administrative_native_exit", AdminExit)) . "`n", "*")
}

_GPO_OnExit(Reason, Code) {
	global _GPO
	if !_GPO.AdminArmed || _GPO.Finished || Code != 0
		return 0
	try {
		_GPO.AdminExitEntered := true
		_GPO_Require(Reason == "Exit" && A_IsSuspended, "the genuine administrative catalogue action must reach native ExitApp while paused")
		_GPO_Require(_GPO.Errors.Length == 0, "the administrative route must not hide a prerequisite or action error")
		_GPO_Observe("administrative-native-exit")
		_GPO_Cleanup()
		_GPO.Finished := true
		OnExit(_GPO_OnExit, 0)
		_GPO_Receipt(true)
		return 0
	} catch Any as Failure {
		_GPO.SinkFailed := true
		_GPO.SinkFailure := Failure
		return 1
	}
}

_GPO_Main() {
	global _GPO, _GPO_ActualOwnerHash, LOGGER_MIN_LEVEL, GESTURE_ACTION_CATALOGUE, GESTURE_ACTIONS
	_GPO_Require(A_Args.Length == 4 && A_Args[2] == _GPO_ActualOwnerHash, "the exact private child ABI and production owner must match")
	for Index, Path in Map(3, A_ScriptFullPath, 4, A_AhkPath)
		_GPO_Require(RegExMatch(A_Args[Index], "^[0-9a-f]{64}$") && CryptoSha256Bytes(FileRead(Path, "RAW")) == A_Args[Index], "actual source and native runtime hashes must match")
	for Action in ["left_click_toggle", "right_click_toggle", "script_quit"] {
		_GPO_Require(GESTURE_ACTIONS.Has(Action) && GESTURE_ACTION_CATALOGUE.Actions.Has(Action), "the genuine registry and generated metadata must admit the selected action")
		_GPO_Require(!GestureActionNeedsConfirm(Action) && GestureActionParameterSpec(Action) == "", "the selected actual catalogue actions must use the ordinary zero-argument branch")
	}
	for Key in ["LControl", "RControl", "LShift", "RShift", "LWin", "RWin"]
		_GPO_Require(!GetKeyState(Key) && !GetKeyState(Key, "P"), "private dispatch requires clear real carrier modifiers; no fixture keyboard output is permitted")
	LOGGER_MIN_LEVEL := "DEBUG"
	_LoggerRefreshFastFlags()
	_LoggerRepeatEnable()
	LoggerSetTestSink(_GPO_Sink)
	OnExit(_GPO_OnExit)
	Critical("Off")
	Suspend(false)
	Primary := 0, HasPrimary := false
	try {
		switch _GPO.Mode {
			case "paused-left", "paused-right": _GPO_Paused()
			case "current-both": _GPO_Current()
			case "admin-paused-quit":
				Suspend(true)
				_GPO.AdminArmed := true
				_GPO_Dispatch("script_quit")
				if _GPO.SinkFailed
					throw _GPO.SinkFailure
				throw Error("the genuine administrative Quit action must exit rather than return under pause")
			default: throw Error("Unknown private gesture pause case.")
		}
	} catch Any as Failure {
		Primary := Failure, HasPrimary := true
		_GPO_Observe("failure-before-cleanup")
	} finally {
		try _GPO_Cleanup()
		catch Any as Failure {
			if !HasPrimary
				Primary := Failure, HasPrimary := true
		}
		OnExit(_GPO_OnExit, 0)
	}
	if HasPrimary
		throw Primary
	_GPO.Finished := true
	_GPO_Receipt()
}

try {
	_GPO_Main()
	ExitApp(0)
} catch Any as Failure {
	Detail := Failure is Error ? Failure.Message . "`n" . Failure.Stack : "Non-Error failure of type " . Type(Failure)
	FileAppend("FAIL " . Detail, "**")
	ExitApp(1)
}
