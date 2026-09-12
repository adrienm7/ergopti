; static/ergopti_plus/windows/tests/unit/test_metrics_delivery_midnight.ahk

; ==============================================================================
; MODULE: Metrics Delivery Midnight Tests
; DESCRIPTION: A day rollover during delivery preserves a pending full refresh.
; ==============================================================================

#Requires AutoHotkey v2.0

_MDM_AdvanceDay(Clock) {
	Clock["day"] := "2026-01-03"
}

_MDM_RolloverDuringDelivery(Boundary) {
	SavedWindows := KLWV.windows
	SavedDay := KLWV.history_day_fn
	SavedDrain := KLWV.ingest_drain_timer_fn
	SavedPush := KLWV.first_paint_push_fn
	_KLRDC_Reset()
	try {
		Root := _KLRDC_Root()
		Clock := Map("day", "2026-01-02")
		KLWV.history_day_fn := () => Clock["day"]
		KLWV.ingest_drain_timer_fn := (*) => true
		KLWV.first_paint_push_fn := 0
		Seed := Map("version", 2, "store", ConfigTransitionNormalizeConfigDir(Root),
			"day", Clock["day"], "ledgers", Map(), "walker_timings", KL_JsonEncode(KLW_TimingValues()))
		Path := Root . "delta.json"
		AssertTrue(FSWriteDurable(Path,
			'{"_history_seed":' . KL_JsonEncode(Seed) . ",`n" . '"_prefetch_data":{"today":{}}}'))
		View := _MCR_View(Boundary = "post" ? _MDM_AdvanceDay.Bind(Clock) : (*) => 0)
		Entry := Map("epoch", 91, "webview", View, "metrics_dir", Root,
			"first_paint_done", true, "full_build_done", true, "history_seed", Seed)
		KLWV.windows := Map("typing", Entry)
		Diagnostic := Boundary = "diagnostic" ? (*) => _MDM_AdvanceDay(Clock) : (*) => 0
		AssertTrue(_KLWV_HistorySeedCurrent(Entry, Seed), "seed must be current before delivery starts")
		Accepted := KLWV_PushPrefetch("typing", Diagnostic, 91, FileRead, Path)
		AssertEqual(1, View.Messages.Length, "the day must roll after the bridge post")
		AssertEqual("2026-01-03", Clock["day"])
		AssertFalse(Accepted, "cross-midnight delivery cannot certify current history")
		AssertFalse(Entry["full_build_done"])
		AssertEqual("full", Entry["pending_ingest_mode"], "recovery must not wait for another typing event")
		AssertTrue(Entry["history_seed"] == Seed, "old receipt must not be advanced by expired delivery")
	} finally {
		KLWV.windows := SavedWindows
		KLWV.history_day_fn := SavedDay
		KLWV.ingest_drain_timer_fn := SavedDrain
		KLWV.first_paint_push_fn := SavedPush
		_KLRDC_Cleanup()
	}
}
for Boundary in ["post", "diagnostic"]
	Test("metrics delivery: midnight during " . Boundary . " requires full recovery (metrics-delivery-midnight)",
		_KLRDC_CheckTeardown.Bind(_MDM_RolloverDuringDelivery.Bind(Boundary)))
