; tests/unit/hotstrings/engine/prefix/test_deferred_pause.ahk

; ==============================================================================
; MODULE: Prefix Watcher Deferred Work Under Pause
; DESCRIPTION:
; Native Suspend does not stop SetTimer callbacks, so the prefix watcher's
; deferred work refuses to run while the driver is paused:
;   - _PrefixDeferredCanPublish, the shared predicate, refuses a paused driver
;     and a stale lifecycle generation (LOW-02);
;   - _PrefixRenderFlush retires its timer slot and paints nothing while paused
;     (LOW-02);
;   - HotstringPrefixWatcherRebuildIndex leaves the live index untouched and
;     records the request so the resume replays it (F19,
;     prefix-index-rebuild-no-suspend-guard).
; The render case holds the send suppression, so an unguarded flush would stop
; before any tooltip; the render queue latency sample it records first is what
; shows whether it passed the pause gate.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ The shared predicate =======
; =======================================
; =======================================

_PDP_PredicateRefusesPauseAndStaleGeneration() {
	global _PrefixDeferredGeneration
	WasSuspended := A_IsSuspended
	try {
		Suspend(false)
		Current := _PrefixDeferredGeneration
		AssertTrue(_PrefixDeferredCanPublish(Current), "a current, running lifecycle may publish")
		AssertFalse(_PrefixDeferredCanPublish(Current + 1), "a stale generation may never publish")
		AssertFalse(_PrefixDeferredCanPublish(Current, true), "an explicit pause override refuses")
		Suspend(true)
		AssertFalse(_PrefixDeferredCanPublish(Current), "a paused driver may not publish deferred prefix work")
		AssertTrue(_PrefixDeferredCanPublish(Current, false),
			"the override replaces the native pause reading for its caller")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
	}
}
Test("prefix deferred work: the shared predicate refuses a pause and a stale generation (LOW-02)",
	_PDP_PredicateRefusesPauseAndStaleGeneration)





; ==============================================
; ==============================================
; ======= 2/ The deferred preview render =======
; ==============================================
; ==============================================

_PDP_RenderQueueSamples() {
	Series := _HotPathStatisticsOwner().Stats.Series
	return Series.Has("Prefix.RenderQueue") ? Series["Prefix.RenderQueue"].Count : 0
}

_PDP_FlushOnce(Generation) {
	global _PrefixRenderScheduledGeneration, _PrefixRenderTimer, _PrefixRenderQueuedWallMs
	_PrefixRenderScheduledGeneration := Generation
	_PrefixRenderTimer := 0
	_PrefixRenderQueuedWallMs := BootClockWallMs() - 5
	_PrefixRenderFlush(Generation)
}

_PDP_PausedRenderPaintsNothing() {
	global _PrefixDeferredGeneration, _PrefixRenderScheduledGeneration, _PrefixRenderTimer
	global _PrefixRenderQueuedWallMs, HSE_Suppressed
	Saved := [_PrefixRenderScheduledGeneration, _PrefixRenderTimer, _PrefixRenderQueuedWallMs, HSE_Suppressed]
	WasSuspended := A_IsSuspended
	try {
		HSE_Suppressed += 1
		Generation := _PrefixDeferredGeneration
		Before := _PDP_RenderQueueSamples()
		Suspend(true)
		_PDP_FlushOnce(Generation)
		AssertEqual(-1, _PrefixRenderScheduledGeneration, "a paused flush must still retire its own timer slot")
		AssertEqual(Before, _PDP_RenderQueueSamples(), "a paused flush must stop at the pause gate")
		Suspend(false)
		_PDP_FlushOnce(Generation)
		AssertEqual(Before + 1, _PDP_RenderQueueSamples(), "positive control: a running flush passes the pause gate")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		_PrefixRenderScheduledGeneration := Saved[1]
		_PrefixRenderTimer := Saved[2]
		_PrefixRenderQueuedWallMs := Saved[3]
		HSE_Suppressed := Saved[4]
	}
}
Test("prefix deferred work: a paused render flush paints nothing (LOW-02)", _PDP_PausedRenderPaintsNothing)





; ====================================
; ====================================
; ======= 3/ The index rebuild =======
; ====================================
; ====================================

_PDP_PausedRebuildDefers() {
	global _PrefixInputHook, _PrefixIndex, _TriggerSet, _PrefixIndexRebuildPending
	Saved := [_PrefixInputHook, _PrefixIndex, _TriggerSet, _PrefixIndexRebuildPending]
	WasSuspended := A_IsSuspended
	try {
		; Any live hook passes the first gate; the paused rebuild never touches it.
		_PrefixInputHook := {}
		Index := Map()
		Triggers := Map()
		_PrefixIndex := Index
		_TriggerSet := Triggers
		_PrefixIndexRebuildPending := false
		Suspend(true)
		HotstringPrefixWatcherRebuildIndex()
		AssertTrue(_PrefixIndexRebuildPending, "a paused rebuild must record its request for the resume replay (F19)")
		AssertTrue(_PrefixIndex == Index && _TriggerSet == Triggers,
			"a paused rebuild must leave the live preview index untouched")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		_PrefixInputHook := Saved[1]
		_PrefixIndex := Saved[2]
		_TriggerSet := Saved[3]
		_PrefixIndexRebuildPending := Saved[4]
	}
}
Test("prefix deferred work: a paused index rebuild defers to the resume (F19)", _PDP_PausedRebuildDefers)
