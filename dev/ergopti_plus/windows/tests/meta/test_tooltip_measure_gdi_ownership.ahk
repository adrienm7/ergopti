; tests/meta/test_tooltip_measure_gdi_ownership.ahk

; ==============================================================================
; MODULE: Tooltip measurement GDI ownership meta test
; DESCRIPTION:
; Keeps the hot-path text measurement wired to an atomic HFONT publisher and a
; finally-owned DC receipt rather than an interruptible Has/create/assign chain.
; ==============================================================================

#Requires AutoHotkey v2.0

_TMGO_MeasurementOwnsCacheAndDc() {
	Acquire := _DriverFuncBody("_TooltipMeasureAcquireCachedFont")
	Assert(Acquire != "" and InStr(Acquire, "Critical") > 0,
		"HFONT cache check, creation, and publication must exclude AHK interrupts")
	Assert(InStr(Acquire, "FontCache.Has") > 0
		and InStr(Acquire, "FontCache[") > 0,
		"the tested atomic publisher must own both cache lookup and publication")
	Measure := _DriverFuncBody("_TooltipMeasureTextSize")
	Assert(Measure != "" and InStr(Measure, "finally") > 0
		and InStr(Measure, "_TooltipMeasureSettleGdiReceipt") > 0,
		"every exit after GetDC must restore the selected font and release the DC")
	Settle := _DriverFuncBody("_TooltipMeasureSettleGdiReceipt")
	Assert(Settle != "" and InStr(Settle, "_TooltipMeasureGdiCleanupDebt") > 0,
		"a refused native cleanup must remain owned instead of being forgotten")
}
Test("tooltip measurement: HFONT publication and DC cleanup share explicit owners (tooltip-measure-gdi-ownership)",
	_TMGO_MeasurementOwnsCacheAndDc)
