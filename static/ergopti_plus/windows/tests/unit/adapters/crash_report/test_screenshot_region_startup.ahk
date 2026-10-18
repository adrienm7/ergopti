; tests/unit/adapters/crash_report/test_screenshot_region_startup.ahk

; ==============================================================================
; MODULE: Screenshot Region Startup Ownership Tests
; DESCRIPTION:
; Runs the real region entry and central clipboard restore coordinator with
; passive OS ports. A failed clear must not authorize restoration over a user
; copy, and a revoked startup must not publish or launch Snipping Tool.
; ==============================================================================

#Requires AutoHotkey v2.0

_GRS_Action(State, Boundary) {
	Action := State.Get(Boundary . "_action", 0)
	State[Boundary . "_action"] := 0
	if IsObject(Action)
		Action.Call()
}

_GRS_Save(State) {
	State["saves"] += 1
	_GRS_Action(State, "save")
	if State["save_error"]
		throw Error("clipboard snapshot unavailable")
	return State["save_sentinel"] ? "__CB_SAVE_ERROR__" : State["snapshot"]
}

_GRS_Clear(State) {
	State["clears"] += 1
	if !State["clear_failure"] {
		State["text"] := ""
		State["sequence"] := 42
	}
	_GRS_Action(State, "clear")
	return !State["clear_failure"]
}

_GRS_Sequence(State) {
	State["probes"] += 1
	Sequence := State["sequence"]
	_GRS_Action(State, "sequence")
	if State["probe_error"]
		throw Error("clipboard sequence unavailable")
	return Sequence
}

_GRS_Restore(State, Snapshot) {
	Debt := CBClipboardOwner.restore_debt
	State["restores"].Push(Map("snapshot", Snapshot, "expected", Debt["expected_sequence"],
		"token", Debt["owner_token"], "live", CBClipboardOwner.active.Has(Debt["owner_token"])))
	State["text"] := "original user clipboard"
	State["sequence"] += 1
	return true
}

_GRS_Notify(State, Ok, Reason) {
	State["callbacks"].Push(Map("ok", Ok, "reason", Reason))
	_GRS_Action(State, "callback")
}

_GRS_Start(State, Ports, Mode := "save") {
	global _GestureRegionCapture
	PreviousCritical := Critical("On")
	try {
		Result := GestureScreenshotRegion(Mode, _GRS_Notify.Bind(State),
			A_Temp . "\ergopti_region_startup_test.png", 0, Ports)
		if _GestureRegionCapture is Map {
			Capture := _GestureRegionCapture
			State["captures"].Push(Capture)
			Timer := Capture.Get("poll_timer", 0)
			if IsObject(Timer) {
				State["timers"].Push(Timer)
				SetTimer(Timer, 0)
			}
		}
		return Result
	} finally Critical(PreviousCritical)
}

_GRS_WithFixture(Fn) {
	global _GestureRegionCapture, _GestureRegionCaptureEpoch, _GestureDirectCaptures
	AssertFalse(IsObject(_GestureRegionCapture), "fixture requires no published region capture")
	AssertEqual(0, _GestureDirectCaptures.Count)
	AssertEqual(0, GestureScreenshotWorkerState.jobs.Count)
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
	Saved := { Region: _GestureRegionCapture, Epoch: _GestureRegionCaptureEpoch,
		Generation: CBClipboardOwner.generation, MutationId: CBClipboardOwner.mutation_id,
		Pending: CBClipboardOwner.pending, Observer: CBClipboardOwner.observer_active,
		Settle: CBClipboardOwner.settle_hook, Suspended: A_IsSuspended, Critical: A_IsCritical }
	State := Map("snapshot", { Formats: "opaque original formats" }, "sequence", 41,
		"text", "original user clipboard", "saves", 0, "clears", 0, "probes", 0,
		"sends", 0, "restores", [], "callbacks", [], "captures", [], "timers", [],
		"save_error", false, "save_sentinel", false, "clear_failure", false,
		"probe_error", false, "timer_ran", false, "timer_error", 0)
	Ports := Map("save", _GRS_Save.Bind(State), "clear", _GRS_Clear.Bind(State),
		"sequence", _GRS_Sequence.Bind(State), "restore", _GRS_Restore.Bind(State),
		"send", (*) => State["sends"] += 1)
	try {
		CBClipboardOwner.pending := []
		CBClipboardOwner.observer_active := false
		CBClipboardOwner.settle_hook := 0
		Suspend(false)
		Critical("Off")
		Fn.Call(State, Ports)
	} finally {
		for Boundary in ["save", "clear", "sequence", "callback"]
			State[Boundary . "_action"] := 0
		State["probe_error"] := false
		for Timer in State["timers"]
			SetTimer(Timer, 0)
		if _GestureRegionCapture is Map {
			Capture := _GestureRegionCapture
			_GestureRegionCapture := false
			if Capture.Get("expected_change", 0)
				CB_CancelExpectedChange(Capture["expected_change"])
			State["sequence"] := Capture["clipboard_sequence"]
			CB_RestoreOwnedAllEventually(Capture["original_clipboard"], Capture["clipboard_sequence"],
				Capture["owner_token"], "region startup fixture cleanup", true, true,
				Ports["restore"], Ports["sequence"])
		}
		if CBClipboardOwner.restore_debt is Map {
			State["sequence"] := CBClipboardOwner.restore_debt["expected_sequence"]
			CB_RetryRestoreDebt()
		}
		SetTimer(CB_RetryRestoreDebt, 0)
		for Capture in State["captures"] {
			Capture["callback"] := 0
			Capture["original_clipboard"] := ""
			Capture["poll_timer"] := 0
		}
		CBClipboardOwner.pending := Saved.Pending
		CBClipboardOwner.observer_active := Saved.Observer
		CBClipboardOwner.mutation_id := Saved.MutationId
		CBClipboardOwner.settle_hook := Saved.Settle
		CBClipboardOwner.generation := Saved.Generation
		_GestureRegionCapture := Saved.Region
		_GestureRegionCaptureEpoch := Saved.Epoch
		Suspend(Saved.Suspended)
		Critical(Saved.Critical)
	}
	AssertEqual(0, CBClipboardOwner.active.Count, "fixture must retire its exact startup owner")
	AssertFalse(CBClipboardOwner.restore_debt)
}

_GRS_AssertFailed(State) {
	global _GestureRegionCapture
	AssertFalse(IsObject(_GestureRegionCapture), "a failed startup must not publish a region")
	AssertEqual(0, State["sends"], "a failed startup cannot launch Snipping Tool")
	AssertEqual(1, State["callbacks"].Length, "the failed request receives one exact terminal")
	AssertFalse(State["callbacks"][1]["ok"])
}

_GRS_Foreign(State) {
	State["text"] := "new external user copy"
	State["sequence"] := 43
}

_GRS_NoMutation(Mode, State, Ports) {
	if Mode == "snapshot-error"
		State["save_error"] := true
	else if Mode == "snapshot-sentinel"
		State["save_sentinel"] := true
	else {
		State["clear_failure"] := true
		if Mode == "foreign-clear-failure"
			State["clear_action"] := _GRS_Foreign.Bind(State)
	}
	AssertFalse(_GRS_Start(State, Ports))
	_GRS_AssertFailed(State)
	AssertEqual(1, State["saves"])
	AssertEqual(InStr(Mode, "snapshot") ? 0 : 1, State["clears"])
	AssertEqual(0, State["restores"].Length, "without a successful clear there is no owned mutation to restore")
	AssertEqual(0, State["probes"], "failure cannot adopt a current user sequence as its own")
	AssertEqual(Mode == "foreign-clear-failure" ? "new external user copy" : "original user clipboard", State["text"])
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
}
for _GRS_Mode in ["snapshot-error", "snapshot-sentinel", "clear-failure", "foreign-clear-failure"]
	Test("region startup: " . _GRS_Mode . " preserves unmodified clipboard (region-startup-ownership)",
		_GRS_WithFixture.Bind(_GRS_NoMutation.Bind(_GRS_Mode)))

_GRS_Revoke(State, Action, Foreign := false) {
	if Foreign
		_GRS_Foreign(State)
	if Action == "pause"
		Suspend(true)
	else
		GestureScreenshotCancelAll("cancelled during region startup")
}

_GRS_Revoked(Boundary, Action, State, Ports) {
	State[Boundary . "_action"] := _GRS_Revoke.Bind(State, Action)
	AssertFalse(_GRS_Start(State, Ports))
	_GRS_AssertFailed(State)
	AssertEqual(Boundary == "save" ? 0 : 1, State["clears"], "revocation after snapshot must precede any clear")
	AssertEqual(Boundary == "save" ? 0 : 1, State["restores"].Length)
	if Boundary != "save" {
		Restore := State["restores"][1]
		AssertTrue(Restore["snapshot"] == State["snapshot"])
		AssertEqual(42, Restore["expected"], "a revoked startup retains its completed clear receipt")
		AssertTrue(Restore["live"], "the exact startup owner remains live through restoration")
	}
	AssertEqual("original user clipboard", State["text"])
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
}
for _GRS_Boundary in ["save", "clear", "sequence"]
	for _GRS_ActionName in ["pause", "cancel"]
		Test("region startup: " . _GRS_ActionName . " during " . _GRS_Boundary . " revokes launch (region-startup-ownership)",
			_GRS_WithFixture.Bind(_GRS_Revoked.Bind(_GRS_Boundary, _GRS_ActionName)))

_GRS_ForeignAfterReceipt(Action, State, Ports) {
	State["sequence_action"] := _GRS_Revoke.Bind(State, Action, true)
	AssertFalse(_GRS_Start(State, Ports))
	_GRS_AssertFailed(State)
	AssertEqual(0, State["restores"].Length, "retirement cannot rename a later foreign sequence as owned")
	AssertEqual("new external user copy", State["text"])
	AssertEqual(43, State["sequence"])
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
}
for _GRS_ForeignAction in ["pause", "cancel"]
	Test("region startup: " . _GRS_ForeignAction . " preserves copy after admitted clear (region-startup-ownership)",
		_GRS_WithFixture.Bind(_GRS_ForeignAfterReceipt.Bind(_GRS_ForeignAction)))

_GRS_Ordinary(State, Ports) {
	global _GestureRegionCapture, _GestureRegionCaptureEpoch
	AssertTrue(_GRS_Start(State, Ports))
	Capture := _GestureRegionCapture
	AssertTrue(Capture is Map)
	AssertEqual(_GestureRegionCaptureEpoch, Capture["epoch"])
	AssertEqual(42, Capture["clipboard_sequence"])
	AssertTrue(Capture["original_clipboard"] == State["snapshot"])
	AssertTrue(CBClipboardOwner.active.Has(Capture["owner_token"]))
	AssertEqual(1, State["saves"])
	AssertEqual(1, State["clears"])
	AssertEqual(1, State["sends"], "ordinary startup still launches the real entry's Snipping Tool port")
	AssertEqual(0, State["callbacks"].Length)
	AssertEqual(0, State["restores"].Length)
	AssertEqual(1, State["timers"].Length, "ordinary startup arms one real epoch-bound native callback")
}
Test("region startup: ordinary capture retains exact snapshot and owner (region-startup-ownership)",
	_GRS_WithFixture.Bind(_GRS_Ordinary))

_GRS_Unknown(State) {
	State["sequence"] := 0
	State["probe_error"] := true
}

_GRS_Recover(State) {
	try {
		State["probe_error"] := false
		State["sequence"] := 43
		State["text"] := "new external user copy"
		State["timer_ran"] := true
	} catch as Err {
		State["timer_error"] := Err
	}
}

_GRS_SequenceErrorDebt(State, Ports) {
	State["sequence_action"] := _GRS_Unknown.Bind(State)
	AssertFalse(_GRS_Start(State, Ports))
	_GRS_AssertFailed(State)
	AssertEqual(1, State["clears"])
	AssertEqual(0, State["restores"].Length)
	Debt := CBClipboardOwner.restore_debt
	AssertTrue(Debt is Map, "a successful clear with an unavailable probe retains real restore debt")
	AssertEqual(0, Debt["expected_sequence"])
	AssertTrue(Debt["force"], "the established unknown-sequence startup policy is preserved only after mutation")
	AssertTrue(Debt["saved"] == State["snapshot"])
	AssertTrue(CBClipboardOwner.active.Has(Debt["owner_token"]))
	AssertEqual(0, CB_TryBeginOwnedTransaction("must remain excluded"))
	Timer := _GRS_Recover.Bind(State)
	State["timers"].Push(Timer)
	SetTimer(Timer, -1)
	Started := A_TickCount
	while CBClipboardOwner.restore_debt && !IsObject(State["timer_error"]) && A_TickCount - Started < 2000
		Sleep(10)
	if IsObject(State["timer_error"])
		throw State["timer_error"]
	AssertTrue(State["timer_ran"], "the actual recovery timer must run")
	AssertFalse(CBClipboardOwner.restore_debt, "the real retry timer must yield to an observable user copy")
	AssertEqual(0, State["restores"].Length)
	AssertEqual("new external user copy", State["text"])
	AssertEqual(0, CBClipboardOwner.active.Count)
}
Test("region startup: unavailable sequence retains actual restore debt (region-startup-debt-timer)",
	_GRS_WithFixture.Bind(_GRS_SequenceErrorDebt))

_GRS_StartSuccessor(State, Ports) {
	global _GestureRegionCapture
	State["successor_started"] := _GRS_Start(State, Ports)
	State["successor"] := _GestureRegionCapture
	State["successor_owner"] := CBClipboardOwner.active[_GestureRegionCapture["owner_token"]]
}

_GRS_CallbackSuccessor(State, Ports) {
	global _GestureRegionCapture
	State["save_action"] := _GRS_Revoke.Bind(State, "cancel")
	State["callback_action"] := _GRS_StartSuccessor.Bind(State, Ports)
	AssertFalse(_GRS_Start(State, Ports))
	AssertTrue(State["successor_started"], "the failed startup releases its lease before notifying its caller")
	AssertTrue(_GestureRegionCapture == State["successor"], "old cleanup must preserve the callback's actual replacement capture")
	AssertTrue(CBClipboardOwner.active[_GestureRegionCapture["owner_token"]] == State["successor_owner"])
	AssertEqual(1, CBClipboardOwner.active.Count)
	AssertEqual(1, State["callbacks"].Length, "only the old failed request has completed")
	AssertEqual(1, State["sends"], "only the replacement capture may launch Snipping Tool")
	AssertEqual(0, State["restores"].Length)
}
Test("region startup: terminal callback may create an exact successor (region-startup-ownership)",
	_GRS_WithFixture.Bind(_GRS_CallbackSuccessor))

_GRS_ClearUnknown(State) {
	State["sequence"] := 0
	Suspend(true)
}

_GRS_UnknownMutation(State, Ports) {
	State["clear_action"] := _GRS_ClearUnknown.Bind(State)
	AssertFalse(_GRS_Start(State, Ports))
	_GRS_AssertFailed(State)
	AssertEqual(1, State["restores"].Length, "successful clear retains the existing forced unknown-sequence rollback policy")
	Restore := State["restores"][1]
	AssertEqual(0, Restore["expected"])
	AssertTrue(Restore["snapshot"] == State["snapshot"])
	AssertTrue(Restore["live"])
	AssertEqual("original user clipboard", State["text"])
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
}
Test("region startup: only a successful clear permits unknown-sequence rollback (region-startup-ownership)",
	_GRS_WithFixture.Bind(_GRS_UnknownMutation))

_GRS_Busy(State, Ports) {
	Token := CB_TryBeginOwnedTransaction("incumbent clipboard producer")
	Record := CBClipboardOwner.active[Token]
	try {
		AssertFalse(_GRS_Start(State, Ports))
		_GRS_AssertFailed(State)
		AssertEqual(0, State["saves"])
		AssertEqual(0, State["clears"])
		AssertEqual(0, State["probes"])
		AssertEqual(0, State["restores"].Length)
		AssertEqual(1, CBClipboardOwner.active.Count)
		AssertTrue(CBClipboardOwner.active[Token] == Record, "refusal must preserve the actual incumbent owner identity")
	} finally CB_EndOwnedTransaction(Token)
}
Test("region startup: busy refusal preserves the incumbent owner (region-startup-ownership)",
	_GRS_WithFixture.Bind(_GRS_Busy))

_GRS_ClipboardOrdinary(State, Ports) {
	global _GestureRegionCapture
	AssertTrue(_GRS_Start(State, Ports, "clipboard"))
	AssertEqual(1, State["sends"], "ordinary clipboard mode still invokes its native-command port")
	AssertEqual(0, State["saves"])
	AssertEqual(0, State["clears"])
	AssertEqual(0, State["restores"].Length)
	AssertEqual(0, State["callbacks"].Length)
	AssertFalse(IsObject(_GestureRegionCapture))
	AssertEqual(0, CBClipboardOwner.active.Count)
}
Test("region startup: ordinary clipboard mode preserves its launch contract (region-startup-ownership)",
	_GRS_WithFixture.Bind(_GRS_ClipboardOrdinary))

_GRS_ClipboardSuperseded(State, Ports) {
	global _GestureRegionCapture
	Old := _GSWO_Install()
	PreviousCritical := Critical("On")
	try {
		AssertTrue(GestureCaptureRegion(0, 0, 20, 20, "save",
			A_Temp . "\region_startup_old_direct.png", (*) => _GRS_StartSuccessor(State, Ports)))
		AssertFalse(_GRS_Start(State, Ports, "clipboard"),
			"the original clipboard request must stop when cancellation completion creates a newer capture")
		AssertTrue(State["successor_started"])
		AssertTrue(_GestureRegionCapture == State["successor"])
		AssertTrue(CBClipboardOwner.active[_GestureRegionCapture["owner_token"]] == State["successor_owner"])
		AssertEqual(1, State["sends"], "only the newer save request may launch Snipping Tool")
		AssertEqual(1, State["saves"])
		AssertEqual(1, CBClipboardOwner.active.Count)
		AssertEqual(0, State["callbacks"].Length, "the current save capture has not finished")
	} finally {
		if _GestureRegionCapture is Map {
			Capture := _GestureRegionCapture
			_GestureRegionCapture := false
			CB_CancelExpectedChange(Capture["expected_change"])
			CB_RestoreOwnedAllEventually(Capture["original_clipboard"], Capture["clipboard_sequence"],
				Capture["owner_token"], "region clipboard fixture cleanup", true, true,
				Ports["restore"], Ports["sequence"])
		}
		_GSWO_Restore(Old)
		Critical(PreviousCritical)
	}
}
Test("region startup: reentrant completion supersedes the old clipboard launch (region-startup-ownership)",
	_GRS_WithFixture.Bind(_GRS_ClipboardSuperseded))
