; tests/unit/modules/hotstrings/engine/test_hotstring_send_failure_containment.ahk

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
	RetiredTimer := 0
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
			; Every ready/completed fixture has admitted the captured sequence.
			; The physical-copy cancellation still owns only its earlier clear.
			"owned_sequence", Reason == "superseded by input" ? 100 : 101,
			"owner_token", Token, "expected_change", 0, "timer", (*) => 0)
		RetiredTimer := Job["timer"]
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
		AssertEqual(0, Job["timer"], "the bound timer reference must retire")
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
		if IsObject(RetiredTimer)
			SetTimer(RetiredTimer, 0)
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

; Startup ports record only OS boundaries. Admission, cancellation, rollback
; debt and timer ownership all execute through the production selection owner.
_SCSC_Revoke(State, Boundary) {
	global _SelectionCaptureJob
	if State["boundary"] != Boundary or State["revoked"]
		return
	State["revoked"] := true
	State["job"] := _SelectionCaptureJob
	AssertTrue(_SelectionCaptureJob["starting"], "startup is published before native work")
	AssertEqual(1, CBClipboardOwner.active.Count, "the interrupted stack owns its snapshot")
	switch State["action"] {
		case "pause": Suspend(true)
		case "cancel": GetSelectionCancel()
		case "pause-resume":
			Suspend(true)
			GetSelectionCancel()
			Suspend(false)
		case "new":
			State["nested"] := GetSelectionAsync((*) => 0, State["ports"])
			AssertFalse(State["nested"], "the newer request cannot snapshot an in-flight clear")
	}
	AssertTrue(_SelectionCaptureJob == State["job"], "revocation retains the exact in-flight job")
	AssertEqual(1, CBClipboardOwner.active.Count, "revocation defers release until the native call returns")
}

_SCSC_Save(State) {
	State["saves"] += 1
	_SCSC_Revoke(State, "snapshot")
	return "owned startup snapshot"
}

_SCSC_Clear(State) {
	State["clears"] += 1
	_SCSC_Revoke(State, "clear")
	return true
}

_SCSC_Sequence(State) {
	State["sequences"] += 1
	_SCSC_Revoke(State, "sequence")
	return 42
}

_SCSC_Send(State) {
	State["sends"] += 1
	_SCSC_Revoke(State, "send")
}

_SCSC_Restore(State, Saved) {
	State["restores"] += 1
	AssertEqual("owned startup snapshot", Saved)
	AssertTrue(CBClipboardOwner.restore_debt is Map,
		"rollback must use the real central clipboard owner")
	AssertEqual(1, CBClipboardOwner.active.Count)
	return true
}

_SCSC_Startup(Boundary, Action) {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	AssertFalse(IsObject(_SelectionCaptureJob), "fixture refuses a live capture")
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
	PreviousId := _SelectionCaptureNextId
	PreviousGeneration := CBClipboardOwner.generation
	PreviousSuspended := A_IsSuspended
	PreviousSettle := CBClipboardOwner.settle_hook
	State := Map("boundary", Boundary, "action", Action, "revoked", false,
		"saves", 0, "clears", 0, "sequences", 0, "sends", 0,
		"restores", 0, "job", 0, "deliveries", 0, "nested", true)
	Ports := Map("save", _SCSC_Save.Bind(State), "clear", _SCSC_Clear.Bind(State),
		"sequence", _SCSC_Sequence.Bind(State), "send", _SCSC_Send.Bind(State),
		"restore", _SCSC_Restore.Bind(State), "foreground", (*) => 101)
	State["ports"] := Ports
	try {
		CBClipboardOwner.settle_hook := 0
		Suspend(false)
		Accepted := GetSelectionAsync((Text) => State["deliveries"] += 1, Ports)
		if Action == "none" {
			AssertTrue(Accepted, "the ordinary capture must remain admitted")
			State["job"] := _SelectionCaptureJob
			AssertFalse(_SelectionCaptureJob["starting"])
			AssertTrue(IsObject(_SelectionCaptureJob["timer"]))
			AssertEqual(1, CBClipboardOwner.active.Count)
			_SelectionCaptureFinish(_SelectionCaptureJob, "captured selection", true, "ready",
				Ports["restore"], Ports["sequence"],
				(*) => Map("foreground", 101, "elapsed", 0, "idle", 0))
		} else {
			AssertFalse(Accepted, "a revoked startup cannot report accepted")
			AssertTrue(State["revoked"], "the requested boundary must be reached")
		}
		AssertEqual(1, State["saves"])
		AssertEqual(Boundary == "snapshot" ? 0 : 1, State["clears"])
		AssertEqual(Boundary == "send" or Action == "none" ? 1 : 0, State["sends"],
			"revocation must prevent any later Ctrl+C")
		AssertEqual(Boundary == "snapshot" ? 0 : 1, State["restores"],
			"only a completed temporary clear needs rollback")
		AssertEqual(Action == "none" ? 1 : 0, State["deliveries"])
		AssertFalse(IsObject(_SelectionCaptureJob), "the exact retired job must leave no timer owner")
		AssertEqual("", State["job"]["clipboard"], "snapshot references must retire")
		AssertEqual(0, CBClipboardOwner.active.Count)
		AssertFalse(CBClipboardOwner.restore_debt)
	} finally {
		if IsObject(_SelectionCaptureJob) {
			if IsObject(_SelectionCaptureJob["timer"])
				SetTimer(_SelectionCaptureJob["timer"], 0)
			Token := _SelectionCaptureJob["owner_token"]
			if Token
				CB_EndOwnedTransaction(Token)
		}
		SetTimer(CB_RetryRestoreDebt, 0)
		if CBClipboardOwner.restore_debt is Map {
			Token := CBClipboardOwner.restore_debt["owner_token"]
			CB_EndOwnedTransaction(Token)
			CBClipboardOwner.restore_debt := 0
		}
		; The injected ports close over State; explicitly release that fixture cycle.
		if IsObject(State["job"]) {
			CB_EndOwnedTransaction(State["job"]["owner_token"])
			State["job"]["callback"] := 0
			State["job"]["timer"] := 0
		}
		State.Delete("ports")
		CBClipboardOwner.settle_hook := PreviousSettle
		CBClipboardOwner.generation := PreviousGeneration
		_SelectionCaptureJob := false
		_SelectionCaptureNextId := PreviousId
		Suspend(PreviousSuspended)
	}
}

for Boundary in ["snapshot", "clear", "sequence", "send"] {
	for Action in ["pause", "cancel", "pause-resume", "new"] {
		Test("hotstrings: selection startup " . Action . " during " . Boundary
			. " (selection-startup-revocation)", _SCSC_Startup.Bind(Boundary, Action))
	}
}
Test("hotstrings: ordinary selection startup retains its native timer (selection-startup-revocation)",
	_SCSC_Startup.Bind("none", "none"))

class _SCL_Callback {
	__New(State) {
		this.State := State
	}
	Call(Text) {
		this.State["deliveries"] += 1
		this.State["text"] := Text
		if this.State["throw"]
			throw Error("injected selection callback failure")
	}
	__Delete() {
		this.State["deleted"] += 1
	}
}

_SCL_TimerLifetime(Reason) {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	AssertFalse(IsObject(_SelectionCaptureJob), "fixture refuses a live capture")
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
	PreviousId := _SelectionCaptureNextId
	PreviousGeneration := CBClipboardOwner.generation
	PreviousSuspended := A_IsSuspended
	PreviousSettle := CBClipboardOwner.settle_hook
	State := Map("boundary", "none", "action", "none", "revoked", false,
		"saves", 0, "clears", 0, "sequences", 0, "sends", 0, "restores", 0,
		"deliveries", 0, "text", "", "deleted", 0, "throw", Reason == "callback error")
	Ports := Map("save", _SCSC_Save.Bind(State), "clear", _SCSC_Clear.Bind(State),
		"sequence", _SCSC_Sequence.Bind(State), "send", _SCSC_Send.Bind(State),
		"restore", _SCSC_Restore.Bind(State), "foreground", (*) => 101)
	Job := 0
	RetiredTimer := 0
	OnReady := _SCL_Callback(State)
	try {
		CBClipboardOwner.settle_hook := 0
		Suspend(false)
		AssertTrue(GetSelectionAsync(OnReady, Ports))
		OnReady := 0
		Job := _SelectionCaptureJob
		RetiredTimer := Job["timer"]
		if Reason == "cancelled" {
			_SelectionCaptureFinish(Job, "", false, "cancelled",
				Ports["restore"], Ports["sequence"])
		} else {
			_SelectionCaptureFinish(Job, "captured selection", true, "ready",
				Ports["restore"], Ports["sequence"],
				(*) => Map("foreground", 101, "elapsed", 0, "idle", 0))
		}
		AssertFalse(IsObject(_SelectionCaptureJob))
		AssertEqual(0, Job["timer"], "retirement must detach the exact bound callback")
		AssertEqual(Reason == "cancelled" ? 0 : 1, State["deliveries"])
		AssertEqual(Reason == "cancelled" ? "" : "captured selection", State["text"])
		AssertEqual(0, CBClipboardOwner.active.Count)
		AssertFalse(CBClipboardOwner.restore_debt)
		RetiredTimer.Call()
		AssertEqual(Reason == "cancelled" ? 0 : 1, State["deliveries"],
			"a captured retired callback must remain inert")
		Job := 0
		AssertEqual(0, State["deleted"], "the retained original timer still owns the callback")
		RetiredTimer := 0
		AssertEqual(1, State["deleted"],
			"native timer cancellation and job detachment must release the last owner")
	} finally {
		if IsObject(Job) {
			if IsObject(RetiredTimer)
				SetTimer(RetiredTimer, 0)
			Job["timer"] := 0
			Job["callback"] := 0
			CB_EndOwnedTransaction(Job["owner_token"])
		}
		SetTimer(CB_RetryRestoreDebt, 0)
		if CBClipboardOwner.restore_debt is Map {
			CB_EndOwnedTransaction(CBClipboardOwner.restore_debt["owner_token"])
			CBClipboardOwner.restore_debt := 0
		}
		CBClipboardOwner.settle_hook := PreviousSettle
		CBClipboardOwner.generation := PreviousGeneration
		_SelectionCaptureJob := false
		_SelectionCaptureNextId := PreviousId
		Suspend(PreviousSuspended)
	}
}

for Reason in ["completed", "cancelled", "callback error"] {
	Test("hotstrings: selection " . Reason . " releases its bound timer (selection-timer-release)",
		_SCL_TimerLifetime.Bind(Reason))
}

_SCO_Sequence(State) {
	State["sequences"] += 1
	return State["external"] and State["sequences"] > 1 ? 43 : 42
}

_SCO_Settle(State, Ports) {
	global _SelectionCaptureJob
	; A new command can enter at the central owner's real settlement boundary.
	CBClipboardOwner.settle_hook := 0
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
	State["successor_started"] := GetSelectionAsync((*) => 0, Ports)
	State["successor"] := _SelectionCaptureJob
}

_SCO_StartupSettlement(ExternalCopy) {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	AssertFalse(IsObject(_SelectionCaptureJob), "fixture refuses a live capture")
	AssertEqual(0, CBClipboardOwner.active.Count)
	AssertFalse(CBClipboardOwner.restore_debt)
	PreviousId := _SelectionCaptureNextId
	PreviousGeneration := CBClipboardOwner.generation
	PreviousSuspended := A_IsSuspended
	PreviousSettle := CBClipboardOwner.settle_hook
	State := Map("boundary", "send", "action", "cancel", "revoked", false,
		"saves", 0, "clears", 0, "sequences", 0, "sends", 0, "restores", 0,
		"job", 0, "successor", 0, "successor_started", false, "external", ExternalCopy)
	Ports := Map("save", _SCSC_Save.Bind(State), "clear", _SCSC_Clear.Bind(State),
		"sequence", _SCO_Sequence.Bind(State), "send", _SCSC_Send.Bind(State),
		"restore", _SCSC_Restore.Bind(State), "foreground", (*) => 101)
	try {
		Suspend(false)
		CBClipboardOwner.settle_hook := ExternalCopy ? 0 : _SCO_Settle.Bind(State, Ports)
		AssertFalse(GetSelectionAsync((*) => 0, Ports))
		AssertTrue(State["revoked"])
		AssertEqual("", State["job"]["clipboard"])
		AssertEqual(0, State["job"]["timer"])
		if ExternalCopy {
			AssertEqual(0, State["restores"], "the newer clipboard sequence must win")
			AssertFalse(IsObject(_SelectionCaptureJob))
		} else {
			AssertEqual(1, State["restores"])
			AssertTrue(State["successor_started"])
			AssertTrue(_SelectionCaptureJob == State["successor"],
				"old startup cleanup must preserve the successor admitted during settlement")
			AssertTrue(_SelectionCaptureJob["id"] > State["job"]["id"])
			AssertTrue(IsObject(_SelectionCaptureJob["timer"]))
			AssertEqual(1, CBClipboardOwner.active.Count)
			_SelectionCapturePoll(State["job"])
			AssertTrue(_SelectionCaptureJob == State["successor"])
			_SelectionCaptureFinish(_SelectionCaptureJob, "", false, "cancelled",
				Ports["restore"], Ports["sequence"])
		}
		AssertEqual(0, CBClipboardOwner.active.Count)
		AssertFalse(CBClipboardOwner.restore_debt)
	} finally {
		CBClipboardOwner.settle_hook := 0
		for Job in [State["job"], State["successor"]] {
			if !IsObject(Job)
				continue
			if IsObject(Job["timer"])
				SetTimer(Job["timer"], 0)
			Job["timer"] := 0
			Job["callback"] := 0
			CB_EndOwnedTransaction(Job["owner_token"])
		}
		SetTimer(CB_RetryRestoreDebt, 0)
		if CBClipboardOwner.restore_debt is Map {
			CB_EndOwnedTransaction(CBClipboardOwner.restore_debt["owner_token"])
			CBClipboardOwner.restore_debt := 0
		}
		CBClipboardOwner.settle_hook := PreviousSettle
		CBClipboardOwner.generation := PreviousGeneration
		_SelectionCaptureJob := false
		_SelectionCaptureNextId := PreviousId
		Suspend(PreviousSuspended)
	}
}

Test("hotstrings: startup rollback yields to a newer clipboard (selection-startup-owner-settlement)",
	_SCO_StartupSettlement.Bind(true))
Test("hotstrings: startup rollback preserves its settlement successor (selection-startup-owner-settlement)",
	_SCO_StartupSettlement.Bind(false))

; A clipboard another program holds past ClipboardAll's one-second wait is
; reported to the user with its holder; it used to raise an ERROR that opened
; the generic error window.
_SCBusy_Run() {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	AssertFalse(IsObject(_SelectionCaptureJob), "fixture refuses a live capture")
	AssertEqual(0, CBClipboardOwner.active.Count)
	PreviousId := _SelectionCaptureNextId
	State := Map("busy", 0, "clears", 0, "sends", 0, "restores", 0)
	Ports := Map("save", (*) => "__CB_SAVE_ERROR__",
		"clear", (*) => (State["clears"] += 1, true),
		"send", (*) => State["sends"] += 1,
		"restore", (Saved) => (State["restores"] += 1, true),
		"sequence", (*) => 42, "foreground", (*) => 101,
		"report_busy", (*) => State["busy"] += 1)
	try {
		AssertFalse(GetSelectionAsync((*) => 0, Ports), "a busy clipboard cannot start a capture")
		AssertEqual(1, State["busy"], "the busy clipboard must be reported once, naming its holder")
		AssertEqual(0, State["clears"], "nothing may be cleared without a snapshot")
		AssertEqual(0, State["sends"], "no Ctrl+C may be sent without a snapshot")
		AssertEqual(0, State["restores"])
		AssertFalse(IsObject(_SelectionCaptureJob))
		AssertEqual(0, CBClipboardOwner.active.Count, "the transaction owner must be released")
	} finally {
		_SelectionCaptureJob := false
		_SelectionCaptureNextId := PreviousId
	}
}
Test("hotstrings: a held clipboard is reported instead of raising an error (selection-clipboard-busy)", _SCBusy_Run)

; GetOpenClipboardWindow names the lock holder: the test process holds the real
; lock itself, so the description must name this process and flag it as ours.
_SCHolder_Run() {
	AssertTrue(CB_OpenClipboardWithin(A_ScriptHwnd), "the test must hold the real clipboard lock")
	try Holder := CB_DescribeClipboardHolder()
	finally DllCall("User32\CloseClipboard", "Int")
	SplitPath(A_AhkPath, &ExeName)
	AssertEqual(A_ScriptHwnd, Holder["hwnd"])
	AssertEqual(DllCall("Kernel32\GetCurrentProcessId", "UInt"), Holder["pid"])
	AssertEqual(StrLower(ExeName), StrLower(Holder["process"]))
	AssertTrue(Holder["own"], "the holder must be flagged as this process")
	Assert(InStr(Holder["summary"], "own_process=yes") > 0, "the log summary must say the holder is ours")
}
Test("clipboard: the busy-clipboard evidence names the holding process (clipboard-holder-evidence)", _SCHolder_Run)


#Include test_selection_admitted_clipboard_sequence.ahk
