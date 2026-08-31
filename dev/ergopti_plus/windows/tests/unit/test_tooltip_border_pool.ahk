; tests/unit/test_tooltip_border_pool.ahk

; ==============================================================================
; MODULE: Tooltip Border Pool Regression Tests
; DESCRIPTION:
; Proves ordinary tooltip updates reuse one immutable layered-border surface
; instead of rebuilding its Gui, DIB, DC and pen. The test measures 100 real
; updates, tracks exact pool ownership, bounds GDI growth and exercises terminal
; cleanup plus pool-cap eviction.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Measurement helpers ===
; ==================================
; ==================================

_TBP_Qpc() {
	Counter := 0
	DllCall("Kernel32\QueryPerformanceCounter", "Int64*", &Counter)
	return Counter
}

_TBP_Percentile(Values, Fraction) {
	Sorted := []
	for , Value in Values {
		Inserted := false
		Loop Sorted.Length {
			if (Value < Sorted[A_Index]) {
				Sorted.InsertAt(A_Index, Value)
				Inserted := true
				break
			}
		}
		if !Inserted
			Sorted.Push(Value)
	}
	return Sorted[Max(1, Min(Sorted.Length, Ceil(Sorted.Length * Fraction)))]
}

_TBP_GdiCount() {
	return DllCall("User32\GetGuiResources", "Ptr",
		DllCall("Kernel32\GetCurrentProcess", "Ptr"),
		"UInt", 0, "UInt")
}





; =========================================================
; =========================================================
; ======= 2/ Reuse, latency and exact cleanup =============
; =========================================================
; =========================================================

_TBP_OrdinaryUpdatesReuseOneBorder() {
	global TOOLTIP_BORDER_POOL_MAX
	SavedMax := TOOLTIP_BORDER_POOL_MAX
	TooltipReleaseRenderResources()
	CreatedBefore := TooltipBorderPoolStats.created
	ReusedBefore := TooltipBorderPoolStats.reused
	DestroyedBefore := TooltipBorderPoolStats.destroyed
	GdiBefore := _TBP_GdiCount()
	FirstHwnd := 0
	try {
		TOOLTIP_BORDER_POOL_MAX := 8
		First := _TooltipBuildBorder(10, 10, 260, 48)
		AssertTrue(IsObject(First), "the real layered border must be created")
		FirstHwnd := First.Hwnd
		AssertTrue(_TooltipRecycleBorder(First),
			"the detached border must enter the bounded pool")

		Frequency := 0
		DllCall("Kernel32\QueryPerformanceFrequency", "Int64*", &Frequency)
		Samples := []
		Loop 100 {
			Started := _TBP_Qpc()
			Border := _TooltipBuildBorder(10 + A_Index, 20, 260, 48)
			AssertEqual(FirstHwnd, Border.Hwnd,
				"ordinary same-size updates must reuse the exact layered window")
			AssertTrue(_TooltipRecycleBorder(Border))
			Samples.Push((_TBP_Qpc() - Started) * 1000 / Frequency)
		}

		P95 := _TBP_Percentile(Samples, 0.95)
		Assert(P95 < 5,
			"pooled border update p95 must stay below the 5 ms input-safe budget; actual="
			. Round(P95, 3) . " ms")
		AssertEqual(1, TooltipBorderPoolStats.created - CreatedBefore,
			"100 same-size updates must allocate exactly one layered border")
		AssertEqual(100, TooltipBorderPoolStats.reused - ReusedBefore,
			"every update after warmup must be a pool hit")
		AssertEqual(1, TooltipBorderPoolStats.pooled,
			"the exact reusable owner must be hidden in the pool")
		Assert(_TBP_GdiCount() <= GdiBefore + 2,
			"warm pooled updates must not accumulate GDI handles")

		AssertEqual(1, TooltipReleaseRenderResources(),
			"terminal cleanup must destroy the one pooled border")
		AssertEqual(0, TooltipBorderPoolStats.pooled)
		AssertEqual(1, TooltipBorderPoolStats.destroyed - DestroyedBefore)
		AssertFalse(DllCall("User32\IsWindow", "Ptr", FirstHwnd, "Int"),
			"cleanup must destroy the retained native layered window")
		FirstHwnd := 0
	} finally {
		TooltipReleaseRenderResources()
		TOOLTIP_BORDER_POOL_MAX := SavedMax
		if FirstHwnd && DllCall("User32\IsWindow", "Ptr", FirstHwnd, "Int")
			try DllCall("User32\DestroyWindow", "Ptr", FirstHwnd)
	}
}

Test("tooltip border: 100 ordinary updates reuse one bounded GDI owner (tooltip-present-layered-reallocation)",
	_TBP_OrdinaryUpdatesReuseOneBorder)

_TBP_CompletePresentPreparationMeetsBudget() {
	TooltipReleaseRenderResources()
	Frequency := 0
	DllCall("Kernel32\QueryPerformanceFrequency", "Int64*", &Frequency)
	Samples := []
	ClampSamples := []
	ShowSamples := []
	CornerSamples := []
	BorderSamples := []
	try {
		Loop 100 {
			Row := _TooltipBuildGui([{
				Text: "ordinary tooltip update",
				ColorHex: "6A5ACD",
				DurationSec: 1.0
			}])
			Surface := _TooltipCreateDetachedSurface(Row, A_Index)
			Started := _TBP_Qpc()
			Pos := _TooltipClampToScreen(120, 120, Row.W, Row.H)
			AfterClamp := _TBP_Qpc()
			_TooltipPositionPreparedContent(Row, Pos.X, Pos.Y)
			AfterShow := _TBP_Qpc()
			_TooltipApplyStackedCorners(Row)
			AfterCorners := _TBP_Qpc()
			Surface.Border := _TooltipBuildBorder(
				Pos.X, Pos.Y, Row.W, Row.H)
			AfterBorder := _TBP_Qpc()
			if Surface.Border
				Surface.BorderHwnds := [Surface.Border.Hwnd]
			Samples.Push((AfterBorder - Started) * 1000 / Frequency)
			ClampSamples.Push((AfterClamp - Started) * 1000 / Frequency)
			ShowSamples.Push((AfterShow - AfterClamp) * 1000 / Frequency)
			CornerSamples.Push((AfterCorners - AfterShow) * 1000 / Frequency)
			BorderSamples.Push((AfterBorder - AfterCorners) * 1000 / Frequency)
			_TooltipDisposeRetired(Surface)
		}
		P95 := _TBP_Percentile(Samples, 0.95)
		Assert(P95 < 5,
			"complete ordinary Present preparation p95 must stay below 5 ms; actual="
			. Round(P95, 3) . " ms, clamp="
			. Round(_TBP_Percentile(ClampSamples, 0.95), 3) . ", show="
			. Round(_TBP_Percentile(ShowSamples, 0.95), 3) . ", corners="
			. Round(_TBP_Percentile(CornerSamples, 0.95), 3) . ", border="
			. Round(_TBP_Percentile(BorderSamples, 0.95), 3))
		Assert(TooltipBorderPoolStats.reused >= 99,
			"the complete preparation path must consume the border pool")
	} finally {
		TooltipReleaseRenderResources()
	}
}

Test("tooltip present: 100 complete ordinary preparations stay input-safe (tooltip-present-layered-reallocation)",
	_TBP_CompletePresentPreparationMeetsBudget)

_TBP_PoolCapEvictsAndCleanupReapsAll() {
	global TOOLTIP_BORDER_POOL_MAX
	SavedMax := TOOLTIP_BORDER_POOL_MAX
	TooltipReleaseRenderResources()
	DestroyedBefore := TooltipBorderPoolStats.destroyed
	try {
		TOOLTIP_BORDER_POOL_MAX := 3
		Loop 7 {
			Border := _TooltipBuildBorder(0, 0, 180 + A_Index, 44)
			AssertTrue(IsObject(Border))
			AssertTrue(_TooltipRecycleBorder(Border))
		}
		AssertEqual(3, TooltipBorderPoolStats.pooled,
			"distinct dimensions must never grow the pool beyond its cap")
		AssertEqual(4, TooltipBorderPoolStats.destroyed - DestroyedBefore,
			"every owner refused by the cap must be destroyed immediately")
		AssertEqual(3, TooltipReleaseRenderResources(),
			"explicit cleanup must reap every retained owner")
		AssertEqual(7, TooltipBorderPoolStats.destroyed - DestroyedBefore)
	} finally {
		TooltipReleaseRenderResources()
		TOOLTIP_BORDER_POOL_MAX := SavedMax
	}
}

Test("tooltip border: pool cap and terminal cleanup own every layered window (tooltip-present-layered-reallocation)",
	_TBP_PoolCapEvictsAndCleanupReapsAll)
