; tests/unit/test_tooltip_dequeue_regression.ahk

; ==============================================================================
; MODULE: Tooltip Dequeue Regression Tests
; DESCRIPTION:
; Regression tests for the "Value not enumerable" crash that occurred when
; _TooltipDequeueRebuild tried to iterate _TooltipDequeueItems after a
; concurrent TooltipHide() had already reset it to 0 (the integer sentinel).
;
; ROOT CAUSE:
; _TooltipDequeueRebuild read _TooltipDequeueItems from the global at line 650
; without snapshotting it first. A concurrent reset (timer, suspend, or a
; build-fail branch) could set it to 0 between the _TooltipBuildGui() call and
; the for-loop. AHK v2 throws "Value not enumerable" when a for-loop iterates
; an integer. The fix snapshots _TooltipDequeueItems into a local and guards
; with IsObject() before iterating.
;
; WHAT THESE TESTS ENCODE:
; 1. IsObject(0) is false: the guard correctly blocks iteration of the sentinel.
; 2. IsObject([]) and IsObject([{...}]) are true: normal dequeue arrays pass
;    through the guard and are iterated correctly.
; 3. The MaxMs accumulation logic is correct for a mix of infinite and live
;    wrap-safe origin/duration rows, mirroring the exact arithmetic in
;    _TooltipDequeueRebuild.
;
; NOTE (AHK v2.0): tests are registered via named functions, not inline
; "() => { ... }" block lambdas. A block-body fat arrow is a v2.1-only construct;
; under the v2.0 runtime the CI pins it parses as an object literal and aborts
; the whole suite at load time ("Missing propertyname:"). Named functions keep
; the suite parseable on v2.0.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Dequeue Sentinel Guard (the crash-causing path) =======
; ==================================================================
; ==================================================================

; Simulate what _TooltipDequeueRebuild now does: snapshot + IsObject guard.
; Before the fix this was a bare `for , Item in _TooltipDequeueItems` - when
; the global held 0 (integer sentinel) AHK v2 threw "Value not enumerable".
_SimulateDequeueRebuildMaxMs(DequeueItemsGlobal, NowMs) {
	MaxMs := 0
	DequeueSnapshot := DequeueItemsGlobal
	if IsObject(DequeueSnapshot) {
		for , Item in DequeueSnapshot {
			if (Item.ExpireDurationMs > 0) {
				Remaining := TickRemaining(
					Item.ExpireOriginTick, Item.ExpireDurationMs, NowMs)
				if (Remaining > MaxMs)
					MaxMs := Remaining
			}
		}
	}
	return MaxMs
}





; ===================================
; ===================================
; ======= 2/ Registered Tests =======
; ===================================
; ===================================




; ============================================================
; ===== 2.1) Integer sentinel (0) must not be enumerated =====
; ============================================================

; This is the exact state that caused the crash: TooltipHide() set
; _TooltipDequeueItems := 0 and a concurrent rebuild tried to iterate it.
_TestTooltipDequeue_SentinelIsNotObject() {
	Assert(!IsObject(0),
		"IsObject(0) must be false - 0 is the integer sentinel, not an array")
}
Test("dequeue regression: IsObject(0) == false (guard prevents enumeration of sentinel)",
	_TestTooltipDequeue_SentinelIsNotObject)

_TestTooltipDequeue_SentinelReturnsZero() {
	Result := _SimulateDequeueRebuildMaxMs(0, 1000)
	AssertEqual(0, Result,
		"When _TooltipDequeueItems is 0 (sentinel), MaxMs must be 0 - not a crash")
}
Test("dequeue regression: _SimulateDequeueRebuildMaxMs returns 0 when items is integer 0",
	_TestTooltipDequeue_SentinelReturnsZero)




; =============================================================
; ===== 2.2) Empty array must pass the guard and return 0 =====
; =============================================================

_TestTooltipDequeue_EmptyArrayReturnsZero() {
	Result := _SimulateDequeueRebuildMaxMs([], 1000)
	AssertEqual(0, Result,
		"Empty dequeue array must return 0 (no items to expire)")
}
Test("dequeue regression: empty dequeue array returns MaxMs 0 without crash",
	_TestTooltipDequeue_EmptyArrayReturnsZero)




; ==============================================================
; ===== 2.3) Live rows: MaxMs reflects the furthest expiry =====
; ==============================================================

; Two rows both still alive with 500 ms and 1000 ms remaining at Now=1000.
; Remaining values: Max(50, 500)=500 and Max(50, 1000)=1000. MaxMs = 1000.
_TestTooltipDequeue_FurthestDeadline() {
	Items := [
		{ ExpireOriginTick: 1000, ExpireDurationMs: 500 },
		{ ExpireOriginTick: 1000, ExpireDurationMs: 1000 },
	]
	Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
	AssertEqual(1000, Result,
		"MaxMs must equal the largest remaining-ms value across live rows")
}
Test("dequeue regression: MaxMs = furthest remaining deadline",
	_TestTooltipDequeue_FurthestDeadline)




; ============================================================
; ===== 2.4) Rows with duration 0 (infinite) are skipped =====
; ============================================================

_TestTooltipDequeue_InfiniteRowsSkipped() {
	Items := [
		{ ExpireOriginTick: 1000, ExpireDurationMs: 0 },
		{ ExpireOriginTick: 1000, ExpireDurationMs: 0 },
	]
	Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
	AssertEqual(0, Result,
		"Infinite rows (duration=0) must not set MaxMs")
}
Test("dequeue regression: rows with duration=0 do not contribute to MaxMs",
	_TestTooltipDequeue_InfiniteRowsSkipped)




; ===============================================================
; ===== 2.5) Mixed: infinite + live - only live contributes =====
; ===============================================================

; One infinite row plus one live row with 800 ms remaining.
; Remaining = Max(50, 800) = 800. MaxMs must be 800.
_TestTooltipDequeue_MixedOnlyLiveContributes() {
	Items := [
		{ ExpireOriginTick: 1000, ExpireDurationMs: 0 },
		{ ExpireOriginTick: 1000, ExpireDurationMs: 800 },
	]
	Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
	AssertEqual(800, Result,
		"Only the live row must set MaxMs; the infinite row must be ignored")
}
Test("dequeue regression: mixed rows - only live row contributes to MaxMs",
	_TestTooltipDequeue_MixedOnlyLiveContributes)




; ================================================================
; ===== 2.6) Canonical deadline remainder stays exact ===========
; ================================================================

; A supplied absolute deadline is engine-owned. Extending 10 ms to an arbitrary
; 50 ms leaves a visible suggestion after the action it advertises can fire.
_TestTooltipDequeue_ExactCanonicalRemainder() {
	Items := [{ ExpireOriginTick: 1000, ExpireDurationMs: 10 }]
	Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
	AssertEqual(10, Result,
		"an absolute deadline remainder must never be extended by the timer floor")
}
Test("dequeue regression: canonical deadline keeps its exact short remainder",
	_TestTooltipDequeue_ExactCanonicalRemainder)

; The renderer may be interrupted after an early remainder sample. Production
; carries only origin/duration into the pixel transaction and resolves again at
; that fence, so a 10 ms sample can never be armed after a 100 ms yield.
_TestTooltipDeadlinePlan_RecomputesAtPixelCommit() {
	Items := [{
		Text: "candidate",
		DurationSec: 0,
		ExpireOriginTick: 1000,
		ExpireDurationMs: 100
	}]
	Plan := _TooltipCreateLifecyclePlan(Items, 0, 9999)
	Early := _TooltipLifecycleDeadlineBounds(Plan, 1090)
	AssertEqual(false, Early.Expired)
	AssertEqual(10, Early.EarliestMs)
	AssertEqual(10, Early.LatestMs)

	AfterYield := _TooltipLifecycleDeadlineBounds(Plan, 1190)
	AssertEqual(true, AfterYield.Expired,
		"the pixel fence must recompute from the canonical origin/duration; it must not arm the stale 10 ms remainder sampled before a yield")
	AssertEqual(0, AfterYield.EarliestMs)
	AssertEqual(0, AfterYield.LatestMs)
}
Test("tooltip deadline: stale pre-yield remainder expires at pixel commit",
	_TestTooltipDeadlinePlan_RecomputesAtPixelCommit)

_TestTooltipDeadlinePlan_OneFenceOwnsEarliestAndLatest() {
	Items := [
		{ Text: "short", DurationSec: 0,
			ExpireOriginTick: 1000, ExpireDurationMs: 100 },
		{ Text: "long", DurationSec: 0,
			ExpireOriginTick: 1000, ExpireDurationMs: 500 }
	]
	Plan := _TooltipCreateLifecyclePlan(Items, 0, 9999)
	Bounds := _TooltipLifecycleDeadlineBounds(Plan, 1050)
	AssertEqual(false, Bounds.Expired)
	AssertEqual(50, Bounds.EarliestMs,
		"the exact destack timer must use the shortest current remainder")
	AssertEqual(450, Bounds.LatestMs,
		"the safety owner must use the longest current remainder from the same fence")
}
Test("tooltip deadline: one pixel fence derives earliest and latest owners",
	_TestTooltipDeadlinePlan_OneFenceOwnsEarliestAndLatest)


; A starts preparing at generation 1. While its detached GUI work pumps the
; message queue, B commits generation 2. When A reaches the selector it must
; neither become active nor retire B. This is the behavioral core of the real
; Row.Gui.Show / border-build re-entrance that previously let A destroy B.
_TestTooltipSurfaceCommit_StaleCandidateCannotRetireNewOwner() {
	SurfaceA := { Name: "A", HideCount: 0, DestroyCount: 0 }
	SurfaceB := { Name: "B", HideCount: 0, DestroyCount: 0 }
	Active := SurfaceB
	PublishedDecision := "B"
	Selection := _TooltipChoosePreparedSurface(1, 2, Active, SurfaceA)
	if Selection.Committed {
		if IsObject(Selection.Retired)
			Selection.Retired.HideCount += 1
		Active := Selection.Active
		PublishedDecision := "A"
	}
	if IsObject(Selection.Retired)
		Selection.Retired.DestroyCount += 1
	AssertEqual(false, Selection.Committed,
		"A must lose after B advances the immutable render generation")
	AssertEqual("B", Active.Name,
		"a stale A commit must leave B active")
	AssertEqual(0, Selection.Retired,
		"a stale A commit must return no retired surface for disposal")
	AssertEqual(0, SurfaceB.HideCount,
		"A losing its fence must never hide B")
	AssertEqual(0, SurfaceB.DestroyCount,
		"A cleanup must never destroy B")
	AssertEqual("B", PublishedDecision,
		"A losing its fence must leave B's published decision unchanged")
}
Test("tooltip surface commit: re-entrant B cannot be retired by stale A",
	_TestTooltipSurfaceCommit_StaleCandidateCannotRetireNewOwner)

; The repeating poll snapshots A, then yields while selecting/filtering rows.
; B commits before A resumes. Generation alone is not enough if the callback
; later reaches a force-hide branch; the captured surface identity must lose too.
_TestTooltipDequeuePoll_StaleSnapshotCannotHideNewOwner() {
	SurfaceA := { Name: "A", Generation: 1 }
	SurfaceB := { Name: "B", Generation: 2 }
	HideB := 0
	RebuildB := 0
	RepublishA := 0
	RearmA := 0
	if _TooltipSurfaceOwnerMatches(1, 2, SurfaceA, SurfaceB) {
		HideB += 1
		RebuildB += 1
		RepublishA += 1
		RearmA += 1
	}
	AssertEqual(false,
		_TooltipSurfaceOwnerMatches(1, 2, SurfaceA, SurfaceB),
		"poll A must lose after B publishes a distinct generation/surface owner")
	AssertEqual(0, HideB,
		"a resumed stale poll must not force-hide B")
	AssertEqual(0, RebuildB,
		"a resumed stale poll must not destack/re-publish over B")
	AssertEqual(0, RepublishA,
		"A must not republish its stale visible decision after B")
	AssertEqual(0, RearmA,
		"A must not rearm its safety/deadline timer against B")
}
Test("tooltip dequeue poll: A snapshot cannot hide or rebuild over B",
	_TestTooltipDequeuePoll_StaleSnapshotCannotHideNewOwner)

; Deferred callback A may already have detached its tuple when request B arrives.
; The immutable record prevents field splicing; the monotonic serial prevents A
; from reaching pixel commit while B still waits on the debounce timer.
_TestTooltipDeferredRequest_AbaTupleAndResumeAreRejected() {
	RequestA := {
		Items: ["A"], DurationSec: 1, ArmSafety: false,
		OriginMs: 100, Serial: 1
	}
	RequestB := {
		Items: ["B"], DurationSec: 9, ArmSafety: true,
		OriginMs: 900, Serial: 2
	}
	Pending := RequestA
	TakenA := Pending
	; B is published after A snapshots. A's final exact-owner clear must not
	; alter any field in B's still-pending immutable tuple.
	Pending := RequestB
	if (IsObject(Pending) and ObjPtr(Pending) == ObjPtr(TakenA))
		Pending := 0
	AssertTrue(IsObject(Pending),
		"resumed A must not clear B's pending record")
	AssertEqual("B", Pending.Items[1])
	AssertEqual(9, Pending.DurationSec)
	AssertEqual(true, Pending.ArmSafety)
	AssertEqual(900, Pending.OriginMs)
	AssertEqual(false,
		_TooltipRequestOwnerMatches(TakenA.Serial, Pending.Serial),
		"A must lose if it resumes after B is requested")
	AssertEqual(true,
		_TooltipRequestOwnerMatches(RequestB.Serial, Pending.Serial),
		"B remains the only deferred owner")
}
Test("tooltip deferred request: immutable B tuple survives resumed A",
	_TestTooltipDeferredRequest_AbaTupleAndResumeAreRejected)
