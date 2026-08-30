; tests/unit/test_tooltip_measure_gdi_ownership.ahk

; ==============================================================================
; MODULE: Tooltip measurement GDI ownership tests
; DESCRIPTION:
; Injects cache hits, measurement exceptions, and refused DC releases into the
; hot-path text measurer without allocating native desktop resources.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TMGO_Native {
	static Events := []
	static CreateCount := 0
	static FailRelease := false
	static ThrowMeasure := false

	static Reset(FailRelease := false, ThrowMeasure := false) {
		this.Events := []
		this.CreateCount := 0
		this.FailRelease := FailRelease
		this.ThrowMeasure := ThrowMeasure
	}

	static GetScreenDC() {
		this.Events.Push("get-dc")
		return 201
	}

	static ReleaseScreenDC(DeviceContext) {
		this.Events.Push("release-dc:" . DeviceContext)
		return !this.FailRelease
	}

	static GetVerticalDpi(DeviceContext) {
		this.Events.Push("dpi:" . DeviceContext)
		return 96
	}

	static CreateFont(HeightPx, FontName) {
		this.CreateCount += 1
		this.Events.Push("create-font:" . HeightPx)
		return 301
	}

	static DeleteObject(ObjectHandle) {
		this.Events.Push("delete-object:" . ObjectHandle)
		return true
	}

	static SelectObject(DeviceContext, ObjectHandle) {
		this.Events.Push("select:" . DeviceContext . ":" . ObjectHandle)
		return ObjectHandle == 301 ? 401 : 901
	}

	static MeasureText(DeviceContext, Text, Size) {
		this.Events.Push("measure:" . Text)
		if this.ThrowMeasure
			throw Error("injected measurement failure")
		NumPut("Int", 123, Size, 0)
		NumPut("Int", 17, Size, 4)
		return 1
	}
}

_TMGO_Join(Values) {
	Output := ""
	for Value in Values
		Output .= (Output == "" ? "" : ",") . Value
	return Output
}





_TMGO_CachePublishesOneFontAndEveryDcCloses() {
	global _TooltipMeasureGdiCleanupDebt
	OriginalDebt := _TooltipMeasureGdiCleanupDebt
	_TooltipMeasureGdiCleanupDebt := []
	try {
		_TMGO_Native.Reset()
		Cache := Map()
		First := _TooltipMeasureTextSize("first", 12, _TMGO_Native, Cache)
		Second := _TooltipMeasureTextSize("second", 12, _TMGO_Native, Cache)
		AssertEqual(123, First.W)
		AssertEqual(17, Second.H)
		AssertEqual(1, _TMGO_Native.CreateCount,
			"the same height must publish exactly one process-lifetime HFONT")
		AssertEqual(2, _TMGO_CountEvent(_TMGO_Native.Events, "release-dc:201"),
			"each independent measurement receipt must release its screen DC")
	} finally _TooltipMeasureGdiCleanupDebt := OriginalDebt
}

_TMGO_CountEvent(Events, Expected) {
	Count := 0
	for Event in Events {
		if Event == Expected
			Count += 1
	}
	return Count
}
Test("tooltip measurement GDI: cached fonts publish once and DCs always close (tooltip-measure-gdi-ownership)",
	_TMGO_CachePublishesOneFontAndEveryDcCloses)

_TMGO_MeasureExceptionStillRestoresAndReleases() {
	global _TooltipMeasureGdiCleanupDebt
	OriginalDebt := _TooltipMeasureGdiCleanupDebt
	_TooltipMeasureGdiCleanupDebt := []
	try {
		_TMGO_Native.Reset(false, true)
		Threw := false
		try _TooltipMeasureTextSize("boom", 12, _TMGO_Native, Map())
		catch
			Threw := true
		AssertTrue(Threw, "the injected measurement error must still propagate")
		Events := _TMGO_Join(_TMGO_Native.Events)
		AssertTrue(InStr(Events, "select:201:401") > 0,
			"finally must restore the previous font after the exception")
		AssertTrue(InStr(Events, "release-dc:201") > 0,
			"finally must release the screen DC after the exception")
	} finally _TooltipMeasureGdiCleanupDebt := OriginalDebt
}
Test("tooltip measurement GDI: exceptions restore selection and release DC (tooltip-measure-gdi-ownership)",
	_TMGO_MeasureExceptionStillRestoresAndReleases)

_TMGO_RefusedReleaseBlocksAllocationUntilDebtClears() {
	global _TooltipMeasureGdiCleanupDebt
	OriginalDebt := _TooltipMeasureGdiCleanupDebt
	_TooltipMeasureGdiCleanupDebt := []
	try {
		_TMGO_Native.Reset(true)
		Cache := Map()
		First := _TooltipMeasureTextSize("first", 12, _TMGO_Native, Cache)
		AssertEqual(123, First.W)
		AssertEqual(1, _TooltipMeasureGdiCleanupDebt.Length,
			"a refused ReleaseDC must retain its exact receipt")
		CreateBefore := _TMGO_Native.CreateCount
		Fallback := _TooltipMeasureTextSize("blocked", 12, _TMGO_Native, Cache)
		AssertEqual(80, Fallback.W,
			"persistent cleanup debt must fail closed to the non-GDI fallback")
		AssertEqual(CreateBefore, _TMGO_Native.CreateCount,
			"no new HFONT may be allocated while native cleanup remains refused")
		_TMGO_Native.FailRelease := false
		Recovered := _TooltipMeasureTextSize("recovered", 12, _TMGO_Native, Cache)
		AssertEqual(123, Recovered.W)
		AssertEqual(0, _TooltipMeasureGdiCleanupDebt.Length)
	} finally _TooltipMeasureGdiCleanupDebt := OriginalDebt
}
Test("tooltip measurement GDI: refused cleanup blocks allocations until retry (tooltip-measure-gdi-ownership)",
	_TMGO_RefusedReleaseBlocksAllocationUntilDebtClears)
