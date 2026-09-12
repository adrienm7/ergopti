; tests/unit/test_metrics_full_retry_cadence.ahk

; ==============================================================================
; MODULE: Full Metrics Retry Cadence Tests
; DESCRIPTION: Manifest notifications cannot bypass bounded historical retries.
; ==============================================================================

#Requires AutoHotkey v2.0

_MFR_WithFixture(Scenario) {
	global _KLPFW_FakeArgs, _KLPFW_FakeTerminated
	global _KLPFW_FullBuildTimers, _KLPFW_IngestDrainTimers
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := [KLWV.windows, KLWV.metrics_dir, KLWV.full_build_timer_fn,
		KLWV.ingest_drain_timer_fn, KLPFWorker.jobs, KLPFWorker.generation,
		KLPFWorker.spawn_fn, _KLPFW_FakeArgs, _KLPFW_FakeTerminated,
		_KLPFW_FullBuildTimers, _KLPFW_IngestDrainTimers, A_IsSuspended]
	try {
		Root := _KLRDC_Root()
		KLWV.windows := Map("typing", Map("epoch", 501, "first_paint_done", true,
			"full_build_done", false, "metrics_dir", Root))
		KLWV.metrics_dir := Root
		KLWV.full_build_timer_fn := _KLPFW_FullBuildTimer
		KLWV.ingest_drain_timer_fn := _KLPFW_IngestDrainTimer
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
		_KLPFW_FakeArgs := []
		_KLPFW_FakeTerminated := 0
		_KLPFW_FullBuildTimers := []
		_KLPFW_IngestDrainTimers := []
		Scenario.Call()
	} finally {
		KLWV.windows := Map()
		try KLPF_CancelBuild("typing")
		finally {
			KLWV.windows := Saved[1]
			KLWV.metrics_dir := Saved[2]
			KLWV.full_build_timer_fn := Saved[3]
			KLWV.ingest_drain_timer_fn := Saved[4]
			KLPFWorker.jobs := Saved[5]
			KLPFWorker.generation := Saved[6]
			KLPFWorker.spawn_fn := Saved[7]
			_KLPFW_FakeArgs := Saved[8]
			_KLPFW_FakeTerminated := Saved[9]
			_KLPFW_FullBuildTimers := Saved[10]
			_KLPFW_IngestDrainTimers := Saved[11]
			Suspend(Saved[12])
			_KLRDC_Cleanup()
		}
	}
}

_MFR_FailActive() {
	Generation := KLPFWorker.jobs["typing"]["generation"]
	KLPF_OnWorkerDone("typing", Generation, 1, "", "fixture failure")
}

_MFR_DrainAll() {
	global _KLPFW_IngestDrainTimers
	while _KLPFW_IngestDrainTimers.Length
		_KLPFW_IngestDrainTimers.RemoveAt(1)["callback"].Call()
}

_MFR_ManifestDrainKeepsRetryOwner() {
	global _KLPFW_FakeArgs, _KLPFW_FullBuildTimers, _KLPFW_IngestDrainTimers
	AssertTrue(KLWV_DelayedFullBuild("typing", 501, 0))
	KLWV_NotifyIngest("manifest")
	AssertEqual("manifest", KLWV.windows["typing"]["pending_ingest_mode"])
	_MFR_FailActive()
	AssertEqual(1, _KLPFW_FullBuildTimers.Length, "failure must schedule the bounded retry")
	AssertEqual(-KLWV.FULL_BUILD_RETRY_MS, _KLPFW_FullBuildTimers[1]["period"])
	AssertEqual(1, _KLPFW_IngestDrainTimers.Length, "the coalesced manifest must reach its drain")
	_MFR_DrainAll()
	AssertFalse(KLPFWorker.jobs.Has("typing"), "a manifest-only drain must wait for the existing retry owner")
	AssertEqual(1, _KLPFW_FakeArgs.Length, "the drain must not launch attempt zero again")
	AssertFalse(KLWV_DelayedFullBuild("typing", 501), "an old initial-build timer must respect the retry too")
	_KLPFW_FullBuildTimers.RemoveAt(1)["callback"].Call()
	AssertTrue(KLPFWorker.jobs.Has("typing"), "the delayed retry must still be able to recover")
	AssertEqual(2, _KLPFW_FakeArgs.Length)
}
Test("metrics retries: coalesced manifest cannot bypass historical backoff (metrics-full-retry-cadence)",
	_KLRDC_CheckTeardown.Bind(_MFR_WithFixture.Bind(_MFR_ManifestDrainKeepsRetryOwner)))

_MFR_ExhaustionRecoversAfterCommit() {
	global _KLPFW_FakeArgs, _KLPFW_FullBuildTimers
	AssertTrue(KLWV_DelayedFullBuild("typing", 501))
	Loop KLWV.FULL_BUILD_MAX_RETRIES + 1 {
		KLWV_NotifyIngest("manifest")
		_MFR_FailActive()
		_MFR_DrainAll()
		AssertFalse(KLPFWorker.jobs.Has("typing"))
		if A_Index <= KLWV.FULL_BUILD_MAX_RETRIES
			_KLPFW_FullBuildTimers.RemoveAt(1)["callback"].Call()
	}
	AssertTrue(KLWV.windows["typing"]["full_build_retry_exhausted"])
	AssertEqual(0, _KLPFW_FullBuildTimers.Length)
	Loop 8
		KLWV_NotifyIngest("manifest")
	AssertEqual(KLWV.FULL_BUILD_MAX_RETRIES + 1, _KLPFW_FakeArgs.Length)
	KLWV_RecordCommittedIngest()
	AssertFalse(KLPFWorker.jobs.Has("typing"), "recording a busy-keyboard commit must not start work")
	AssertEqual("live", KLWV.windows["typing"]["pending_ingest_mode"])
	KLWV_NotifyIngest("manifest")
	AssertTrue(KLPFWorker.jobs.Has("typing"), "the deferred commit must admit recovery")
	AssertEqual(KLWV.FULL_BUILD_MAX_RETRIES + 2, _KLPFW_FakeArgs.Length)
}
Test("metrics retries: exhaustion retains deferred committed input (metrics-full-retry-cadence)",
	_KLRDC_CheckTeardown.Bind(_MFR_WithFixture.Bind(_MFR_ExhaustionRecoversAfterCommit)))

_MFR_CommitDuringWorker() {
	global _KLPFW_FakeArgs, _KLPFW_FullBuildTimers
	AssertTrue(KLWV_DelayedFullBuild("typing", 501))
	KLWV_RecordCommittedIngest()
	_MFR_FailActive()
	AssertEqual(0, _KLPFW_FullBuildTimers.Length, "new committed input supersedes retrying the old input")
	_MFR_DrainAll()
	AssertEqual(2, _KLPFW_FakeArgs.Length)
	AssertEqual(1, KLWV.windows["typing"]["full_build_requested_revision"])
}
Test("metrics retries: a commit during the failed worker owns immediate recovery (metrics-full-retry-cadence)",
	_KLRDC_CheckTeardown.Bind(_MFR_WithFixture.Bind(_MFR_CommitDuringWorker)))

_MFR_StaleTimerCannotBorrowSuccessor() {
	global _KLPFW_FakeArgs, _KLPFW_FullBuildTimers
	AssertTrue(KLWV_DelayedFullBuild("typing", 501))
	_MFR_FailActive()
	Old := _KLPFW_FullBuildTimers.RemoveAt(1)["callback"]
	KLWV_NotifyIngest("live")
	_MFR_FailActive()
	Owner := KLWV.windows["typing"]["full_build_retry_owner"]
	Old.Call()
	AssertFalse(KLPFWorker.jobs.Has("typing"), "an old timer must not start the successor's equal-numbered attempt")
	AssertTrue(KLWV.windows["typing"]["full_build_retry_owner"] = Owner)
	AssertEqual(2, _KLPFW_FakeArgs.Length)
	_KLPFW_FullBuildTimers.RemoveAt(1)["callback"].Call()
	AssertEqual(3, _KLPFW_FakeArgs.Length)
}
Test("metrics retries: stale timer cannot borrow a successor revision (metrics-full-retry-cadence)",
	_KLRDC_CheckTeardown.Bind(_MFR_WithFixture.Bind(_MFR_StaleTimerCannotBorrowSuccessor)))

_MFR_TimerRefusalKeepsRecovery() {
	KLWV.full_build_timer_fn := (*) => false
	AssertTrue(KLWV_DelayedFullBuild("typing", 501))
	_MFR_FailActive()
	AssertFalse(KLWV.windows["typing"].Has("full_build_retry_owner"), "a refused timer cannot retain phantom ownership")
	KLWV_NotifyIngest("manifest")
	AssertFalse(KLPFWorker.jobs.Has("typing"))
	KLWV_NotifyIngest("live")
	AssertTrue(KLPFWorker.jobs.Has("typing"), "new committed data must recover after scheduler refusal")
}
Test("metrics retries: scheduler refusal releases ownership and admits new input (metrics-full-retry-cadence)",
	_KLRDC_CheckTeardown.Bind(_MFR_WithFixture.Bind(_MFR_TimerRefusalKeepsRecovery)))

_MFR_PausedRetryWithNewInput() {
	global _KLPFW_FullBuildTimers, _KLPFW_FakeArgs
	AssertTrue(KLWV_DelayedFullBuild("typing", 501))
	_MFR_FailActive()
	Suspend(true)
	_KLPFW_FullBuildTimers.RemoveAt(1)["callback"].Call()
	AssertTrue(KLWV.windows["typing"].Has("pending_full_build_retry"))
	KLWV_RecordCommittedIngest()
	Suspend(false)
	KLWV_OnSuspendResume()
	_KLPFW_FullBuildTimers.RemoveAt(1)["callback"].Call()
	AssertFalse(KLPFWorker.jobs.Has("typing"), "resume must not resurrect a retry for older input")
	_MFR_DrainAll()
	AssertEqual(2, _KLPFW_FakeArgs.Length)
}
Test("metrics retries: resume preserves fresh committed input over an old retry (metrics-full-retry-cadence)",
	_KLRDC_CheckTeardown.Bind(_MFR_WithFixture.Bind(_MFR_PausedRetryWithNewInput)))
