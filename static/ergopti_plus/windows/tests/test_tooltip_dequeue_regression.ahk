; tests/test_tooltip_dequeue_regression.ahk

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
; 1. IsObject(0) is false — the guard correctly blocks iteration of the sentinel.
; 2. IsObject([]) and IsObject([{...}]) are true — normal dequeue arrays pass
;    through the guard and are iterated correctly.
; 3. The MaxMs accumulation logic is correct for a mix of expired (ExpireMs = 0)
;    and live (ExpireMs > 0) rows — mirrors the exact arithmetic in
;    _TooltipDequeueRebuild.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Dequeue Sentinel Guard (the crash-causing path) =======
; ==================================================================
; ==================================================================

; Simulate what _TooltipDequeueRebuild now does: snapshot + IsObject guard.
; Before the fix this was a bare `for , Item in _TooltipDequeueItems` — when
; the global held 0 (integer sentinel) AHK v2 threw "Value not enumerable".
_SimulateDequeueRebuildMaxMs(DequeueItemsGlobal, NowMs) {
	MaxMs := 0
	DequeueSnapshot := DequeueItemsGlobal
	if IsObject(DequeueSnapshot) {
		for , Item in DequeueSnapshot {
			if (Item.ExpireMs > 0) {
				Remaining := Max(50, Item.ExpireMs - NowMs)
				if (Remaining > MaxMs)
					MaxMs := Remaining
			}
		}
	}
	return MaxMs
}

_RunTooltipDequeueRegressionTests() {


	; =========================================================================
	; ===== 1.1) Integer sentinel (0) must not be enumerated =====
	; =========================================================================

	; This is the exact state that caused the crash: TooltipHide() set
	; _TooltipDequeueItems := 0 and a concurrent rebuild tried to iterate it.
	Test("dequeue regression: IsObject(0) == false (guard prevents enumeration of sentinel)", () => {
		Assert(!IsObject(0),
			"IsObject(0) must be false — 0 is the integer sentinel, not an array")
	})

	Test("dequeue regression: _SimulateDequeueRebuildMaxMs returns 0 when items is integer 0", () => {
		Result := _SimulateDequeueRebuildMaxMs(0, 1000)
		AssertEqual(0, Result,
			"When _TooltipDequeueItems is 0 (sentinel), MaxMs must be 0 — not a crash")
	})


	; =========================================================================
	; ===== 1.2) Empty array must pass the guard and return 0 =====
	; =========================================================================

	Test("dequeue regression: empty dequeue array returns MaxMs 0 without crash", () => {
		Result := _SimulateDequeueRebuildMaxMs([], 1000)
		AssertEqual(0, Result,
			"Empty dequeue array must return 0 (no items to expire)")
	})


	; =====================================================================
	; ===== 1.3) Live rows: MaxMs reflects the furthest expiry =====
	; =====================================================================

	; Two rows both still alive: ExpireMs 1500 and 2000 relative to Now=1000.
	; Remaining values: Max(50, 500)=500 and Max(50, 1000)=1000. MaxMs = 1000.
	Test("dequeue regression: MaxMs = furthest remaining deadline", () => {
		Items := [
			{ ExpireMs: 1500 },
			{ ExpireMs: 2000 },
		]
		Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
		AssertEqual(1000, Result,
			"MaxMs must equal the largest remaining-ms value across live rows")
	})


	; =====================================================================
	; ===== 1.4) Rows with ExpireMs 0 (infinite) are skipped =====
	; =====================================================================

	Test("dequeue regression: rows with ExpireMs=0 do not contribute to MaxMs", () => {
		Items := [
			{ ExpireMs: 0 },
			{ ExpireMs: 0 },
		]
		Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
		AssertEqual(0, Result,
			"Infinite rows (ExpireMs=0) must not set MaxMs")
	})


	; =====================================================================
	; ===== 1.5) Mixed: infinite + live — only live contributes =====
	; =====================================================================

	; One infinite row (ExpireMs=0) plus one live row expiring at 1800.
	; Remaining = Max(50, 800) = 800. MaxMs must be 800.
	Test("dequeue regression: mixed rows — only live row contributes to MaxMs", () => {
		Items := [
			{ ExpireMs: 0 },
			{ ExpireMs: 1800 },
		]
		Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
		AssertEqual(800, Result,
			"Only the live row must set MaxMs; the infinite row must be ignored")
	})


	; =====================================================================
	; ===== 1.6) 50 ms floor is enforced for nearly-expired rows =====
	; =====================================================================

	; Row whose deadline is only 10 ms in the future — Max(50, 10) = 50.
	Test("dequeue regression: 50 ms floor applied to nearly-expired rows", () => {
		Items := [{ ExpireMs: 1010 }]
		Result := _SimulateDequeueRebuildMaxMs(Items, 1000)
		AssertEqual(50, Result,
			"Remaining deadlines shorter than 50 ms must be clamped to 50")
	})
}

_RunTooltipDequeueRegressionTests()
