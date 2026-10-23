; tests/fixtures/gesture_keywatcher_owner_body.ahk

; The actual owner above retains native InputHook construction/Start. Mouse
; transport alone is passive; the Stop observer delegates the real native call.
; Invoking its saved OnKeyDown property is controlled delivery, not a queued
; native AHK_INPUT_KEYDOWN witness. Critical keeps unrelated native callbacks
; outside the acquisition/assertion sequence; every exact hook retires below.
; Suspend cases exercise the genuine watcher branch, not the complete
; Ergopti_OnSuspendEnter reactor or a real OS Button Up refusal.
global _GKO := { Mode: A_Args[1], Hooks: [], Events: [], Stops: [], NativeHeld: Map("Left", false, "Right", false),
	RefuseUp: "", Refused: 0, OwnerA: 0, OwnerB: 0, CallbackA: 0, CallbackB: 0, Logs: [] }

_GKO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_GKO_Log(Line) {
	global _GKO
	if _GKO.Logs.Length < 100
		_GKO.Logs.Push(Line)
}

_GKO_Click(Button, Direction) {
	global _GKO
	_GKO_Require(_GKO.NativeHeld.Has(Button) && (Direction == "Down" || Direction == "Up"), "only the actual button transport may reach the observer")
	Refused := Direction == "Up" && _GKO.RefuseUp == Button
	_GKO.Events.Push(Map("button", Button, "direction", Direction, "refused", Refused))
	if Refused {
		_GKO.Refused += 1
		throw Error("The passive native Button Up boundary refused the release.")
	}
	_GKO.NativeHeld[Button] := Direction == "Down"
}

_GKO_Stop(Hook) {
	global _GKO
	_GKO.Stops.Push(ObjPtr(Hook))
	Hook.Stop()
}

_GKO_Snapshot(Phase) {
	global _GKO, GestureKeyboardHook, GestureLeftClickHeld, GestureRightClickHeld
	return Map("phase", Phase, "mode", _GKO.Mode, "left_held", GestureLeftClickHeld,
		"right_held", GestureRightClickHeld, "current", IsObject(GestureKeyboardHook) ? ObjPtr(GestureKeyboardHook) : 0,
		"a", IsObject(_GKO.OwnerA) ? ObjPtr(_GKO.OwnerA) : 0,
		"b", IsObject(_GKO.OwnerB) ? ObjPtr(_GKO.OwnerB) : 0,
		"b_in_progress", IsObject(_GKO.OwnerB) ? _GKO.OwnerB.InProgress : false,
		"stops", _GKO.Stops.Clone(), "events", _GKO.Events.Clone(), "suspended", A_IsSuspended,
		"native_left_model", _GKO.NativeHeld["Left"], "native_right_model", _GKO.NativeHeld["Right"], "logs", _GKO.Logs.Clone())
}

_GKO_Observe(Phase) {
	FileAppend("OBSERVATION " . KL_JsonEncode(_GKO_Snapshot(Phase)) . "`n", "*")
}

_GKO_Acquire(Button) {
	global _GKO, GestureKeyboardHook
	_GKO_Observe("native-acquisition-prerequisite-" . Button)
	Accepted := Button == "Left" ? GestureToggleLeftClick() : GestureToggleRightClick()
	_GKO_Require(Accepted, "the actual hold acquisition must succeed before callback assertions")
	Hook := GestureKeyboardHook
	_GKO_Require(Hook is InputHook && Hook.InProgress, "the owner must really start its native InputHook")
	_GKO.Hooks.Push(Hook)
	return Hook
}

_GKO_Subscriptions(Count) {
	for Event in ["mouse_ldown", "mouse_rdown"]
		_GKO_Require(HookDispatcher._subscribers.Has(Event) && HookDispatcher._subscribers[Event].Length == Count,
			"the actual dispatcher must retain the exact number of recovery subscribers: " . Event)
}

_GKO_Released() {
	global _GKO, GestureKeyboardHook, GestureLeftClickHeld, GestureRightClickHeld
	_GKO_Require(!GestureLeftClickHeld && !GestureRightClickHeld, "both real held flags must settle after accepted Up")
	_GKO_Require(!_GKO.NativeHeld["Left"] && !_GKO.NativeHeld["Right"], "the passive mouse transport must acknowledge every outstanding Up")
	_GKO_Require(GestureKeyboardHook == 0, "the exact current watcher must retire only after release")
	_GKO_Subscriptions(0)
	for Hook in _GKO.Hooks
		_GKO_Require(!Hook.InProgress, "every actual InputHook must be stopped before the receipt")
}

_GKO_Replacement() {
	global _GKO, GestureKeyboardHook, GestureLeftClickHeld, GestureRightClickHeld
	First := InStr(_GKO.Mode, "left-right", true) ? "Left" : "Right"
	Second := First == "Left" ? "Right" : "Left"
	_GKO.OwnerA := _GKO_Acquire(First)
	_GKO.CallbackA := _GKO.OwnerA.OnKeyDown
	_GKO_Require(_GKO.CallbackA is Func, "the original owner's actual callback must be retained before replacement")
	_GKO.OwnerB := _GKO_Acquire(Second)
	_GKO.CallbackB := _GKO.OwnerB.OnKeyDown
	_GKO_Require(_GKO.OwnerA != _GKO.OwnerB && GestureKeyboardHook == _GKO.OwnerB, "the actual second acquisition must publish a distinct replacement")
	_GKO_Require(!_GKO.OwnerA.InProgress && _GKO.OwnerB.InProgress, "native replacement must stop A and start B")
	_GKO_Require(_GKO.Stops.Length == 1 && _GKO.Stops[1] == ObjPtr(_GKO.OwnerA), "the real replacement must Stop only A")
	_GKO_Require(GestureLeftClickHeld && GestureRightClickHeld && _GKO.Events.Length == 2,
		"both independent accepted Downs must precede controlled callback delivery")
	_GKO_Subscriptions(2)
	_GKO_Observe("replacement-admitted")
	if InStr(_GKO.Mode, "retired-", true) == 1 {
		_GKO.CallbackA.Call(_GKO.OwnerA, 0x41, 0x1E)
		_GKO_Observe("retired-callback-returned")
		_GKO_Require(GestureKeyboardHook == _GKO.OwnerB && _GKO.OwnerB.InProgress,
			"the retired callback must preserve the exact active replacement B")
		_GKO_Require(GestureLeftClickHeld && GestureRightClickHeld && _GKO.Events.Length == 2,
			"the retired callback must emit no Up and preserve both replacement holds")
		_GKO_Require(_GKO.Stops.Length == 1, "the retired callback must not attempt native Stop on B")
		_GKO_Subscriptions(2)
	}
	_GKO.CallbackB.Call(_GKO.OwnerB, 0x41, 0x1E)
	_GKO_Observe("current-callback-returned")
	_GKO_Released()
	_GKO_Require(_GKO.Events.Length == 4 && _GKO.Events[3]["button"] == "Left" && _GKO.Events[3]["direction"] == "Up"
		&& _GKO.Events[4]["button"] == "Right" && _GKO.Events[4]["direction"] == "Up",
		"the current callback must follow the actual two-button release path")
	_GKO_Require(_GKO.Stops.Length == 2 && _GKO.Stops[2] == ObjPtr(_GKO.OwnerB), "only current B may finish its native Stop")
}

_GKO_PausedRefusal() {
	global _GKO, GestureKeyboardHook, GestureLeftClickHeld, GestureRightClickHeld
	Button := InStr(_GKO.Mode, "paused-left", true) == 1 ? "Left" : "Right"
	_GKO.OwnerB := _GKO_Acquire(Button)
	_GKO.CallbackB := _GKO.OwnerB.OnKeyDown
	_GKO.RefuseUp := Button
	Suspend(true)
	_GKO_Require(A_IsSuspended, "the actual suspended branch must be admitted")
	_GKO.CallbackB.Call(_GKO.OwnerB, 0x41, 0x1E)
	_GKO_Observe("paused-up-refused")
	_GKO_Require(_GKO.Refused == 1 && _GKO.Events.Length == 2, "the paused callback must actually attempt the modeled native Up")
	_GKO_Require(GestureKeyboardHook == _GKO.OwnerB && _GKO.OwnerB.InProgress && _GKO.Stops.Length == 0,
		"a refused paused release must retain its exact native watcher and attempt no Stop")
	_GKO_Require((Button == "Left" ? GestureLeftClickHeld : GestureRightClickHeld) && _GKO.NativeHeld[Button],
		"a refused release must preserve the matching held flag and modeled native debt")
	_GKO_Subscriptions(1)
	_GKO.RefuseUp := ""
	_GKO.CallbackB.Call(_GKO.OwnerB, 0x41, 0x1E)
	_GKO_Observe("paused-current-retry-returned")
	_GKO_Released()
	_GKO_Require(A_IsSuspended && _GKO.Events.Length == 3 && _GKO.Stops.Length == 1
		&& _GKO.Stops[1] == ObjPtr(_GKO.OwnerB), "retry while still paused must discharge only its own debt")
}

_GKO_Main() {
	global _GKO, _GKO_ActualOwnerHash
	_GKO_Require(A_Args.Length == 4, "the exact child ABI must be retained")
	_GKO_Require(A_Args[2] == _GKO_ActualOwnerHash, "the bound production owner hash must match the parent")
	_GKO_Require(CryptoSha256Bytes(FileRead(A_ScriptFullPath, "RAW")) == A_Args[3], "the actual child source must match its provenance")
	_GKO_Require(CryptoSha256Bytes(FileRead(A_AhkPath, "RAW")) == A_Args[4], "the actual native runtime must match its provenance")
	SavedCritical := Critical("On"), SavedSuspended := A_IsSuspended
	Primary := 0, Cleanup := 0, HasPrimary := false, HasCleanup := false
	LoggerSetTestSink(_GKO_Log)
	try {
		Suspend(false)
		if InStr(_GKO.Mode, "paused-", true) == 1
			_GKO_PausedRefusal()
		else
			_GKO_Replacement()
	} catch Any as Failure {
		Primary := Failure, HasPrimary := true
		_GKO_Observe("failure-before-cleanup")
	} finally {
		try {
			_GKO.RefuseUp := ""
			_GKO_Require(GestureReleaseLeftClick(), "private left transport cleanup must settle")
			_GKO_Require(GestureReleaseRightClick(), "private right transport cleanup must settle")
			for Hook in _GKO.Hooks
				Hook.Stop()
			_GKO_Released()
		} catch Any as Failure {
			Cleanup := Failure, HasCleanup := true
		} finally {
			LoggerClearTestSink()
			Suspend(SavedSuspended)
			Critical(SavedCritical)
		}
	}
	if HasPrimary
		throw Primary
	if HasCleanup
		throw Cleanup
	FileAppend("RECEIPT " . KL_JsonEncode(Map("pid", DllCall("GetCurrentProcessId", "UInt"), "mode", _GKO.Mode,
		"source_sha256", A_Args[3], "runtime_sha256", A_Args[4], "click_owner_sha256", _GKO_ActualOwnerHash,
		"callback_delivery", "controlled", "mouse_injected", false, "hooks_retired", true,
		"subscriptions_retired", true, "suspended", A_IsSuspended)) . "`n", "*")
}

try {
	_GKO_Main()
	ExitApp(0)
} catch Any as Failure {
	Detail := Failure is Error ? Failure.Message . "`n" . Failure.Stack : "Non-Error failure of type " . Type(Failure)
	FileAppend("FAIL " . Detail, "**")
	ExitApp(1)
}
