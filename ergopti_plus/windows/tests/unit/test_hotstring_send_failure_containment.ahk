; tests/unit/test_hotstring_send_failure_containment.ahk

; ============================================================================== 
; MODULE: Hotstring Send Failure Containment Tests
; DESCRIPTION:
; The shared SendNewResult/SendFinalResult primitives run on keyboard-facing
; paths.  A failed sender must not escape the callback, and SendNewResult must
; not mutate the last-sent ring as if its output reached the application.
; ============================================================================== 

#Requires AutoHotkey v2.0

_HSFC_FailingSendHook(*) {
    throw Error("injected hotstring send failure")
}

_HSFC_SendFailuresDoNotEscapeOrAdvanceRing() {
    global _SendHook
    PreviousHook := _SendHook
    try {
        _SendHook := _HSFC_FailingSendHook
        Before := GetLastSentCharacterAt(-1)
        AssertEqual(false, SendNewResult("Q"),
            "SendNewResult must return false when its send primitive throws")
        AssertEqual(Before, GetLastSentCharacterAt(-1),
            "failed SendNewResult must not advance the last-sent ring")
        AssertEqual(false, SendFinalResult("Q"),
            "SendFinalResult must return false instead of propagating a send failure")
    } finally {
        _SendHook := PreviousHook
    }
}
Test("hotstrings: failed common send primitives are contained and do not corrupt output state",
    _HSFC_SendFailuresDoNotEscapeOrAdvanceRing)

; A restore may yield after the capture job retires. Use the real restore-debt
; owner with recording assignment/sequence ports; no real clipboard or input.
_SCFC_Transition(State, Action) {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	switch Action {
		case "cancel": GetSelectionCancel()
		case "new", "failed new":
			; The public admission increments its canonical id before acquisition.
			; A refused acquisition still supersedes the previous continuation.
			_SelectionCaptureNextId += 1
			if Action == "new"
				_SelectionCaptureJob := Map("id", _SelectionCaptureNextId)
		case "pause": Suspend(true)
	}
}

_SCFC_Restore(State, Saved) {
	State["restores"] += 1
	AssertEqual("owned snapshot", Saved)
	AssertTrue(CBClipboardOwner.restore_debt is Map,
		"the recording must execute inside the actual clipboard restore owner")
	_SCFC_Transition(State, State["restore_action"])
	return true
}

_SCFC_Context(State, Job) {
	State["contexts"] += 1
	_SCFC_Transition(State, State["context_action"])
	return Map("foreground", State["foreground"],
		"elapsed", TickElapsed(Job["started"], State["now"]),
		"idle", State["idle"])
}

_SCFC_Deliver(State, Text) {
	State["deliveries"] += 1
	State["delivery_debt"] := CBClipboardOwner.restore_debt
	State["delivery_active"] := CBClipboardOwner.active.Count
	State["delivered"] := Text
}

_SCFC_AfterRestore(CaseName, Expected, RestoreAction := "none",
		ContextAction := "none", Foreground := 101, Started := 100,
		Now := 200, Idle := 100, Deliver := true, Reason := "ready") {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	AssertFalse(IsObject(_SelectionCaptureJob), "fixture requires no live capture")
	AssertEqual(0, CBClipboardOwner.active.Count,
		"fixture refuses to acquire over an existing clipboard owner")
	AssertFalse(CBClipboardOwner.restore_debt)
	PreviousJob := _SelectionCaptureJob
	PreviousId := _SelectionCaptureNextId
	PreviousGeneration := CBClipboardOwner.generation
	PreviousSuspended := A_IsSuspended
	PreviousSettle := CBClipboardOwner.settle_hook
	Token := 0
	Job := 0
	try {
		CBClipboardOwner.settle_hook := 0
		State := Map("restore_action", RestoreAction, "context_action", ContextAction,
			"foreground", Foreground, "now", Now, "idle", Idle,
			"restores", 0, "contexts", 0, "deliveries", 0, "delivered", "")
		Token := CB_TryBeginOwnedTransaction("selection_capture")
		AssertTrue(Token > 0)
		Job := Map("id", ++_SelectionCaptureNextId,
			"callback", _SCFC_Deliver.Bind(State), "started", Started,
			"foreground", 101, "clipboard", "owned snapshot", "clear_sequence", 100,
			"owner_token", Token, "expected_change", 0, "timer", (*) => 0)
		_SelectionCaptureJob := Job
		Sequence := () => 101
		_SelectionCaptureFinish(Job, "captured text", Deliver, Reason,
			_SCFC_Restore.Bind(State), Sequence, _SCFC_Context.Bind(State))
		AssertEqual(Expected, State["deliveries"], CaseName)
		if Expected {
			AssertEqual("captured text", State["delivered"])
			AssertFalse(State["delivery_debt"],
				"delivery must observe the actual restoration settled")
			AssertEqual(0, State["delivery_active"])
		}
		AssertEqual("", Job["clipboard"], "snapshot reference must retire")
		AssertFalse(CBClipboardOwner.restore_debt)
		AssertEqual(0, CBClipboardOwner.active.Count)
		if Reason == "superseded by input"
			AssertEqual(0, State["restores"], "newer physical copy must be preserved")
		else
			AssertEqual(1, State["restores"], "actual restoration must have executed")
		if RestoreAction == "new" or ContextAction == "new"
			AssertEqual(_SelectionCaptureNextId, _SelectionCaptureJob["id"],
				"old completion must leave the newer published job intact")
		; Replay a retired timer after terminal completion: no restore or callback.
		Restores := State["restores"]
		_SelectionCaptureFinish(Job, "captured text", Deliver, Reason,
			_SCFC_Restore.Bind(State), Sequence, _SCFC_Context.Bind(State))
		AssertEqual(Expected, State["deliveries"], "stale completion must not redeliver")
		AssertEqual(Restores, State["restores"], "stale completion must not restore")
	} finally {
		if IsObject(Job)
			SetTimer(Job["timer"], 0)
		SetTimer(CB_RetryRestoreDebt, 0)
		; Only this fixture's exact owned token may be retired on assertion failure.
		if Token and CBClipboardOwner.active.Has(Token)
			CB_EndOwnedTransaction(Token)
		if (CBClipboardOwner.restore_debt is Map)
				and CBClipboardOwner.restore_debt["owner_token"] == Token
			CBClipboardOwner.restore_debt := 0
		CBClipboardOwner.settle_hook := PreviousSettle
		CBClipboardOwner.generation := PreviousGeneration
		_SelectionCaptureJob := PreviousJob
		_SelectionCaptureNextId := PreviousId
		Suspend(PreviousSuspended)
	}
}

for Vector in [
	["normal", 1],
	["input before grace", 1, "none", "none", 101, 100, 200, 81],
	["input at grace", 1, "none", "none", 101, 100, 200, 80],
	["input after grace", 0, "none", "none", 101, 100, 200, 79],
	["input wrap at grace", 1, "none", "none", 101, 0xFFFFFFF0, 0x10, 12],
	["input wrap after grace", 0, "none", "none", 101, 0xFFFFFFF0, 0x10, 11],
	["foreground replaced", 0, "none", "none", 202],
	["foreground unavailable", 0, "none", "none", 0],
	["cancel during restoration", 0, "cancel"],
	["new capture during restoration", 0, "new"],
	["refused newer capture during restoration", 0, "failed new"],
	["cancel during context query", 0, "none", "cancel"],
	["new capture during context query", 0, "none", "new"],
	["pause during context query", 0, "none", "pause"],
	["cancelled completion", 0, "none", "none", 101, 100, 200, 100, false, "cancelled"],
	["physical copy cancellation", 0, "none", "none", 101, 100, 200, 100, false, "superseded by input"]
] {
	Test("hotstrings: selection finish " . Vector[1] . " (selection-restore-revalidation)",
		_SCFC_AfterRestore.Bind(Vector*))
}
