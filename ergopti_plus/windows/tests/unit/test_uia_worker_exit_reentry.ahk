; tests/unit/test_uia_worker_exit_reentry.ahk

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
