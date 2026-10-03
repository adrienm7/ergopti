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

	static CreateFont(HeightPx, FontName, Bold := false) {
		this.CreateCount += 1
		this.Events.Push("create-font:" . HeightPx . ":" . FontName . ":" . (Bold ? "bold" : "regular"))
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

_TMGO_CacheOwnsEveryFontIdentity() {
	global _TooltipMeasureGdiCleanupDebt, _TOOLTIP_FONT_NAME
	SavedDebt := _TooltipMeasureGdiCleanupDebt, SavedName := _TOOLTIP_FONT_NAME
	_TooltipMeasureGdiCleanupDebt := []
	try {
		_TMGO_Native.Reset()
		Cache := Map()
		_TOOLTIP_FONT_NAME := "First family"
		_TooltipMeasureTextSize("regular", 12, _TMGO_Native, Cache, false)
		_TooltipMeasureTextSize("bold", 12, _TMGO_Native, Cache, true)
		_TooltipMeasureTextSize("bold again", 12, _TMGO_Native, Cache, true)
		_TOOLTIP_FONT_NAME := "Second family"
		_TooltipMeasureTextSize("another family", 12, _TMGO_Native, Cache, false)
		AssertEqual(3, Cache.Count, "font family and weight are distinct cache identities")
		AssertEqual(3, _TMGO_Native.CreateCount, "repeated bold measurement reuses only the same font")
		AssertEqual(1, _TMGO_CountEvent(_TMGO_Native.Events, "create-font:-16:First family:regular"))
		AssertEqual(1, _TMGO_CountEvent(_TMGO_Native.Events, "create-font:-16:First family:bold"))
		AssertEqual(1, _TMGO_CountEvent(_TMGO_Native.Events, "create-font:-16:Second family:regular"))
		AssertEqual(4, _TMGO_CountEvent(_TMGO_Native.Events, "release-dc:201"),
			"every new identity and cache hit still settle their measurement DC")
		AssertEqual(0, _TooltipMeasureGdiCleanupDebt.Length)
	} finally {
		_TOOLTIP_FONT_NAME := SavedName
		_TooltipMeasureGdiCleanupDebt := SavedDebt
	}
}
Test("tooltip measurement GDI: font cache identity includes family and bold weight",
	_TMGO_CacheOwnsEveryFontIdentity)

; Actual native fonts are created in a private cache and deleted in finally.
; The production process-lifetime cache is never replaced or borrowed here.
_TMGO_NativeFontWeightsHaveSeparateHandles() {
	Cache := Map()
	Released := []
	try {
		Regular := _TooltipMeasureTextSize("Regular font", 12, , Cache, false)
		Bold := _TooltipMeasureTextSize("Bold font", 12, , Cache, true)
		AssertEqual(2, Cache.Count, "actual regular/bold native handles must be independently owned")
		Weights := Map(), Handles := Map()
		for Key, Font in Cache {
			LogFont := Buffer(92, 0)
			AssertEqual(92, DllCall("Gdi32\GetObjectW", "Ptr", Font,
				"Int", LogFont.Size, "Ptr", LogFont, "Int"), "the actual cached font must expose LOGFONTW")
			Weights[NumGet(LogFont, 16, "Int")] := true
			Handles[Font] := true
		}
		AssertEqual(2, Handles.Count, "native bold cannot reuse the regular HFONT")
		AssertTrue(Weights.Has(400), "FW_NORMAL is painted with regular weight")
		AssertTrue(Weights.Has(700), "FW_BOLD is painted with bold weight")
		Assert(Regular.W > 0 && Bold.W > 0 && Regular.H > 0 && Bold.H > 0,
			"both weights produce real nonempty geometry")
	} finally {
		for Key, Font in Cache
			Released.Push(_TooltipMeasureGdiNative.DeleteObject(Font))
	}
	AssertEqual(2, Released.Length)
	for Acknowledged in Released
		AssertTrue(Acknowledged, "the isolated native font must acknowledge deletion")
}
Test("tooltip measurement GDI: actual regular and bold fonts own different acknowledged handles",
	_TMGO_NativeFontWeightsHaveSeparateHandles)
