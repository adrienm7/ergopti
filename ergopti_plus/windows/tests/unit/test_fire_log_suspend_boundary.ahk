; tests/unit/test_fire_log_suspend_boundary.ahk

; ==============================================================================
; MODULE: AHK-22 Deferred Fire-Log Suspend Boundary Regression
; DESCRIPTION:
; Drives the real prefix-watcher queue/drain and the real KL_LogHotstring sink
; against the recording keylogger/ROI/WPM stubs. A fired record belongs to the
; lifecycle generation that armed its timer. If pause wins the 90 ms race, that
; callback must not call the destructive buffer flush, append a row, mutate ROI,
; or push WPM state; the record remains queued and a fresh resume owner emits it
; exactly once. This encodes the state-transfer mechanism, not merely a source
; spelling, so moving the guard below KL_FlushBuffer makes the test fail.
; ==============================================================================

#Requires AutoHotkey v2.0

global _FLSB_GuardCalls := 0





; =====================================================
; =====================================================
; ======= 1/ Pause retains and resume owns once =======
; =====================================================
; =====================================================

_FLSB_PauseRetainsAndResumeOwnsOnce() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration, _PrefixRenderScheduledGeneration
	global _PrefixRenderTimer
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls
	global _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	global _Stub_FlushBufferMutates

	SavedQueue := _HSE_FireLogQueue
	SavedScheduled := _HSE_FireLogScheduled
	SavedScheduledGeneration := _HSE_FireLogScheduledGeneration
	SavedTimer := _HSE_FireLogTimer
	SavedDeferredGeneration := _PrefixDeferredGeneration
	SavedRenderScheduledGeneration := _PrefixRenderScheduledGeneration
	SavedRenderTimer := _PrefixRenderTimer
	SavedAppendRows := _Stub_AppendLogRows
	SavedRoiCalls := _Stub_RoiHotstringCalls
	SavedWpmCalls := _Stub_WpmPushCalls
	SavedFlushCalls := _Stub_FlushBufferCalls
	SavedFlushMutates := _Stub_FlushBufferMutates
	SavedInitialized := Keylogger.initialized
	SavedShuttingDown := Keylogger._shutting_down
	SavedBufferText := Keylogger.buffer_text
	SavedBufferEvents := Keylogger.buffer_events
	SavedRichChunks := Keylogger.rich_chunks
	SavedSessionClicks := Keylogger.session_clicks
	SavedSessionScrolls := Keylogger.session_scrolls
	SavedMouseDistance := Keylogger.mouse_distance

	; Suppress the real one-shot while exercising ownership synchronously.
	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	_HSE_FireLogTimer := 0
	_PrefixDeferredGeneration := 41
	_PrefixRenderScheduledGeneration := -1
	_PrefixRenderTimer := 0
	_HSE_FireLogScheduledGeneration := 41
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	_Stub_FlushBufferMutates := true
	Keylogger.initialized := true
	Keylogger._shutting_down := false
	Keylogger.buffer_text := "typed-before-fire"
	Keylogger.buffer_events := [["t", 10, Map("s", 0)]]
	Keylogger.rich_chunks := []
	Keylogger.session_clicks := 0
	Keylogger.session_scrolls := 0
	Keylogger.mouse_distance := 0

	try {
		Assert(_HSE_QueueFireLog("pex", "par exemple", "endchar",
			"magickey", "abbreviations"),
			"AHK-22 setup: the fire must enter the deferred queue")
		AssertEqual(1, _HSE_FireLogQueue.Length,
			"AHK-22 setup: exactly one fired record must be queued")

		; Simulate the timer winning after native Suspend changed state but before
		; the lifecycle watchdog ran. The override affects the real drain only;
		; A_IsSuspended remains false in the runner, so any accidental sink call is
		; observable through the recording stubs.
		AssertFalse(_HSE_DrainFireLog(41, true),
			"AHK-22: a drain that observes pause must relinquish ownership")
		AssertEqual(1, _HSE_FireLogQueue.Length,
			"AHK-22: a paused attempt must retain the fired batch for resume")
		AssertEqual("typed-before-fire", Keylogger.buffer_text,
			"AHK-22: pre-pause typing state must remain intact")
		AssertEqual(0, _Stub_FlushBufferCalls,
			"AHK-22: the pause guard must run before KL_FlushBuffer")
		AssertEqual(0, _Stub_AppendLogRows.Length,
			"AHK-22: no hotstring row may publish while paused")
		AssertEqual(0, _Stub_RoiHotstringCalls.Length,
			"AHK-22: ROI state must not mutate while paused")
		AssertEqual(0, _Stub_WpmPushCalls.Length,
			"AHK-22: WPM state must not mutate while paused")

		HotstringPrefixWatcherOnSuspend()
		AssertFalse(_HSE_DrainFireLog(41, false),
			"AHK-22: the pre-pause callback must remain stale after the lifecycle generation changes")
		AssertEqual(1, _HSE_FireLogQueue.Length,
			"AHK-22: a stale callback must not consume the retained batch")

		; ArmTimer=false publishes a fresh owner without leaving a real timer in the
		; runner. Invoke that owner once, then replay it to prove idempotence.
		Assert(HotstringPrefixWatcherOnResume(false),
			"AHK-22: resume must transfer a retained batch to a fresh owner")
		ResumeGeneration := _HSE_FireLogScheduledGeneration
		Assert(_HSE_DrainFireLog(ResumeGeneration, false),
			"AHK-22: the resumed owner must drain the retained batch")
		AssertEqual(0, _HSE_FireLogQueue.Length,
			"AHK-22: resume must consume the retained record")
		AssertEqual(1, _Stub_FlushBufferCalls,
			"AHK-22: the retained typing buffer must flush exactly once")
		AssertEqual("", Keylogger.buffer_text,
			"AHK-22: the resumed owner must clear the retained typing buffer after accepting it")
		AssertEqual(0, Keylogger.buffer_events.Length,
			"AHK-22: the resumed owner must consume the retained typing events exactly once")
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"AHK-22: resume must emit exactly one hotstring row")
		AssertEqual(1, _Stub_RoiHotstringCalls.Length,
			"AHK-22: resume must apply ROI exactly once")
		AssertEqual(StrLen("par exemple"), _Stub_WpmPushCalls.Length,
			"AHK-22: resume must apply the WPM samples exactly once")

		AssertFalse(_HSE_DrainFireLog(ResumeGeneration, false),
			"AHK-22: a consumed owner cannot publish twice")
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"AHK-22: replaying the callback must not duplicate the row")
		AssertEqual(1, _Stub_RoiHotstringCalls.Length,
			"AHK-22: replaying the callback must not duplicate ROI")
		AssertEqual(StrLen("par exemple"), _Stub_WpmPushCalls.Length,
			"AHK-22: replaying the callback must not duplicate WPM samples")
	} finally {
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogQueue := SavedQueue
		_HSE_FireLogScheduled := SavedScheduled
		_HSE_FireLogScheduledGeneration := SavedScheduledGeneration
		_HSE_FireLogTimer := SavedTimer
		_PrefixDeferredGeneration := SavedDeferredGeneration
		_PrefixRenderScheduledGeneration := SavedRenderScheduledGeneration
		_PrefixRenderTimer := SavedRenderTimer
		_Stub_AppendLogRows := SavedAppendRows
		_Stub_RoiHotstringCalls := SavedRoiCalls
		_Stub_WpmPushCalls := SavedWpmCalls
		_Stub_FlushBufferCalls := SavedFlushCalls
		_Stub_FlushBufferMutates := SavedFlushMutates
		Keylogger.initialized := SavedInitialized
		Keylogger._shutting_down := SavedShuttingDown
		Keylogger.buffer_text := SavedBufferText
		Keylogger.buffer_events := SavedBufferEvents
		Keylogger.rich_chunks := SavedRichChunks
		Keylogger.session_clicks := SavedSessionClicks
		Keylogger.session_scrolls := SavedSessionScrolls
		Keylogger.mouse_distance := SavedMouseDistance
	}
}

Test("AHK-22 fire-log-suspend-boundary: pause retains and resume emits exactly once",
	_FLSB_PauseRetainsAndResumeOwnsOnce)

; Simulates lifecycle invalidation between the sink's entry guard and the
; destructive KL_FlushBuffer boundary. The production generation predicate is
; pure; this deterministic seam changes its verdict on the second observation.
_FLSB_ExpireOnSecondCheck() {
	global _FLSB_GuardCalls
	_FLSB_GuardCalls += 1
	return _FLSB_GuardCalls < 2
}

_FLSB_MidSinkLifecycleLossStopsBeforeFlush() {
	global _FLSB_GuardCalls, _Stub_AppendLogRows, _Stub_RoiHotstringCalls
	global _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	global _Stub_FlushBufferMutates
	SavedInitialized := Keylogger.initialized
	SavedShuttingDown := Keylogger._shutting_down
	SavedAppendRows := _Stub_AppendLogRows
	SavedRoiCalls := _Stub_RoiHotstringCalls
	SavedWpmCalls := _Stub_WpmPushCalls
	SavedFlushCalls := _Stub_FlushBufferCalls
	SavedFlushMutates := _Stub_FlushBufferMutates
	SavedBufferText := Keylogger.buffer_text
	SavedBufferEvents := Keylogger.buffer_events
	_FLSB_GuardCalls := 0
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	_Stub_FlushBufferMutates := true
	Keylogger.initialized := true
	Keylogger._shutting_down := false
	Keylogger.buffer_text := "still-owned"
	Keylogger.buffer_events := [["s", 5, Map("s", 0)]]
	try {
		AssertFalse(KL_LogHotstring("pex", "par exemple", "endchar", "",
			"magickey", "abbreviations", false, _FLSB_ExpireOnSecondCheck),
			"AHK-22: a generation expiring inside the sink must return the fire to its queue owner")
		Assert(_FLSB_GuardCalls >= 2,
			"AHK-22 setup: the lifecycle predicate must expire at the flush boundary")
		AssertEqual(0, _Stub_FlushBufferCalls,
			"AHK-22: lifecycle ownership must be rechecked inside KL_FlushBuffer before its destructive snapshot")
		AssertEqual("still-owned", Keylogger.buffer_text,
			"AHK-22: mid-sink lifecycle loss must leave the pre-pause typing buffer untouched")
		AssertEqual(1, Keylogger.buffer_events.Length,
			"AHK-22: mid-sink lifecycle loss must leave the pre-pause typing events untouched")
		AssertEqual(0, _Stub_AppendLogRows.Length,
			"AHK-22: an expired mid-sink owner must not append the fire row")
		AssertEqual(0, _Stub_RoiHotstringCalls.Length,
			"AHK-22: an expired mid-sink owner must not mutate ROI")
		AssertEqual(0, _Stub_WpmPushCalls.Length,
			"AHK-22: an expired mid-sink owner must not mutate WPM")
	} finally {
		Keylogger.initialized := SavedInitialized
		Keylogger._shutting_down := SavedShuttingDown
		_Stub_AppendLogRows := SavedAppendRows
		_Stub_RoiHotstringCalls := SavedRoiCalls
		_Stub_WpmPushCalls := SavedWpmCalls
		_Stub_FlushBufferCalls := SavedFlushCalls
		_Stub_FlushBufferMutates := SavedFlushMutates
		Keylogger.buffer_text := SavedBufferText
		Keylogger.buffer_events := SavedBufferEvents
		_FLSB_GuardCalls := 0
	}
}

Test("AHK-22 fire-log-suspend-boundary: mid-sink generation loss stops before flush",
	_FLSB_MidSinkLifecycleLossStopsBeforeFlush)





; =============================================================
; =============================================================
; ======= 2/ Sink terminal outcomes remain exactly once =======
; =============================================================
; =============================================================

_FLSB_InvalidateDuringAppend(*) {
	HotstringPrefixWatcherOnSuspend()
}

_FLSB_AcceptedAppendIsNeverReplayed() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration, _PrefixRenderScheduledGeneration
	global _PrefixRenderTimer, _PrefixVisibleFireDecisions
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls
	global _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	global _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend
	global _Stub_AppendLogHook

	SavedQueue := _HSE_FireLogQueue
	SavedScheduled := _HSE_FireLogScheduled
	SavedScheduledGeneration := _HSE_FireLogScheduledGeneration
	SavedTimer := _HSE_FireLogTimer
	SavedDeferredGeneration := _PrefixDeferredGeneration
	SavedRenderScheduledGeneration := _PrefixRenderScheduledGeneration
	SavedRenderTimer := _PrefixRenderTimer
	SavedAppendRows := _Stub_AppendLogRows
	SavedRoiCalls := _Stub_RoiHotstringCalls
	SavedWpmCalls := _Stub_WpmPushCalls
	SavedFlushCalls := _Stub_FlushBufferCalls
	SavedAppendAccept := _Stub_AppendLogAccept
	SavedAppendRejectSuspend := _Stub_AppendLogRejectSuspend
	SavedAppendHook := _Stub_AppendLogHook
	SavedInitialized := Keylogger.initialized
	SavedShuttingDown := Keylogger._shutting_down

	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	_HSE_FireLogScheduledGeneration := 73
	_HSE_FireLogTimer := 0
	_PrefixDeferredGeneration := 73
	_PrefixRenderScheduledGeneration := -1
	_PrefixRenderTimer := 0
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	_Stub_AppendLogAccept := true
	_Stub_AppendLogRejectSuspend := false
	_Stub_AppendLogHook := _FLSB_InvalidateDuringAppend
	Keylogger.initialized := true
	Keylogger._shutting_down := false

	try {
		Assert(_HSE_QueueFireLog("brb", "be right back", "endchar",
			"text_expansion", "english"),
			"AHK-22 setup: the fire must enter the owned queue")
		Assert(_HSE_DrainFireLog(73, false),
			"AHK-22: an accepted canonical row remains consumed when pause lands immediately after its append")
		AssertEqual(0, _HSE_FireLogQueue.Length,
			"AHK-22: an accepted row must not return to the queue")
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"AHK-22: the canonical hotstring row must append exactly once")
		AssertEqual(0, _Stub_RoiHotstringCalls.Length,
			"AHK-22: lifecycle loss after append must suppress the remaining ROI sink")
		AssertEqual(0, _Stub_WpmPushCalls.Length,
			"AHK-22: lifecycle loss after append must suppress the remaining WPM sink")
		AssertFalse(HotstringPrefixWatcherOnResume(false),
			"AHK-22: resume must not re-arm a fire whose canonical row was accepted")
		AssertFalse(_HSE_DrainFireLog(73, false),
			"AHK-22: the stale pre-pause owner must remain unable to replay")
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"AHK-22: neither resume nor stale callback replay may duplicate an accepted row")
	} finally {
		_Stub_AppendLogHook := 0
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogQueue := SavedQueue
		_HSE_FireLogScheduled := SavedScheduled
		_HSE_FireLogScheduledGeneration := SavedScheduledGeneration
		_HSE_FireLogTimer := SavedTimer
		_PrefixDeferredGeneration := SavedDeferredGeneration
		_PrefixRenderScheduledGeneration := SavedRenderScheduledGeneration
		_PrefixRenderTimer := SavedRenderTimer
		_Stub_AppendLogRows := SavedAppendRows
		_Stub_RoiHotstringCalls := SavedRoiCalls
		_Stub_WpmPushCalls := SavedWpmCalls
		_Stub_FlushBufferCalls := SavedFlushCalls
		_Stub_AppendLogAccept := SavedAppendAccept
		_Stub_AppendLogRejectSuspend := SavedAppendRejectSuspend
		_Stub_AppendLogHook := SavedAppendHook
		Keylogger.initialized := SavedInitialized
		Keylogger._shutting_down := SavedShuttingDown
	}
}

Test("AHK-22 fire-log-suspend-boundary: accepted append is never replayed",
	_FLSB_AcceptedAppendIsNeverReplayed)

_FLSB_SuspendRejectedAppendRetriesOnce() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration, _PrefixRenderScheduledGeneration
	global _PrefixRenderTimer
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls
	global _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	global _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend
	global _Stub_AppendLogHook

	SavedQueue := _HSE_FireLogQueue
	SavedScheduled := _HSE_FireLogScheduled
	SavedScheduledGeneration := _HSE_FireLogScheduledGeneration
	SavedTimer := _HSE_FireLogTimer
	SavedDeferredGeneration := _PrefixDeferredGeneration
	SavedRenderScheduledGeneration := _PrefixRenderScheduledGeneration
	SavedRenderTimer := _PrefixRenderTimer
	SavedAppendRows := _Stub_AppendLogRows
	SavedRoiCalls := _Stub_RoiHotstringCalls
	SavedWpmCalls := _Stub_WpmPushCalls
	SavedFlushCalls := _Stub_FlushBufferCalls
	SavedAppendAccept := _Stub_AppendLogAccept
	SavedAppendRejectSuspend := _Stub_AppendLogRejectSuspend
	SavedAppendHook := _Stub_AppendLogHook
	SavedInitialized := Keylogger.initialized
	SavedShuttingDown := Keylogger._shutting_down

	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	_HSE_FireLogScheduledGeneration := 81
	_HSE_FireLogTimer := 0
	_PrefixDeferredGeneration := 81
	_PrefixRenderScheduledGeneration := -1
	_PrefixRenderTimer := 0
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	_Stub_AppendLogAccept := false
	_Stub_AppendLogRejectSuspend := true
	_Stub_AppendLogHook := 0
	Keylogger.initialized := true
	Keylogger._shutting_down := false

	try {
		Assert(_HSE_QueueFireLog("omw", "on my way", "endchar",
			"text_expansion", "english"),
			"AHK-22 setup: the retryable fire must enter the owned queue")
		AssertFalse(_HSE_DrainFireLog(81, false),
			"AHK-22: a sink that observes native Suspend must reject consumption")
		AssertEqual(1, _HSE_FireLogQueue.Length,
			"AHK-22: a suspend-refused append must return the current record to the queue")
		AssertEqual(0, _Stub_AppendLogRows.Length,
			"AHK-22: a suspend-refused append must not publish a row")

		HotstringPrefixWatcherOnSuspend()
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		Assert(HotstringPrefixWatcherOnResume(false),
			"AHK-22: resume must transfer the rejected record to one fresh owner")
		ResumeGeneration := _HSE_FireLogScheduledGeneration
		Assert(_HSE_DrainFireLog(ResumeGeneration, false),
			"AHK-22: the fresh owner must consume the formerly rejected row")
		AssertEqual(0, _HSE_FireLogQueue.Length,
			"AHK-22: the successful retry must empty the queue")
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"AHK-22: the successful retry must append exactly once")
		AssertFalse(_HSE_DrainFireLog(ResumeGeneration, false),
			"AHK-22: the consumed retry owner cannot replay")
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"AHK-22: callback replay must not duplicate the retried row")
	} finally {
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogQueue := SavedQueue
		_HSE_FireLogScheduled := SavedScheduled
		_HSE_FireLogScheduledGeneration := SavedScheduledGeneration
		_HSE_FireLogTimer := SavedTimer
		_PrefixDeferredGeneration := SavedDeferredGeneration
		_PrefixRenderScheduledGeneration := SavedRenderScheduledGeneration
		_PrefixRenderTimer := SavedRenderTimer
		_Stub_AppendLogRows := SavedAppendRows
		_Stub_RoiHotstringCalls := SavedRoiCalls
		_Stub_WpmPushCalls := SavedWpmCalls
		_Stub_FlushBufferCalls := SavedFlushCalls
		_Stub_AppendLogAccept := SavedAppendAccept
		_Stub_AppendLogRejectSuspend := SavedAppendRejectSuspend
		_Stub_AppendLogHook := SavedAppendHook
		Keylogger.initialized := SavedInitialized
		Keylogger._shutting_down := SavedShuttingDown
	}
}

Test("AHK-22 fire-log-suspend-boundary: suspend-rejected append retries once",
	_FLSB_SuspendRejectedAppendRetriesOnce)

_FLSB_PrivacyDropIsTerminalAcrossPause() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration, _PrefixRenderScheduledGeneration
	global _PrefixRenderTimer
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls
	global _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	global _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend
	global _Stub_AppendLogHook

	SavedQueue := _HSE_FireLogQueue
	SavedScheduled := _HSE_FireLogScheduled
	SavedScheduledGeneration := _HSE_FireLogScheduledGeneration
	SavedTimer := _HSE_FireLogTimer
	SavedDeferredGeneration := _PrefixDeferredGeneration
	SavedRenderScheduledGeneration := _PrefixRenderScheduledGeneration
	SavedRenderTimer := _PrefixRenderTimer
	SavedAppendRows := _Stub_AppendLogRows
	SavedRoiCalls := _Stub_RoiHotstringCalls
	SavedWpmCalls := _Stub_WpmPushCalls
	SavedFlushCalls := _Stub_FlushBufferCalls
	SavedAppendAccept := _Stub_AppendLogAccept
	SavedAppendRejectSuspend := _Stub_AppendLogRejectSuspend
	SavedAppendHook := _Stub_AppendLogHook
	SavedInitialized := Keylogger.initialized
	SavedShuttingDown := Keylogger._shutting_down

	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	_HSE_FireLogScheduledGeneration := 97
	_HSE_FireLogTimer := 0
	_PrefixDeferredGeneration := 97
	_PrefixRenderScheduledGeneration := -1
	_PrefixRenderTimer := 0
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	_Stub_AppendLogAccept := false
	_Stub_AppendLogRejectSuspend := false
	_Stub_AppendLogHook := _FLSB_InvalidateDuringAppend
	Keylogger.initialized := true
	Keylogger._shutting_down := false

	try {
		Assert(_HSE_QueueFireLog("secret", "withheld", "endchar",
			"personal", "private", true),
			"AHK-22 setup: the privacy-filtered fire must enter the owned queue")
		Assert(_HSE_DrainFireLog(97, false),
			"AHK-22: a privacy drop is a terminal consumption even when pause lands during the filter")
		AssertEqual(0, _HSE_FireLogQueue.Length,
			"AHK-22: privacy-filtered data must never survive for replay under a later foreground window")
		AssertEqual(0, _Stub_AppendLogRows.Length,
			"AHK-22: the privacy drop must publish no canonical row")
		AssertEqual(0, _Stub_RoiHotstringCalls.Length,
			"AHK-22: the privacy drop must publish no ROI state")
		AssertEqual(0, _Stub_WpmPushCalls.Length,
			"AHK-22: the privacy drop must publish no WPM state")
		AssertFalse(HotstringPrefixWatcherOnResume(false),
			"AHK-22: resume must not re-arm privacy-filtered data")
	} finally {
		_Stub_AppendLogHook := 0
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogQueue := SavedQueue
		_HSE_FireLogScheduled := SavedScheduled
		_HSE_FireLogScheduledGeneration := SavedScheduledGeneration
		_HSE_FireLogTimer := SavedTimer
		_PrefixDeferredGeneration := SavedDeferredGeneration
		_PrefixRenderScheduledGeneration := SavedRenderScheduledGeneration
		_PrefixRenderTimer := SavedRenderTimer
		_Stub_AppendLogRows := SavedAppendRows
		_Stub_RoiHotstringCalls := SavedRoiCalls
		_Stub_WpmPushCalls := SavedWpmCalls
		_Stub_FlushBufferCalls := SavedFlushCalls
		_Stub_AppendLogAccept := SavedAppendAccept
		_Stub_AppendLogRejectSuspend := SavedAppendRejectSuspend
		_Stub_AppendLogHook := SavedAppendHook
		Keylogger.initialized := SavedInitialized
		Keylogger._shutting_down := SavedShuttingDown
	}
}

Test("AHK-22 fire-log-suspend-boundary: privacy drop is terminal across pause",
	_FLSB_PrivacyDropIsTerminalAcrossPause)

_FLSB_ShutdownDrainsRetainedBatchOnce() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _HSE_FireLogScheduledGeneration, _HSE_FireLogTimer
	global _PrefixDeferredGeneration, _PrefixRenderScheduledGeneration
	global _PrefixRenderTimer, _PrefixVisibleFireDecisions
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls
	global _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	global _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend
	global _Stub_AppendLogHook

	SavedQueue := _HSE_FireLogQueue
	SavedScheduled := _HSE_FireLogScheduled
	SavedScheduledGeneration := _HSE_FireLogScheduledGeneration
	SavedTimer := _HSE_FireLogTimer
	SavedDeferredGeneration := _PrefixDeferredGeneration
	SavedRenderScheduledGeneration := _PrefixRenderScheduledGeneration
	SavedRenderTimer := _PrefixRenderTimer
	SavedVisibleDecisions := _PrefixVisibleFireDecisions
	SavedAppendRows := _Stub_AppendLogRows
	SavedRoiCalls := _Stub_RoiHotstringCalls
	SavedWpmCalls := _Stub_WpmPushCalls
	SavedFlushCalls := _Stub_FlushBufferCalls
	SavedAppendAccept := _Stub_AppendLogAccept
	SavedAppendRejectSuspend := _Stub_AppendLogRejectSuspend
	SavedAppendHook := _Stub_AppendLogHook
	SavedInitialized := Keylogger.initialized
	SavedShuttingDown := Keylogger._shutting_down

	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	_HSE_FireLogScheduledGeneration := 109
	_HSE_FireLogTimer := 0
	_PrefixDeferredGeneration := 109
	_PrefixRenderScheduledGeneration := -1
	_PrefixRenderTimer := 0
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	_Stub_AppendLogAccept := true
	_Stub_AppendLogRejectSuspend := false
	_Stub_AppendLogHook := 0
	Keylogger.initialized := true
	Keylogger._shutting_down := true

	try {
		Assert(_HSE_QueueFireLog("fyi", "for your information", "endchar",
			"text_expansion", "english"),
			"AHK-22 setup: the pre-shutdown fire must enter the owned queue")
		HotstringPrefixWatcherOnSuspend()
		AssertEqual(1, _HSE_FireLogQueue.Length,
			"AHK-22 setup: suspend must retain the pre-shutdown fire")
		VisibleSentinel := [{ FireDecision: "keep-visible-until-commit" }]
		_PrefixVisibleFireDecisions := VisibleSentinel
		GenerationBeforePrepare := _PrefixDeferredGeneration
		Assert(HotstringPrefixWatcherPrepareShutdown(),
			"AHK-22: reversible shutdown preparation must terminalize the retained batch")
		AssertEqual(0, _HSE_FireLogQueue.Length,
			"AHK-22: preparation must leave no retained fire behind")
		AssertEqual(1, _Stub_AppendLogRows.Length,
			"AHK-22: preparation must append the retained canonical row exactly once")
		AssertTrue(_PrefixVisibleFireDecisions == VisibleSentinel,
			"a refusal-capable preparation must preserve visible decisions")
		AssertEqual(GenerationBeforePrepare, _PrefixDeferredGeneration,
			"a refusal-capable preparation must not invalidate render owners")

		; A sink refusal must likewise preserve both the batch and all live UI
		; owners, so OnExit can return to a fully functional driver.
		_Stub_AppendLogRejectSuspend := true
		Assert(_HSE_QueueFireLog("brb", "be right back", "endchar",
			"text_expansion", "english"))
		RefusalSentinel := [{ FireDecision: "keep-on-refusal" }]
		_PrefixVisibleFireDecisions := RefusalSentinel
		AssertFalse(HotstringPrefixWatcherPrepareShutdown())
		AssertEqual(1, _HSE_FireLogQueue.Length)
		AssertTrue(_PrefixVisibleFireDecisions == RefusalSentinel)
		AssertEqual(GenerationBeforePrepare, _PrefixDeferredGeneration)
		_Stub_AppendLogRejectSuspend := false
		Assert(HotstringPrefixWatcherPrepareShutdown(),
			"the retained refusal batch must remain drainable on retry")

		Assert(HotstringPrefixWatcherOnShutdown(),
			"irreversible shutdown may retire callbacks after every gate accepted")
		Assert(HotstringPrefixWatcherOnShutdown(),
			"AHK-22: an empty repeated shutdown drain must remain idempotent")
		AssertEqual(2, _Stub_AppendLogRows.Length,
			"AHK-22: repeated shutdown callbacks must not duplicate a terminalized row")
	} finally {
		TimerCancel(_HSE_FireLogTimer)
		_HSE_FireLogQueue := SavedQueue
		_HSE_FireLogScheduled := SavedScheduled
		_HSE_FireLogScheduledGeneration := SavedScheduledGeneration
		_HSE_FireLogTimer := SavedTimer
		_PrefixDeferredGeneration := SavedDeferredGeneration
		_PrefixRenderScheduledGeneration := SavedRenderScheduledGeneration
		_PrefixRenderTimer := SavedRenderTimer
		_PrefixVisibleFireDecisions := SavedVisibleDecisions
		_Stub_AppendLogRows := SavedAppendRows
		_Stub_RoiHotstringCalls := SavedRoiCalls
		_Stub_WpmPushCalls := SavedWpmCalls
		_Stub_FlushBufferCalls := SavedFlushCalls
		_Stub_AppendLogAccept := SavedAppendAccept
		_Stub_AppendLogRejectSuspend := SavedAppendRejectSuspend
		_Stub_AppendLogHook := SavedAppendHook
		Keylogger.initialized := SavedInitialized
		Keylogger._shutting_down := SavedShuttingDown
	}
}

Test("AHK-22 fire-log-suspend-boundary: shutdown drains retained batch once",
	_FLSB_ShutdownDrainsRetainedBatchOnce)
