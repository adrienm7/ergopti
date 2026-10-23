; tests/unit/modules/hotstrings/engine/test_selection_admitted_clipboard_sequence.ahk

; ==============================================================================
; MODULE: Selection Admitted Clipboard Sequence Tests
; DESCRIPTION:
; Real capture jobs and the central restore owner must retain the sequence they
; admitted, instead of authorizing a later user copy sampled during retirement.
; Only clipboard, context and copy-command OS boundaries are passive ports.
; ==============================================================================

#Requires AutoHotkey v2.0

_SCAS_Save(State) {
	return State["snapshot"]
}

_SCAS_Clear(State) {
	State["text"] := ""
	State["sequence"] := 42
	return true
}

_SCAS_Sequence(State) {
	State["probes"] += 1
	Action := State["sequence_action"]
	State["sequence_action"] := 0
	if IsObject(Action)
		Action.Call()
	if State["probe_error"]
		throw Error("selection sequence probe unavailable")
	return State["sequence"]
}

_SCAS_Read(State) {
	State["reads"] += 1
	Action := State["read_action"]
	State["read_action"] := 0
	if State["foreign_before_read"] {
		if IsObject(Action)
			Action.Call()
		Text := State["text"]
	} else {
		Text := State["text"]
		if IsObject(Action)
			Action.Call()
	}
	State["read_values"].Push(Text)
	if State["read_error"]
		throw Error("clipboard getter failed")
	return Text
}

_SCAS_Restore(State, Saved) {
	Debt := CBClipboardOwner.restore_debt
	State["restores"].Push(Map("saved", Saved, "expected", Debt["expected_sequence"],
		"token", Debt["owner_token"], "live", CBClipboardOwner.active.Has(Debt["owner_token"])))
	State["text"] := "original user clipboard"
	State["sequence"] += 1
	return true
}

_SCAS_Deliver(State, Text) {
	State["delivered"].Push(Text)
}

_SCAS_Begin(State, Ports) {
	global _SelectionCaptureJob
	PreviousCritical := Critical("On")
	try {
		AssertTrue(GetSelectionAsync(_SCAS_Deliver.Bind(State), Ports), "the real startup must admit its job")
		Job := _SelectionCaptureJob
		State["jobs"].Push(Job)
		State["timers"].Push(Job["timer"])
		; All startup OS ports are passive here. Stop desktop polling before
		; restoring interruptibility; retain the exact callback for stale replay.
		SetTimer(Job["timer"], 0)
		return Job
	} finally Critical(PreviousCritical)
}

_SCAS_WithFixture(Fn) {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	AssertFalse(IsObject(_SelectionCaptureJob), "fixture requires no live capture")
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
	Saved := { Job: _SelectionCaptureJob, Id: _SelectionCaptureNextId,
		Generation: CBClipboardOwner.generation, Settle: CBClipboardOwner.settle_hook,
		Suspended: A_IsSuspended, Critical: A_IsCritical }
	State := Map("snapshot", { Formats: "opaque original user formats" },
		"text", "original user clipboard", "sequence", 1, "probes", 0,
		"reads", 0, "read_values", [], "foreign_before_read", false, "read_error", false,
		"sends", 0, "restores", [], "delivered", [],
		"sequence_action", 0, "read_action", 0, "probe_error", false,
		"jobs", [], "timers", [], "extra_timers", [], "timer_error", 0,
		"timer_ran", false)
	Ports := Map("save", _SCAS_Save.Bind(State), "clear", _SCAS_Clear.Bind(State),
		"send", (*) => State["sends"] += 1, "sequence", _SCAS_Sequence.Bind(State),
		"restore", _SCAS_Restore.Bind(State), "foreground", (*) => 101)
	State["ports"] := Ports
	try {
		CBClipboardOwner.settle_hook := 0
		Suspend(false)
		Critical("Off")
		State["job"] := _SCAS_Begin(State, Ports)
		Fn.Call(State, Ports)
	} finally {
		State["sequence_action"] := 0
		State["read_action"] := 0
		State["probe_error"] := false
		for Timer in State["extra_timers"]
			SetTimer(Timer, 0)
		State["extra_timers"] := []
		for Timer in State["timers"]
			SetTimer(Timer, 0)
		if IsObject(_SelectionCaptureJob) {
			Job := _SelectionCaptureJob
			State["sequence"] := Job.Get("owned_sequence", Job["clear_sequence"])
			_SelectionCaptureFinish(Job, "", false, "fixture cleanup", Ports["restore"], Ports["sequence"])
		}
		if CBClipboardOwner.restore_debt is Map {
			State["sequence"] := CBClipboardOwner.restore_debt["expected_sequence"]
			CB_RetryRestoreDebt()
		}
		SetTimer(CB_RetryRestoreDebt, 0)
		for Job in State["jobs"] {
			CB_EndOwnedTransaction(Job["owner_token"])
			Job["timer"] := 0
			Job["callback"] := 0
			Job["clipboard"] := ""
		}
		State.Delete("ports")
		CBClipboardOwner.settle_hook := Saved.Settle
		CBClipboardOwner.generation := Saved.Generation
		_SelectionCaptureJob := Saved.Job
		_SelectionCaptureNextId := Saved.Id
		Suspend(Saved.Suspended)
		Critical(Saved.Critical)
	}
	AssertEqual(0, CBClipboardOwner.active.Count, "fixture teardown must retire every exact capture owner")
	AssertFalse(CBClipboardOwner.restore_debt, "fixture teardown must settle its own restore debt")
}

_SCAS_AssertRetired(State, Job) {
	global _SelectionCaptureJob
	AssertFalse(IsObject(_SelectionCaptureJob))
	AssertEqual(0, Job["timer"], "the exact native poll callback must detach")
	AssertEqual("", Job["clipboard"], "terminal retirement releases its snapshot reference")
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
	Deliveries := State["delivered"].Length
	Restores := State["restores"].Length
	State["timers"][1].Call()
	AssertEqual(Deliveries, State["delivered"].Length, "a retired native callback cannot deliver again")
	AssertEqual(Restores, State["restores"].Length, "a retired native callback cannot restore again")
}

_SCAS_AssertOneRestore(State, Job, Expected, ExpectedText := "original user clipboard") {
	AssertEqual(1, State["restores"].Length, "a still-owned snapshot restores exactly once")
	Restore := State["restores"][1]
	AssertTrue(Restore["saved"] == State["snapshot"], "restore must receive the exact opaque snapshot")
	AssertEqual(Expected, Restore["expected"], "debt retains the admitted sequence")
	AssertEqual(Job["owner_token"], Restore["token"], "debt retains the exact capture owner")
	AssertTrue(Restore["live"], "ownership remains live during assignment")
	AssertEqual(ExpectedText, State["text"])
}

_SCAS_Finish(State, Ports, Reason) {
	_SelectionCaptureFinish(State["job"], "", false, Reason, Ports["restore"], Ports["sequence"])
}

_SCAS_Cancel(Reason, Foreign, State, Ports) {
	Job := State["job"]
	State["sequence"] := Foreign ? 43 : 42
	State["text"] := Foreign ? "new external user copy" : ""
	if Reason == "suspended"
		Suspend(true)
	_SCAS_Finish(State, Ports, Reason)
	AssertEqual(0, State["delivered"].Length)
	if Foreign {
		AssertEqual(0, State["restores"].Length, "a later user copy cannot be renamed as capture-owned")
		AssertEqual("new external user copy", State["text"])
	} else {
		_SCAS_AssertOneRestore(State, Job, 42)
	}
	_SCAS_AssertRetired(State, Job)
}
for _SCAS_Reason in ["cancelled", "suspended", "superseded", "foreground changed", "timeout"]
	for _SCAS_Foreign in [false, true]
		Test("selection sequence: " . _SCAS_Reason . " with " . (_SCAS_Foreign ? "new user copy" : "owned clear")
			. " (selection-admitted-sequence)", _SCAS_WithFixture.Bind(_SCAS_Cancel.Bind(_SCAS_Reason, _SCAS_Foreign)))

_SCAS_ChangeDuringRead(State, Mode) {
	if Mode == "foreign" or Mode == "foreign-before" {
		State["sequence"] := 44
		State["text"] := "new external user copy"
	} else if Mode == "probe-error" {
		State["probe_error"] := true
	} else {
		State["sequence"] := 0
	}
}

_SCAS_RecoverSequence(State, Target) {
	State["probe_error"] := false
	State["sequence"] := Target
	if Target == 44
		State["text"] := "new external user copy"
}

_SCAS_Ready(Mode, State, Ports) {
	Job := State["job"]
	Expected := Mode == "admission-zero" ? 42 : 43
	State["sequence"] := Mode == "admission-zero" ? 0 : 43
	State["text"] := "captured selection"
	State["foreign_before_read"] := Mode == "foreign-before"
	if Mode != "ordinary"
		State["read_action"] := _SCAS_ChangeDuringRead.Bind(State, Mode)
	AssertTrue(_SelectionCaptureReadReady(Job, _SCAS_Read.Bind(State), Ports["sequence"],
		Ports["restore"], (J) => Map("foreground", 101, "physical_generation", J["physical_generation"])))
	AssertEqual(Mode == "admission-zero" ? 0 : 1, State["reads"], "unavailable initial ownership must refuse the clipboard read")
	AssertEqual(Expected, Job["owned_sequence"], "a positive copy is admitted before reading, while zero retains proven clear ownership")
	AssertEqual(Mode == "ordinary" ? 1 : 0, State["delivered"].Length,
		"only a positive stable sequence can authorize delivery of the actual text read")
	if Mode == "ordinary"
		AssertEqual("captured selection", State["delivered"][1])
	if Mode == "foreign-before"
		AssertEqual("new external user copy", State["read_values"][1],
			"the read port must actually return foreign text, which cannot reach the continuation")
	if Mode == "zero-match" or Mode == "zero-foreign" or Mode == "probe-error" or Mode == "admission-zero" {
		Debt := CBClipboardOwner.restore_debt
		AssertTrue(Debt is Map, "an unavailable probe retains actual restore debt")
		AssertEqual(Expected, Debt["expected_sequence"])
		AssertTrue(Debt["saved"] == State["snapshot"])
		AssertTrue(CBClipboardOwner.active.Has(Job["owner_token"]), "unknown ownership retains its exact lease")
		AssertEqual(0, State["restores"].Length)
		AssertEqual(0, CB_TryBeginOwnedTransaction("must remain excluded"))
		Target := Mode == "zero-foreign" ? 44 : Expected
		RecoveryTimer := _SCAS_RecoverSequence.Bind(State, Target)
		State["extra_timers"].Push(RecoveryTimer)
		SetTimer(RecoveryTimer, -1)
		Started := A_TickCount
		while CBClipboardOwner.restore_debt && A_TickCount - Started < 2000
			Sleep(10)
		AssertFalse(CBClipboardOwner.restore_debt, "the real central retry timer must settle")
	}
	if Mode == "foreign" or Mode == "foreign-before" or Mode == "zero-foreign" {
		AssertEqual(0, State["restores"].Length, "a later positive sequence wins even after an unavailable probe")
		AssertEqual("new external user copy", State["text"])
	} else {
		_SCAS_AssertOneRestore(State, Job, Expected)
	}
	_SCAS_AssertRetired(State, Job)
}
for _SCAS_Mode in ["ordinary", "foreign", "foreign-before", "zero-match", "zero-foreign", "probe-error", "admission-zero"]
	Test("selection sequence: admitted copy then " . _SCAS_Mode . " ownership (selection-admitted-sequence)",
		_SCAS_WithFixture.Bind(_SCAS_Ready.Bind(_SCAS_Mode)))

_SCAS_Reenter(State, Ports, Action) {
	global _SelectionCaptureJob
	if Action == "pause" {
		Suspend(true)
		return
	}
	_SCAS_Finish(State, Ports, Action == "replace" ? "superseded" : "cancelled")
	if Action == "replace" {
		State["successor"] := _SCAS_Begin(State, Ports)
		State["successor_record"] := CBClipboardOwner.active[State["successor"]["owner_token"]]
	}
}

_SCAS_ReentrantRead(Boundary, Action, State, Ports) {
	global _SelectionCaptureJob
	Job := State["job"]
	State["sequence"] := 43
	State["text"] := "captured selection"
	Reenter := _SCAS_Reenter.Bind(State, Ports, Action)
	if Boundary == "post-sequence"
		State["read_action"] := (*) => State["sequence_action"] := Reenter
	else
		State[Boundary . "_action"] := Reenter
	AssertFalse(_SelectionCaptureReadReady(Job, _SCAS_Read.Bind(State), Ports["sequence"],
		Ports["restore"], (J) => Map("foreground", 101, "physical_generation", J["physical_generation"])),
		"revocation at either native boundary must stop the old completion")
	AssertEqual(Boundary == "sequence" ? 0 : 1, State["reads"], "a revoked probe cannot proceed to a clipboard read")
	AssertEqual(Boundary == "sequence" ? 42 : 43, Job["owned_sequence"], "only a current sequence probe can admit ownership")
	AssertEqual(0, State["delivered"].Length)
	if Action == "pause" {
		AssertTrue(CBClipboardOwner.active.Has(Job["owner_token"]), "pause leaves exact cleanup to the terminal path")
		_SCAS_Finish(State, Ports, "suspended")
	} else if Action == "replace" {
		Successor := State["successor"]
		AssertTrue(_SelectionCaptureJob == Successor, "old completion cannot retire the replacement job")
		AssertEqual(1, CBClipboardOwner.active.Count)
		AssertTrue(CBClipboardOwner.active.Has(Successor["owner_token"]))
		AssertTrue(CBClipboardOwner.active[Successor["owner_token"]] == State["successor_record"])
		AssertEqual(42, Successor["owned_sequence"])
		Restores := State["restores"].Length
		State["timers"][1].Call()
		AssertTrue(_SelectionCaptureJob == Successor, "the old native timer cannot retire a successor")
		AssertTrue(CBClipboardOwner.active[Successor["owner_token"]] == State["successor_record"])
		AssertEqual(Restores, State["restores"].Length)
		AssertEqual(0, State["delivered"].Length)
		return
	}
	AssertEqual(Boundary == "sequence" ? 0 : 1, State["restores"].Length,
		"only an already admitted matching copy may restore during revocation")
	_SCAS_AssertRetired(State, Job)
}
for _SCAS_Boundary in ["sequence", "read", "post-sequence"]
	for _SCAS_Action in ["cancel", "pause", "replace"]
		Test("selection sequence: " . _SCAS_Action . " during " . _SCAS_Boundary . " admission (selection-admitted-sequence)",
			_SCAS_WithFixture.Bind(_SCAS_ReentrantRead.Bind(_SCAS_Boundary, _SCAS_Action)))

_SCAS_ReadFailure(Action, State, Ports) {
	global _SelectionCaptureJob
	Job := State["job"]
	State["sequence"] := 43
	State["text"] := "captured selection"
	State["read_error"] := true
	if Action == "unavailable"
		State["read_action"] := _SCAS_RecoverSequence.Bind(State, 0)
	else if Action != "none"
		State["read_action"] := _SCAS_Reenter.Bind(State, Ports, Action)
	Completed := _SelectionCaptureReadReady(Job, _SCAS_Read.Bind(State), Ports["sequence"],
		Ports["restore"], (J) => Map("foreground", 101, "physical_generation", J["physical_generation"]))
	AssertEqual(1, State["reads"], "the failing getter must actually run")
	AssertEqual(0, State["delivered"].Length, "a failed getter never delivers partial or foreign text")
	AssertEqual(43, Job["owned_sequence"], "error cleanup retains the sequence admitted before the getter")
	if Action == "unavailable" {
		AssertTrue(CBClipboardOwner.restore_debt is Map)
		AssertEqual(43, CBClipboardOwner.restore_debt["expected_sequence"])
		AssertTrue(CBClipboardOwner.restore_debt["saved"] == State["snapshot"])
		AssertTrue(CB_HasRestoreDebtForOwner(Job["owner_token"]))
		AssertTrue(CBClipboardOwner.active.Has(Job["owner_token"]))
		AssertEqual(0, State["restores"].Length)
		State["sequence"] := 43
		AssertTrue(CB_RetryRestoreDebt(), "a matching probe must settle the real retained error-cleanup debt")
	}
	_SCAS_AssertOneRestore(State, Job, 43, Action == "replace" ? "" : "original user clipboard")
	if Action == "replace" {
		Successor := State["successor"]
		AssertFalse(Completed, "the replaced getter cannot finish a new job")
		AssertTrue(_SelectionCaptureJob == Successor)
		AssertTrue(CBClipboardOwner.active[Successor["owner_token"]] == State["successor_record"])
		AssertEqual(1, CBClipboardOwner.active.Count)
	} else {
		AssertEqual(Action != "cancel", Completed, "only the still-owned getter performs its own terminal cleanup")
		_SCAS_AssertRetired(State, Job)
	}
}
for _SCAS_ReadFailureAction in ["none", "cancel", "replace", "pause", "unavailable"]
	Test("selection sequence: getter failure after " . _SCAS_ReadFailureAction . " revocation (selection-admitted-sequence)",
		_SCAS_WithFixture.Bind(_SCAS_ReadFailure.Bind(_SCAS_ReadFailureAction)))

_SCAS_TimerCancel(State, Ports) {
	try {
		_SCAS_Finish(State, Ports, "cancelled")
		State["timer_ran"] := true
	} catch as Err {
		State["timer_error"] := Err
	}
}

_SCAS_CancelFromNativeTimer(State, Ports) {
	Job := State["job"]
	State["sequence"] := 43
	State["text"] := "new external user copy"
	Timer := _SCAS_TimerCancel.Bind(State, Ports)
	State["extra_timers"].Push(Timer)
	SetTimer(Timer, -1)
	Started := A_TickCount
	while !State["timer_ran"] && !IsObject(State["timer_error"]) && A_TickCount - Started < 2000
		Sleep(10)
	if IsObject(State["timer_error"])
		throw State["timer_error"]
	AssertTrue(State["timer_ran"], "the actual native timer must execute its terminal path")
	AssertEqual(0, State["restores"].Length)
	AssertEqual("new external user copy", State["text"])
	_SCAS_AssertRetired(State, Job)
}
Test("selection sequence: native cancellation preserves a newer copy (selection-admitted-sequence-timer)",
	_SCAS_WithFixture.Bind(_SCAS_CancelFromNativeTimer))
