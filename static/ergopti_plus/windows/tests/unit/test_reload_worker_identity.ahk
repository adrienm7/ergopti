; tests/unit/test_reload_worker_identity.ahk

; ==============================================================================
; MODULE: Reload Worker Identity Tests
; DESCRIPTION:
; A detached worker that re-runs the driver entry owns the driver's exact
; main-window title from the creation of its window to its first statement
; (22 to 34 ms measured on AutoHotkey v2.0.26). A /restart successor closes the
; newest window with that title, so one that finished loading inside that span
; closed the worker instead of the driver, then waited on the driver mutex and
; left: the reload was refused with "the successor exited without asking this
; instance to close" (reload-worker-identity). The metrics warm-up chain started
; its next worker in the very millisecond the successor launched, so both loaded
; the same script side by side. No worker may start while a reload hand-off
; exists. The fake successor port comes from test_reload_terminal_pending.ahk
; and the fake UIA worker from test_uia_selection_worker_deadline.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

global _RWI_PrefetchSpawns := 0
global _RWI_Terminals := []





; ==================================
; ==================================
; ======= 1/ Shared fixtures =======
; ==================================
; ==================================

_RWI_PrefetchSpawn(Executable, Args, Done) {
	global _RWI_PrefetchSpawns
	_RWI_PrefetchSpawns += 1
	Handle := {}
	Handle.start := (*) => true
	Handle.terminate := (*) => true
	return Handle
}

_RWI_Terminal(Status, *) {
	global _RWI_Terminals
	_RWI_Terminals.Push(Status)
}

; Brings a hand-off to Stage through the real hand-off: "authorized" is the
; record while its successor is being launched, "pending" the launched one.
_RWI_EnterStage(Stage, Bundle, Port) {
	if (Stage == "authorized") {
		AssertTrue(ReloadTerminalHandoffPrepare(Bundle) is Map,
			"the test must own an authorized hand-off")
		return
	}
	AssertTrue(ReloadTerminalInvoke(Bundle, 0, _RTP_LaunchReturnsAtOnce, Port),
		"the test must own a pending hand-off")
}

_RWI_LeaveStage() {
	global _ReloadTerminalHandoff
	AssertTrue(_ReloadTerminalHandoff is Map, "the hand-off must still exist")
	Record := _ReloadTerminalHandoff
	if Record["state"] == "authorized" {
		AssertTrue(ReloadTerminalHandoffCancel(Record), "the unlaunched test hand-off can be withdrawn")
		return
	}
	Port := Record["port"]
	AssertTrue(ReloadTerminalHandoffRefuse(Record, "worker identity test cleanup"))
	Port["probe"]["alive"] := false
	_RTP_RunArmed(Port)
	_RTP_RunArmed(Port)
	AssertFalse(_ReloadTerminalHandoff is Map, "The launched test hand-off must physically stop before cleanup.")
}





; ===================================================
; ===================================================
; ======= 2/ No worker starts during a reload =======
; ===================================================
; ===================================================

_RWI_PrefetchWorkerWaitsForTheReload() {
	global _RWI_PrefetchSpawns, _RWI_Terminals
	OldJobs := KLPFWorker.jobs
	OldGeneration := KLPFWorker.generation
	OldSpawn := KLPFWorker.spawn_fn
	OldRangeDelete := KLPFWorker.range_delete_fn
	KLPFWorker.jobs := Map()
	KLPFWorker.spawn_fn := _RWI_PrefetchSpawn
	KLPFWorker.range_delete_fn := (*) => true
	MetricsDir := A_Temp . "\ergopti-reload-worker-identity"
	Query := Map("apps", [], "start_date", "2026-10-01", "end_date", "2026-10-02")
	Bundle := _RTP_Acquire("worker-identity-prefetch")
	Port := _RTP_NewPort()
	try {
		for Stage in ["authorized", "pending"] {
			_RWI_PrefetchSpawns := 0
			_RWI_Terminals := []
			_RWI_EnterStage(Stage, Bundle, Port)
			AssertTrue(ReloadTerminalHandoffActive(),
				Stage . ": the hand-off must report itself")
			AssertFalse(KLPF_RequestBuild("apps", MetricsDir, "full", 0,
				_RWI_Terminal, false),
				Stage . ": a projection must not start beside a reload successor")
			AssertFalse(KLPF_RequestRange("typing", MetricsDir, Query, 0,
				_RWI_Terminal),
				Stage . ": a range projection must not start beside a reload successor")
			AssertEqual(0, _RWI_PrefetchSpawns,
				Stage . ": no worker that shares the driver's window title may be spawned")
			AssertEqual("canceled,canceled", _RTP_Join(_RWI_Terminals),
				Stage . ": each refused request must end its caller once")
			AssertEqual(0, KLPFWorker.jobs.Count,
				Stage . ": a refused request must leave no job behind")
			_RWI_LeaveStage()
		}
		; The control: the same request starts a worker once the hand-off is gone,
		; so the refusals above came from the hand-off and nothing else.
		AssertFalse(ReloadTerminalHandoffActive())
		_RWI_PrefetchSpawns := 0
		AssertTrue(KLPF_RequestBuild("apps", MetricsDir, "full", 0,
			_RWI_Terminal, false),
			"a projection must start again once no reload is under way")
		AssertEqual(1, _RWI_PrefetchSpawns)
	} finally {
		KLPF_CancelAll()
		KLPFWorker.jobs := OldJobs
		KLPFWorker.generation := OldGeneration
		KLPFWorker.spawn_fn := OldSpawn
		KLPFWorker.range_delete_fn := OldRangeDelete
		_RTP_Cleanup(Bundle)
	}
}
Test("reload: no prefetch worker starts while a hand-off exists "
	. "(reload-worker-identity)", _RWI_PrefetchWorkerWaitsForTheReload)

_RWI_UiaWorkerWaitsForTheReload() {
	global _UIASW_TestSpawnCount, _UIASW_TestTerminateCount
	Saved := Map()
	for Field in ["handle", "worker_hwnd", "worker_process_handle",
			"worker_generation", "pending", "start_deadline_fn",
			"start_failure_tick", "start_diagnostic", "spawn_fn",
			"open_process_fn", "terminate_process_fn", "close_process_fn"]
		Saved[Field] := UIASWState.%Field%
	Bundle := _RTP_Acquire("worker-identity-uia")
	Port := _RTP_NewPort()
	try {
		for Field in ["handle", "worker_hwnd", "worker_process_handle", "pending",
				"start_deadline_fn", "start_failure_tick"]
			UIASWState.%Field% := 0
		UIASWState.spawn_fn := _UIASW_TestSpawn
		UIASWState.open_process_fn := _UIASW_TestOpenProcess
		UIASWState.terminate_process_fn := _UIASW_TestTerminateProcess
		UIASWState.close_process_fn := _UIASW_TestCloseProcess
		for Stage in ["authorized", "pending"] {
			_UIASW_TestSpawnCount := 0
			_RWI_EnterStage(Stage, Bundle, Port)
			AssertFalse(UIASW_Start(),
				Stage . ": the UIA worker must not start beside a reload successor")
			AssertEqual(0, _UIASW_TestSpawnCount,
				Stage . ": a compiled UIA worker shares the driver's window title")
			AssertEqual(0, UIASWState.start_failure_tick,
				Stage . ": a start refused for a reload is not a failure to back off from")
			_RWI_LeaveStage()
		}
		_UIASW_TestSpawnCount := 0
		AssertTrue(UIASW_Start(),
			"the UIA worker must start again once no reload is under way")
		AssertEqual(1, _UIASW_TestSpawnCount)
	} finally {
		UIASW_Stop("canceled")
		for Field, Value in Saved
			UIASWState.%Field% := Value
		_RTP_Cleanup(Bundle)
	}
}
Test("reload: no UIA worker starts while a hand-off exists "
	. "(reload-worker-identity)", _RWI_UiaWorkerWaitsForTheReload)

; A record whose claim could not be rearmed stays published for good, and no
; successor of it is alive: it must not keep the workers out for the rest of
; the session.
_RWI_OnlyALiveHandoffKeepsWorkersOut() {
	global _ReloadTerminalHandoff
	Bundle := _RTP_Acquire("worker-identity-stuck")
	try {
		Record := ReloadTerminalHandoffPrepare(Bundle)
		AssertTrue(Record is Map)
		AssertTrue(ReloadTerminalHandoffActive())
		Record["state"] := "cancel_failed"
		AssertFalse(ReloadTerminalHandoffActive(),
			"a record that failed to cancel has no successor to protect")
		Record["state"] := "authorized"
	} finally _RTP_Cleanup(Bundle)
	AssertFalse(ReloadTerminalHandoffActive())
}
Test("reload: only a live hand-off keeps the workers out "
	. "(reload-worker-identity)", _RWI_OnlyALiveHandoffKeepsWorkersOut)
