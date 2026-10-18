; tests/unit/modules/gestures/test_gesture_paste_admission.ahk

; ==============================================================================
; MODULE: Catalogue Paste Clipboard Admission Tests
; DESCRIPTION:
; Exercise the real catalogue, gesture, keyboard-slot and tap dispatch paths
; while another producer owns a temporary clipboard payload. Only the final OS
; send and held-modifier query are passive; admission and native timers are real.
; ==============================================================================

#Requires AutoHotkey v2.0

_GPA_RecordSend(State, Keys) {
	State.Sent.Push(Keys)
	State.Owners.Push(CBClipboardOwner.active.Clone())
	State.DriverPaste.Push(CB_IsDriverPasteActive())
	State.Provenance.Push(TapHoldTapInDispatch())
	return true
}

_GPA_Invoke(Route) {
	global GESTURE_ACTIONS
	switch Route {
		case "catalogue": return GESTURE_ACTIONS["paste"].Fn.Call()
		case "gesture": return GestureDispatch("tap_3")
		case "keyboard": return RunKeyboardShortcutAction("__paste_fixture")
		case "tap": return _TapHoldFireAction("left_ctrl")
		default: throw ValueError("Unknown paste fixture route.")
	}
}

_GPA_WithFixture(Fn, Held := false) {
	global _AHK_SendInput, _TapHoldModifierIsHeld, TapHold, _TH_TapHoldTrackState
	global _TH_PressesTakenByCombination, _TH_LastTapHoldCancelReason, _TapHoldTapInDispatch
	global GestureAssignments, KeyboardShortcutAssignments, Features
	global GestureLeftClickHeld, GestureRightClickHeld, GestureKeyboardHook
	AssertEqual(0, CBClipboardOwner.active.Count, "fixture requires an idle clipboard owner")
	AssertFalse(CBClipboardOwner.restore_debt, "fixture requires no pending restoration")
	; The unit runner omits feature_state, which owns this production global.
	; Own the fixture map only during dispatch and preserve true prior absence.
	SavedKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	Saved := { Send: _AHK_SendInput, Held: _TapHoldModifierIsHeld, Tap: TapHold,
		Track: _TH_TapHoldTrackState, Combinations: _TH_PressesTakenByCombination,
		Reason: _TH_LastTapHoldCancelReason, Dispatch: _TapHoldTapInDispatch,
		Gestures: GestureAssignments,
		Enabled: Features["gestures"]["enabled"], Left: GestureLeftClickHeld,
		Right: GestureRightClickHeld, Hook: GestureKeyboardHook,
		Suspended: A_IsSuspended, Critical: A_IsCritical }
	State := { Sent: [], Owners: [], DriverPaste: [], Provenance: [], Token: 0,
		Dispatched: false, Restores: 0, Error: 0 }
	_AHK_SendInput := _GPA_RecordSend.Bind(State)
	_TapHoldModifierIsHeld := (Name) => Held && Name == "LShift"
	TapHold := Map("keys", Map("left_ctrl", Map("tap_action", "paste",
		"time_activation_seconds", 0.2)), "layers", Map())
	_TH_TapHoldTrackState := Map()
	_TH_PressesTakenByCombination := Map()
	_TapHoldTapInDispatch := ""
	GestureAssignments := Map("tap_3", "paste")
	KeyboardShortcutAssignments := Map("__paste_fixture", "paste")
	Features["gestures"]["enabled"] := true
	GestureLeftClickHeld := false
	GestureRightClickHeld := false
	GestureKeyboardHook := 0
	try {
		Suspend(false)
		Critical("Off")
		Fn.Call(State)
	} finally {
		if State.Token
			CB_EndOwnedTransaction(State.Token)
		_AHK_SendInput := Saved.Send
		_TapHoldModifierIsHeld := Saved.Held
		TapHold := Saved.Tap
		_TH_TapHoldTrackState := Saved.Track
		_TH_PressesTakenByCombination := Saved.Combinations
		_TH_LastTapHoldCancelReason := Saved.Reason
		_TapHoldTapInDispatch := Saved.Dispatch
		GestureAssignments := Saved.Gestures
		KeyboardShortcutAssignments := IsSet(SavedKeyboard) ? SavedKeyboard : unset
		Features["gestures"]["enabled"] := Saved.Enabled
		GestureLeftClickHeld := Saved.Left
		GestureRightClickHeld := Saved.Right
		GestureKeyboardHook := Saved.Hook
		Suspend(Saved.Suspended)
		Critical(Saved.Critical)
	}
	AssertEqual(IsSet(SavedKeyboard), IsSet(KeyboardShortcutAssignments),
		"fixture teardown must preserve the assignment global's true absence")
	if IsSet(SavedKeyboard)
		AssertTrue(KeyboardShortcutAssignments == SavedKeyboard,
			"fixture teardown must restore the exact prior assignment map")
}

_GPA_Busy(Route, State) {
	State.Token := CB_TryBeginOwnedTransaction("temporary clipboard producer", true)
	AssertTrue(State.Token > 0)
	Record := CBClipboardOwner.active[State.Token]
	_GPA_Invoke(Route)
	AssertEqual(0, State.Sent.Length, "busy paste must not emit the other producer's temporary payload")
	AssertEqual(1, CBClipboardOwner.active.Count)
	AssertTrue(CBClipboardOwner.active[State.Token] == Record, "refusal preserves the exact incumbent")
}

_GPA_Normal(Route, State) {
	global GESTURE_ACTIONS
	Entry := GESTURE_ACTIONS["paste"]
	AssertEqual("v", Entry.Key, "paste retains its key metadata for the tap fast path")
	AssertEqual("Ctrl", Entry.Mods[1])
	_GPA_Invoke(Route)
	AssertEqual(1, State.Sent.Length, "an idle clipboard still permits one ordinary paste")
	AssertEqual("^{v}", State.Sent[1])
	AssertEqual(1, State.Owners[1].Count, "admission remains live through the actual send")
	for Token, Owner in State.Owners[1] {
		AssertEqual("gesture_paste", Owner["source"])
		AssertFalse(Owner["suppress_paste"], "a requested paste keeps user-paste observation")
	}
	AssertFalse(State.DriverPaste[1])
	AssertEqual(Route == "tap" ? "left_ctrl" : "", State.Provenance[1])
	AssertEqual(0, CBClipboardOwner.active.Count, "the exact short-lived lease releases after sending")
}

for _GPA_Route in ["catalogue", "gesture", "keyboard", "tap"] {
	Test("paste admission: " . _GPA_Route . " refuses a temporary clipboard owner (catalogue-paste-admission)",
		_GPA_WithFixture.Bind(_GPA_Busy.Bind(_GPA_Route)))
	Test("paste admission: " . _GPA_Route . " retains ordinary paste and metadata (catalogue-paste-admission)",
		_GPA_WithFixture.Bind(_GPA_Normal.Bind(_GPA_Route)))
}

_GPA_HeldTap(State) {
	_GPA_Invoke("tap")
	AssertEqual(1, State.Sent.Length)
	AssertEqual("{Blind}^{v}", State.Sent[1], "the guarded tap must retain inherited modifiers")
	AssertEqual("left_ctrl", State.Provenance[1], "the send still belongs to the same tap dispatch")
	AssertEqual(1, State.Owners[1].Count)
	AssertEqual(0, CBClipboardOwner.active.Count)
}
Test("paste admission: tap preserves Blind and provenance (catalogue-paste-admission)",
	_GPA_WithFixture.Bind(_GPA_HeldTap, true))

_GPA_TimerDispatch(State, Route) {
	try {
		AssertTrue(CBClipboardOwner.active.Has(State.Token), "dispatch must occur before exact-owner restoration")
		_GPA_Invoke(Route)
		State.Dispatched := true
	} catch as Err {
		State.Error := Err
	}
}

_GPA_Restore(State, Saved) {
	try {
		AssertTrue(Saved == State.Snapshot, "native timer must restore the original opaque snapshot")
		AssertTrue(CBClipboardOwner.active.Has(State.Token), "the exact owner stays live through restoration")
	} catch as Err {
		State.Error := Err
	}
	State.Restores += 1
	return true
}

_GPA_TimerWindow(Route, State) {
	global SEND_INSTANT_PASTE_DELAY_MS
	State.Token := CB_TryBeginOwnedTransaction("deferred clipboard payload", true)
	AssertTrue(State.Token > 0)
	State.Snapshot := { Original: "opaque user formats" }
	DispatchTimer := _GPA_TimerDispatch.Bind(State, Route)
	RestoreTimer := CB_RestoreOwnedAllEventually.Bind(State.Snapshot, 42, State.Token,
		"paste admission fixture", true, false, _GPA_Restore.Bind(State), () => 42)
	try {
		; Create dispatch first so even an overloaded runner receives this owned
		; ordering. Both callbacks are real native timers and use production routes.
		TimerCritical := Critical("On")
		try {
			SetTimer(DispatchTimer, -1)
			SetTimer(RestoreTimer, -SEND_INSTANT_PASTE_DELAY_MS)
		} finally Critical(TimerCritical)
		Started := A_TickCount
		while (!State.Dispatched || !State.Restores) && A_TickCount - Started < 3000
			Sleep(10)
		if IsObject(State.Error)
			throw State.Error
		AssertTrue(State.Dispatched, "the native dispatch timer must actually fire")
		AssertEqual(1, State.Restores, "the native restoration timer must actually settle")
		AssertEqual(0, State.Sent.Length, "paste during the restore window must emit nothing")
		AssertEqual(0, CBClipboardOwner.active.Count)
		AssertFalse(CBClipboardOwner.restore_debt)
		_GPA_Invoke(Route)
		AssertEqual(1, State.Sent.Length, "the same route works after the real owner retires")
	} finally {
		SetTimer(DispatchTimer, 0)
		SetTimer(RestoreTimer, 0)
	}
}
for _GPA_TimerRoute in ["gesture", "tap"]
	Test("paste admission: " . _GPA_TimerRoute . " cannot paste during native deferred restoration (catalogue-paste-timer-window)",
		_GPA_WithFixture.Bind(_GPA_TimerWindow.Bind(_GPA_TimerRoute)))

_GPA_DirectKeyStillWorks(State) {
	State.Token := CB_TryBeginOwnedTransaction("temporary clipboard producer", true)
	AssertTrue(State.Token > 0)
	AssertTrue(TextPressKey("v", ["Ctrl"]), "the generic key adapter keeps its literal-key contract")
	AssertEqual(1, State.Sent.Length, "admission must target the catalogue action, not every Ctrl+V emitter")
	AssertTrue(CBClipboardOwner.active.Has(State.Token))
}
Test("paste admission: generic key output remains independent (catalogue-paste-admission)",
	_GPA_WithFixture.Bind(_GPA_DirectKeyStillWorks))

_GPA_ThrowWhileOwned(State) {
	AssertEqual(1, CBClipboardOwner.active.Count)
	throw State.ExpectedError
}

_GPA_ExceptionReleases(State) {
	State.ExpectedError := Error("paste emission boundary failed")
	Caught := 0
	try _GestureWithPasteAdmission(_GPA_ThrowWhileOwned.Bind(State))
	catch as Err
		Caught := Err
	AssertTrue(Caught == State.ExpectedError, "the exact send failure must survive cleanup")
	AssertEqual(0, CBClipboardOwner.active.Count, "an exception must release the exact lease")
}
Test("paste admission: emission failure releases its exact owner (catalogue-paste-admission)",
	_GPA_WithFixture.Bind(_GPA_ExceptionReleases))
