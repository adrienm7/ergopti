; tests/meta/test_keylogger_prefetch_worker.ahk

; ============================================================================== 
; MODULE: Keylogger Prefetch Worker Regression Test
; DESCRIPTION:
; The metrics projection contains SQLite reconstruction and JSON encoding that
; can take seconds.  These guards keep that work in a detached /force worker
; and prove that a superseded completion cannot publish stale dashboard data.
; ============================================================================== 

#Requires AutoHotkey v2.0

_KLPFW_ReadWorkerContract() {
	Request := _DriverFuncBody("KLPF_RequestBuild")
	Done := _DriverFuncBody("KLPF_OnWorkerDone")
	Worker := _DriverFuncBody("KLPF_WorkerMain")
	First := _DriverFuncBody("KLWV_DelayedFirstPush")
	Full := _DriverFuncBody("KLWV_DelayedFullBuild")
	NotifyBody := _DriverFuncBody("KLWV_NotifyIngest")
	Bridge := _DriverFuncBody("KLWV_OnWebMessage")
	Edge := _DriverFuncBody("KLUI_LaunchWindow")
	SuspendBody := _DriverFuncBody("Ergopti_OnSuspendEnter")

	Assert(Request != "" && Done != "" && Worker != "",
		"keylogger prefetch worker lifecycle functions must exist")
	Assert(InStr(Request, "ShellRunner_Spawn") > 0 && InStr(Request, '"/force"') > 0,
		"KLPF_RequestBuild must start a detached /force worker instead of projecting on the AHK hook thread")
	Assert(InStr(Request, "++KLPFWorker.generation") > 0
			&& InStr(Request, '"stage"') > 0,
		"each worker request must allocate a monotonic generation and private staging path")
	Assert(InStr(Done, 'job["generation"] != generation') > 0
			&& InStr(Done, "KLPF_MoveAtomic(stage, KLPF_PrefetchPath(which))") > 0,
		"only the current generation may atomically publish its staged JSON")
	Assert(InStr(Worker, "KLPF_BuildAndWriteToPath") > 0
			&& InStr(Worker, "ExitApp(0)") > 0,
		"the worker must produce its own staged file then exit before normal driver boot")

	for _, body in [First, Full, NotifyBody, Bridge, Edge] {
		Assert(InStr(body, "KLPF_BuildAndWrite(") = 0,
			"WebView/Edge entry points must never synchronously run KLPF_BuildAndWrite")
		Assert(InStr(body, "KLPF_RequestBuild(") > 0,
			"WebView/Edge entry points must use the worker protocol")
	}
	Assert(InStr(SuspendBody, 'KLPF_CancelBuild("typing")') > 0
			&& InStr(SuspendBody, 'KLPF_CancelBuild("apps")') > 0,
		"Suspend must terminate both in-flight metrics workers instead of letting SQLite continue while paused")
}

Test("keylogger: prefetch projection is staged by a generation-fenced detached worker",
	_KLPFW_ReadWorkerContract)

global _KLPFW_FakeTerminated := 0
global _KLPFW_FakeArgs := []

_KLPFW_FakeStart(*) {
	return true
}

_KLPFW_FakeTerminate(*) {
	global _KLPFW_FakeTerminated
	_KLPFW_FakeTerminated += 1
}

_KLPFW_FakeSpawn(executable, args, done) {
	global _KLPFW_FakeArgs
	_KLPFW_FakeArgs.Push(Map("executable", executable, "args", args, "done", done))
	handle := {}
	handle.start := _KLPFW_FakeStart
	handle.terminate := _KLPFW_FakeTerminate
	return handle
}

_KLPFW_GenerationFenceRunsWithoutProjection() {
	global _KLPFW_FakeTerminated, _KLPFW_FakeArgs
	old_jobs := KLPFWorker.jobs
	old_generation := KLPFWorker.generation
	old_spawn := KLPFWorker.spawn_fn
	_KLPFW_FakeTerminated := 0
	_KLPFW_FakeArgs := []
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
	try {
		started := A_TickCount
		Assert(KLPF_RequestBuild("typing", A_Temp . "\\metrics", "live"),
			"a projection request must publish an async worker job immediately")
		first_generation := KLPFWorker.jobs["typing"]["generation"]
		Assert(KLPF_RequestBuild("typing", A_Temp . "\\metrics", "live"),
			"a newer projection request must replace the prior worker job")
		Assert((A_TickCount - started) < 100,
			"requesting a projection must only spawn work; it must not execute SQLite/JSON on the caller thread")
		Assert(_KLPFW_FakeTerminated = 1,
			"a newer request must terminate the prior worker process tree")
		Assert(KLPFWorker.jobs["typing"]["generation"] > first_generation,
			"a replacement worker must receive a strictly newer generation")
		KLPF_OnWorkerDone("typing", first_generation, 0, "", "")
		Assert(KLPFWorker.jobs["typing"]["generation"] > first_generation,
			"a late completion must not remove or mutate the newer live job")
	} finally {
		KLPF_CancelBuild("typing")
		KLPFWorker.jobs := old_jobs
		KLPFWorker.generation := old_generation
		KLPFWorker.spawn_fn := old_spawn
	}
}

Test("keylogger: stale prefetch-worker completion cannot evict a newer job",
	_KLPFW_GenerationFenceRunsWithoutProjection)
