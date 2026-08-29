; tests/unit/test_wall_clock_snapshot.ahk

; ==============================================================================
; MODULE: Atomic Wall-Clock Snapshot Tests
; DESCRIPTION:
; Guards timestamp producers against combining the second from A_Now with the
; millisecond from a later A_MSec read. A scheduler interruption at a second or
; day boundary otherwise creates a valid-looking timestamp from two instants.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Production ownership =======
; =======================================
; =======================================

_WCS_ProductionCallersUseOneSnapshot() {
	for FunctionName in [
		"LoggerInit",
		"_LoggerEmitDroppedSummary",
		"_LoggerEmit",
		"_LoggerEmitDedupSummary",
		"KL_NowTimestamp"
	] {
		Body := _DriverFuncBody(FunctionName)
		Assert(Body != "", FunctionName . " must be discoverable in production source")
		Assert(InStr(Body, "WallClockTimestamp(") > 0,
			FunctionName . " must derive seconds and milliseconds from one snapshot")
		Assert(!InStr(Body, "A_MSec"),
			FunctionName . " must not retain an independent millisecond read")
	}
}
Test("wall clock: every millisecond timestamp uses one sampled instant "
	. "(wall-clock-torn-second)", _WCS_ProductionCallersUseOneSnapshot)





; ======================================
; ======================================
; ======= 2/ Snapshot formatting =======
; ======================================
; ======================================

_WCS_Sample(Year, Month, Day, Hour, Minute, Second, Millisecond) {
	return Map(
		"year", Year,
		"month", Month,
		"day", Day,
		"hour", Hour,
		"minute", Minute,
		"second", Second,
		"millisecond", Millisecond)
}

_WCS_BoundarySamplesStayCoherent() {
	Before := _WCS_Sample(2026, 12, 31, 23, 59, 59, 999)
	After := _WCS_Sample(2027, 1, 1, 0, 0, 0, 0)
	AssertEqual("2026-12-31 23:59:59:999",
		WallClockTimestamp(":", (*) => Before),
		"the last millisecond must remain attached to its sampled second")
	AssertEqual("2027-01-01 00:00:00.000",
		WallClockTimestamp(".", (*) => After),
		"the first millisecond must remain attached to the new sampled date")
}
Test("wall clock: second and date boundaries format one coherent snapshot "
	. "(wall-clock-torn-second)", _WCS_BoundarySamplesStayCoherent)
