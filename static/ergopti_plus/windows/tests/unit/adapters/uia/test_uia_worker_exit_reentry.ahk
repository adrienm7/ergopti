; tests/unit/adapters/uia/test_uia_worker_exit_reentry.ahk

; ==============================================================================
; MODULE: UIA Worker Exit Reentry Tests
; DESCRIPTION:
; A terminal callback must never observe the exited worker as ready. A successor
; admitted by that callback owns independent state that old cleanup cannot erase.
; ==============================================================================

#Requires AutoHotkey v2.0

_UER_ExitReentry(RequestFn, ReplaceWorker := false, ReenterClose := false) {
	Fields := ["handle", "worker_hwnd", "worker_process_handle", "worker_generation",
		"request_generation", "pending", "start_deadline_fn", "start_failure_tick",
		"start_diagnostic", "handlers_registered", "spawn_fn", "post_fn", "open_process_fn",
		"close_process_fn", "cleanup_debt", "cleanup_draining", "process_cleanup_debt",
		"process_cleanup_draining", "cleanup_retry_armed"]
	Saved := Map()
	for Name in Fields
		Saved[Name] := UIASWState.%Name%
	WasSuspended := A_IsSuspended
	Timers := []
	Posts := []
	Closes := []
	Receipt := {Calls: 0, Ready: true, Accepted: false, Spawned: 0, NewTerminals: 0}
	OldHandle := {start: (*) => true, processId: (*) => 5151}
	NewHandle := {start: (*) => true, processId: (*) => 6161}
	Context := Map("Hwnd", 11, "Control", 22, "InputEpoch", 33, "ProcName", "exit-fixture.exe")
	NewTerminal(*) {
		Receipt.NewTerminals += 1
	}
	Spawn(*) {
		Receipt.Spawned += 1
		return NewHandle
	}
	Close(Handle) {
		Closes.Push(Handle)
		if ReenterClose
			UIASW_Stop("canceled")
		return true
	}
	Terminal(Status, SeenContext, Result) {
		Receipt.Calls += 1
		Receipt.Status := Status
		Receipt.Context := SeenContext
		Receipt.Ready := UIASW_IsReady()
		if ReplaceWorker {
			; Isolate publication ordering from the independently tested retry delay.
			UIASWState.start_failure_tick := 0
			Receipt.Started := UIASW_Start()
			Receipt.ReadyAck := UIASW_OnWorkerReady(4243,
				UIASWState.worker_generation, 0, A_ScriptHwnd)
		}
		Receipt.Accepted := RequestFn.Call(Context, NewTerminal)
		if IsObject(UIASWState.pending) {
			Timers.Push(UIASWState.pending["deadline_fn"])
			SetTimer(Timers[Timers.Length], 0)
		}
	}
	try {
		Suspend(false)
		UIASWState.handle := OldHandle
		UIASWState.worker_hwnd := 4242
		UIASWState.worker_process_handle := 9001
		UIASWState.worker_generation := 73
		UIASWState.request_generation := 0
		UIASWState.pending := 0
		UIASWState.start_deadline_fn := 0
		UIASWState.start_failure_tick := 0
		UIASWState.start_diagnostic := "fixture ready"
		UIASWState.handlers_registered := true
		UIASWState.cleanup_debt := []
		UIASWState.cleanup_draining := false
		UIASWState.process_cleanup_debt := []
		UIASWState.process_cleanup_draining := false
		UIASWState.cleanup_retry_armed := false
		UIASWState.spawn_fn := Spawn
		UIASWState.post_fn := (Hwnd, *) => (Posts.Push(Hwnd), true)
		UIASWState.open_process_fn := (Hwnd, Root) => Hwnd = 4243 && Root = 6161 ? 9002 : 0
		UIASWState.close_process_fn := Close
		AssertTrue(RequestFn.Call(Context, Terminal))
		Timers.Push(UIASWState.pending["deadline_fn"])
		SetTimer(Timers[1], 0)
		Posts.Length := 0

		UIASW_OnWorkerExit(73, 1, "", "fixture exit")
		AssertEqual(1, Receipt.Calls, "the exited request must receive exactly one terminal")
		AssertEqual(ReenterClose ? "canceled" : "failed", Receipt.Status)
		AssertTrue(Receipt.Context == Context, "the original request context must be retained")
		AssertFalse(Receipt.Ready, "the exited worker must be retired before the terminal callback")
		AssertEqual(1, Closes.Length, "the old native capability must be released exactly once")
		AssertEqual(9001, Closes[1])
		if ReplaceWorker && !ReenterClose {
			AssertTrue(Receipt.Started)
			AssertEqual(1, Receipt.ReadyAck)
			AssertEqual(1, Receipt.Spawned)
			AssertTrue(Receipt.Accepted, "a fresh ready successor may admit its own request")
			AssertTrue(UIASWState.handle == NewHandle, "old cleanup must not erase the successor")
			AssertEqual(9002, UIASWState.worker_process_handle)
			AssertEqual(4243, UIASWState.worker_hwnd)
			AssertEqual(1, Posts.Length)
			AssertEqual(4243, Posts[1], "only the successor may receive the new request")
			AssertEqual(UIASWState.worker_generation, UIASWState.pending["worker_generation"])
			AssertEqual(0, Receipt.NewTerminals)
		} else {
			if ReenterClose {
				AssertFalse(Receipt.Started, "native cleanup must fence successor admission until its receipt")
				AssertEqual(0, Receipt.ReadyAck)
				AssertEqual(0, Receipt.Spawned)
			}
			AssertFalse(Receipt.Accepted, "retry must not be posted to the exited worker")
			AssertEqual(0, Posts.Length)
			AssertFalse(IsObject(UIASWState.pending))
			AssertFalse(UIASW_IsReady())
		}
		UIASW_OnWorkerExit(73, 1, "", "late duplicate")
		AssertEqual(1, Receipt.Calls, "a stale exit cannot notify the old request again")
		AssertEqual(1, Closes.Length, "a stale exit cannot close a successor capability")
	} finally {
		try {
			if IsObject(UIASWState.pending)
				SetTimer(UIASWState.pending["deadline_fn"], 0)
			for Timer in Timers
				SetTimer(Timer, 0)
			if IsObject(UIASWState.start_deadline_fn)
				SetTimer(UIASWState.start_deadline_fn, 0)
		} finally {
			for Name, Value in Saved
				UIASWState.%Name% := Value
			Suspend(WasSuspended)
		}
	}
}
for RequestFn in [UIASW_Request, UIASW_RequestPassword, UIASW_RequestBounds]
	Test("UIA: exit rejects reentrant " . RequestFn.Name . " admission (uia-exit-reentry)",
		_UER_ExitReentry.Bind(RequestFn))
Test("UIA: exit preserves a reentrant successor (uia-exit-reentry)",
	_UER_ExitReentry.Bind(UIASW_Request, true))
Test("UIA: native close reentry retains one terminal and fences admission (uia-exit-reentry)",
	_UER_ExitReentry.Bind(UIASW_Request, true, true))

; A timer retires startup while the actual shell handle is still being built.
; The late constructor must never publish over a newer worker or start a
; process after cancellation. Every handle remains in the fixture ledger.
_UER_ConstructorReentry(Mode) {
	Fields := ["starting_generation", "handle", "worker_hwnd", "worker_process_handle", "worker_generation",
		"request_generation", "pending", "start_deadline_fn", "start_failure_tick",
		"start_diagnostic", "handlers_registered", "spawn_fn", "post_fn", "open_process_fn",
		"terminate_process_fn", "close_process_fn", "cleanup_debt", "cleanup_draining",
		"process_cleanup_debt", "process_cleanup_draining", "cleanup_retry_armed", "cleanup_timer_fn"]
	AssertFalse(IsObject(UIASWState.handle) || IsObject(UIASWState.pending),
		"native startup qualification must not borrow a live worker or request")
	AssertEqual(0, UIASWState.cleanup_debt.Length + UIASWState.process_cleanup_debt.Length,
		"native startup qualification must not borrow old cleanup debt")
	Saved := Map()
	for Name in Fields
		Saved[Name] := UIASWState.%Name%
	WasSuspended := A_IsSuspended
	State := Map("constructors", 0, "timer_calls", 0, "replacement", 0,
		"replacement_started", false, "handles", [], "records", [], "deadlines", [])
	Reenter() {
		State["timer_calls"] += 1
		if Mode == "noop"
			return
		if Mode == "busy" {
			State["replacement_started"] := UIASW_Start()
			if IsObject(UIASWState.start_deadline_fn)
				State["deadlines"].Push(UIASWState.start_deadline_fn)
			return
		}
		UIASW_Stop("canceled")
		if Mode != "stop" {
			State["replacement_started"] := UIASW_Start()
			State["replacement"] := UIASWState.handle
			if IsObject(UIASWState.start_deadline_fn)
				State["deadlines"].Push(UIASWState.start_deadline_fn)
		}
	}
	Spawn(Executable, Args, Done, OnChunk?) {
		State["constructors"] += 1
		if State["constructors"] == 1 {
			SetTimer(Reenter, -1)
			Started := A_TickCount
			while State["timer_calls"] == 0 && !TickExpired64(Started, 2000)
				Sleep(10)
			AssertEqual(1, State["timer_calls"],
				"the real scheduler must deliver reentry outside any publication Critical")
			if Mode == "throw"
				throw Error("Owned constructor refusal after native successor admission.")
			if Mode == "invalid"
				return 0
		}
		local Handle := ShellRunner_Spawn(Executable, Args, Done)
		local NativeStart := Handle.start
		local Record := Map("start_calls", 0, "started_pid", 0)
		ObserveStart(*) {
			Record["start_calls"] += 1
			Result := NativeStart.Call()
			if Result
				Record["started_pid"] := Handle.processId()
			return Result
		}
		; Passive observation of the genuine boundary catches start-then-kill
		; substitutes that would make processId() look retired after the fact.
		Handle.start := ObserveStart
		State["handles"].Push(Handle)
		State["records"].Push(Record)
		return Handle
	}
	PrimaryFailure := 0
	CleanupFailures := []
	try {
		Suspend(false)
		UIASWState.start_failure_tick := 0
		UIASWState.spawn_fn := Spawn
		UIASWState.open_process_fn := 0
		UIASWState.close_process_fn := 0
		UIASWState.terminate_process_fn := 0
		UIASWState.cleanup_timer_fn := 0
		Accepted := UIASW_Start()
		if IsObject(UIASWState.start_deadline_fn)
			State["deadlines"].Push(UIASWState.start_deadline_fn)
		AssertEqual(1, State["timer_calls"], "the actual timer crossed the constructor window exactly once")
		if Mode == "noop" || Mode == "busy" {
			if Mode == "busy"
				AssertFalse(State["replacement_started"], "an overlapping constructor cannot create another worker")
			AssertTrue(Accepted, "an undisplaced actual startup remains admitted")
			AssertEqual(1, State["handles"].Length)
			AssertTrue(State["records"][1]["started_pid"] > 0, "the observer must see an actual admitted native process")
		} else {
			AssertFalse(Accepted, "a retired constructor cannot admit its former worker")
			if Mode == "stop" {
				AssertFalse(IsObject(UIASWState.handle), "late allocation cannot republish a cancelled owner")
				AssertEqual(0, State["handles"][1].processId(), "cancellation precedes any native child start")
				AssertEqual(0, State["records"][1]["started_pid"], "a cancelled constructor cannot start and then conceal a child")
			} else {
				AssertTrue(State["replacement_started"], "the replacement must have genuinely started")
				AssertTrue(State["replacement"].processId() > 0, "the replacement owns a real native process")
				AssertTrue(UIASWState.handle == State["replacement"], "late allocation must preserve the exact newer worker")
				AssertEqual(0, UIASWState.start_failure_tick, "an old refusal cannot back off the newer worker")
				if Mode == "replace" {
					AssertEqual(0, State["handles"][2].processId(), "the stale constructor must never start a second native child")
					AssertEqual(0, State["records"][2]["started_pid"], "retirement after starting cannot fabricate a prestart refusal")
				}
			}
		}
		if Mode != "stop" {
			Started := A_TickCount
			while !UIASW_IsReady() && !TickExpired64(Started, UIASW_START_DEADLINE_MS) {
				_SR_Poll()
				Sleep(10)
			}
			AssertTrue(UIASW_IsReady(), "the retained actual worker must complete its native ready handshake")
		}
	} catch Any as Failure {
		PrimaryFailure := Failure
	} finally {
		SetTimer(Reenter, 0)
		try UIASW_Stop("canceled")
		for Deadline in State["deadlines"]
			SetTimer(Deadline, 0)
		for Handle in State["handles"] {
			try {
				if !Handle.terminate()
					CleanupFailures.Push("Native shell termination was not acknowledged.")
			} catch as Err {
				CleanupFailures.Push(Err.Message)
			}
		}
		if !UIASW_RetryTerminationDebt()
			CleanupFailures.Push("UIA native cleanup debt remains owned.")
		SetTimer(UIASW_RetryTerminationDebt, 0)
		if !Saved["handlers_registered"]
			OnMessage(0x004A, UIASW_OnCopyData, 0)
		for Name, Value in Saved
			UIASWState.%Name% := Value
		Suspend(WasSuspended)
	}
	if IsObject(PrimaryFailure)
		throw PrimaryFailure
	AssertEqual(0, CleanupFailures.Length, "the fixture must acknowledge every exact native handle retirement")
}
for Mode in ["replace", "stop", "throw", "invalid", "noop", "busy"]
	Test("UIA: constructor " . Mode . " preserves native startup ownership (uia-start-constructor-reentry)",
		_UER_ConstructorReentry.Bind(Mode))
