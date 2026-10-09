; tests/unit/test_tooltip_position_cache_receipt.ahk

#Requires AutoHotkey v2.0+

_TPCR_Receipt(Monitor, Left := 0, Top := 0, Right := 1920, Bottom := 1080,
		Dpi := 96) {
	return Map(
		"monitor", Monitor,
		"work_left", Left,
		"work_top", Top,
		"work_right", Right,
		"work_bottom", Bottom,
		"dpi", Dpi
	)
}

_TPCR_Cache(Environment, Hwnd := 7001, Tick := 1000) {
	return Map(
		"hwnd", Hwnd,
		"control", 8001,
		"x", 400,
		"y", 500,
		"tick", Tick,
		"environment", Environment
	)
}

_TPCR_PositionCacheRequiresExactEnvironmentReceipt() {
	Baseline := _TPCR_Receipt(101, -1920, 0, 0, 1040, 120)
	Cache := _TPCR_Cache(Baseline)

	AssertTrue(_TooltipPositionCacheCanReuse(Cache, 7001,
		_TPCR_Receipt(101, -1920, 0, 0, 1040, 120), 1200, 600, 8001),
		"the same HWND, monitor, work area, and DPI must reuse a fresh position")
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001,
		_TPCR_Receipt(202, -1920, 0, 0, 1040, 120), 1200, 600, 8001),
		"moving the same HWND to another monitor must invalidate the position")
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001,
		_TPCR_Receipt(101, -1920, 0, 0, 1000, 120), 1200, 600, 8001),
		"a work-area change on the same monitor must invalidate the position")
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001,
		_TPCR_Receipt(101, -1920, 0, 0, 1040, 144), 1200, 600, 8001),
		"a DPI change on the same monitor must invalidate the position")
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7002, Baseline, 1200, 600, 8001),
		"a different foreground HWND must never reuse the receipt")
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001, Baseline, 1700, 600, 8001),
		"an expired receipt must miss even when its environment is unchanged")
	Cache["control"] := 8001
	AssertTrue(_TooltipPositionCacheCanReuse(Cache, 7001, Baseline, 1200, 600, 8001))
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001, Baseline, 1200, 600, 8002),
		"a different editor in the same HWND must never reuse a caret position")
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001, Baseline, 1200, 600, 0),
		"an unknown focused control must refuse cached coordinates")
}

_TPCR_QueryComposesMonitorWorkAreaAndDpi() {
	Calls := Map("monitor", 0, "work", 0, "dpi", 0)
	MonitorFn := (Hwnd) => (Calls["monitor"] += 1, 303)
	WorkFn := (Monitor) => (Calls["work"] += 1,
		Map("left", -2560, "top", -80, "right", 0, "bottom", 1360))
	DpiFn := (Hwnd) => (Calls["dpi"] += 1, 168)

	Receipt := _TooltipReadPositionReceipt(8001, MonitorFn, WorkFn, DpiFn)
	AssertTrue(IsObject(Receipt), "a complete OS identity must produce a receipt")
	AssertEqual(303, Receipt["monitor"], "the receipt must retain monitor identity")
	AssertEqual(-2560, Receipt["work_left"], "negative monitor coordinates must survive")
	AssertEqual(-80, Receipt["work_top"], "negative work-area coordinates must survive")
	AssertEqual(0, Receipt["work_right"], "the right work-area edge must survive")
	AssertEqual(1360, Receipt["work_bottom"], "the bottom work-area edge must survive")
	AssertEqual(168, Receipt["dpi"], "the receipt must retain per-window DPI")
	AssertEqual(1, Calls["monitor"], "monitor identity must be queried once")
	AssertEqual(1, Calls["work"], "work area must be queried once")
	AssertEqual(1, Calls["dpi"], "DPI must be queried once")
}

_TPCR_InvalidEnvironmentFailsClosed() {
	Baseline := _TPCR_Receipt(101)
	Cache := _TPCR_Cache(Baseline)
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001, 0, 1200, 600, 8001),
		"an unavailable current environment must force a fresh probe")
	Cache.Delete("environment")
	AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001, Baseline, 1200, 600, 8001),
		"a legacy cache entry without an environment receipt must miss")
	AssertFalse(IsObject(_TooltipReadPositionReceipt(8001, (*) => 0,
		(*) => _TPCR_Receipt(1), (*) => 96)),
		"an unavailable monitor identity must not create a reusable receipt")
}

Test("tooltip position receipt: cache reuse requires exact monitor work-area and DPI (ahk2-17)",
	_TPCR_PositionCacheRequiresExactEnvironmentReceipt)
Test("tooltip position receipt: query composes monitor work-area and DPI (ahk2-17)",
	_TPCR_QueryComposesMonitorWorkAreaAndDpi)
Test("tooltip position receipt: incomplete environments fail closed (ahk2-17)",
	_TPCR_InvalidEnvironmentFailsClosed)

; The production writer publishes the actual native clock, not a truncated DWORD.
; Supplied context avoids foreground/monitor queries; restore the exact singleton.
_TPCR_Native64Age(Elapsed, Expected) {
	global _TooltipPositionCache
	Saved := _TooltipPositionCache
	try {
		Environment := _TPCR_Receipt(101, -1920, 0, 0, 1040, 120)
		Context := Map("Control", 8001, "Environment", Environment)
		Position := { Type: "caret", X: 400, Y: 500, H: 20 }
		Before := A_TickCount
		Actual := _TooltipCachePosition(7001, Position, Context)
		After := A_TickCount
		Cache := _TooltipPositionCache
		AssertTrue(Actual == Position, "actual writer returns the exact published coordinate object")
		AssertTrue(Cache["tick"] >= Before && Cache["tick"] <= After, "actual cache origin is the native clock sample")
		AssertEqual(8001, Cache["control"], "supplied context retains the exact focused control identity")
		AssertTrue(Cache["environment"] == Environment, "actual writer retains the exact supplied environment receipt")
		AssertEqual(400, Cache["x"])
		AssertEqual(500, Cache["y"])
		Now := Cache["tick"] + Elapsed
		AssertEqual(Expected, _TooltipPositionCacheCanReuse(Cache, 7001, Environment, Now, 600, 8001),
			"a full native age cannot revive a previously expired coordinate receipt")
		AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001, Environment, Now, 600, 8002), "another control cannot use this receipt")
		AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7002, Environment, Now, 600, 8001), "another window cannot use this receipt")
		AssertFalse(_TooltipPositionCacheCanReuse(Cache, 7001, _TPCR_Receipt(202), Now, 600, 8001), "another monitor cannot use this receipt")
	} finally _TooltipPositionCache := Saved
}
Test("tooltip position native64: before expiry (tooltip-position-native64)", _TPCR_Native64Age.Bind(599, true))
Test("tooltip position native64: exact expiry (tooltip-position-native64)", _TPCR_Native64Age.Bind(600, true))
Test("tooltip position native64: after expiry (tooltip-position-native64)", _TPCR_Native64Age.Bind(601, false))
Test("tooltip position native64: full cycle (tooltip-position-native64)", _TPCR_Native64Age.Bind(4294967296, false))
Test("tooltip position native64: cycle before remainder expiry (tooltip-position-native64)", _TPCR_Native64Age.Bind(4294967895, false))
Test("tooltip position native64: cycle exact remainder expiry (tooltip-position-native64)", _TPCR_Native64Age.Bind(4294967896, false))
Test("tooltip position native64: cycle after remainder expiry (tooltip-position-native64)", _TPCR_Native64Age.Bind(4294967897, false))
Test("tooltip position native64: two full cycles (tooltip-position-native64)", _TPCR_Native64Age.Bind(8589934592, false))
