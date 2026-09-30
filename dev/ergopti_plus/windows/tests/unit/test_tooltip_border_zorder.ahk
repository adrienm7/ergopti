; tests/unit/test_tooltip_border_zorder.ahk

; ==============================================================================
; MODULE: Tooltip Border Z-Order Regression Tests
; DESCRIPTION:
; The Windows tooltip is two HWNDs: an opaque content Gui clipped to a rounded
; window region, and a layered window carrying the 1 px border ring. The ring is
; only visible while the layered window stacks ABOVE the content. Revealing both
; with ShowWindow(SW_SHOWNOACTIVATE) keeps each window in the z-order slot it
; already holds, so the order silently depended on creation order. Since the
; border pool (tooltip-present-layered-reallocation) hands back a border created
; for an earlier render, every pooled reuse is older than the fresh content Gui:
; the content covered the ring and only the corner pixels outside its rounded
; region stayed visible, reported as "no border, a few white pixels in the
; corners" (tooltip-border-zorder).
;
; The first test replays that exact production order with real windows and
; checks the native z-order after the reveal. The second pins the reveal seam
; deterministically: content first, border last, both placed at the top of the
; topmost band without activation.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Native z-order helpers =======
; =========================================
; =========================================

; Walk the top-level z-order downward from Upper. GetWindow enumerates hidden
; windows too, so the relation is observable before and after the reveal. The
; step bound keeps a concurrently destroyed sibling from looping forever.
_TBZ_IsAbove(Upper, Lower) {
	static GW_HWNDNEXT := 2
	static MaxSteps := 65536
	Hwnd := Upper
	Loop MaxSteps {
		Hwnd := DllCall("User32\GetWindow", "Ptr", Hwnd, "UInt", GW_HWNDNEXT, "Ptr")
		if !Hwnd
			return false
		if (Hwnd == Lower)
			return true
	}
	throw Error("z-order walk exceeded its bound; the window list is unstable")
}

class _TBZ_Native {
	static Events := []
	static RefuseHwnd := 0

	static Reset(RefuseHwnd := 0) {
		this.Events := []
		this.RefuseHwnd := RefuseHwnd
	}

	static ShowOnTop(Hwnd) {
		this.Events.Push("top:" . Hwnd)
		return Hwnd != this.RefuseHwnd
	}

	static PaintNow(Hwnd) {
		this.Events.Push("paint:" . Hwnd)
		return true
	}
}

_TBZ_Join(Values) {
	Output := ""
	for Value in Values
		Output .= (Output == "" ? "" : ",") . Value
	return Output
}





; ==============================================
; ==============================================
; ======= 2/ Reveal stacking regressions =======
; ==============================================
; ==============================================

_TBZ_PooledBorderRevealsAboveNewerContent() {
	Items := [{ Text: "border z-order", ColorHex: "6A5ACD", DurationSec: 1.0 }]
	TooltipReleaseRenderResources()
	Warm := 0
	Surface := 0
	try {
		; A first render sizes the border and retires it into the pool, exactly
		; as _TooltipDisposeRetired does after the next render replaces it.
		WarmRow := _TooltipBuildGui(Items)
		Warm := _TooltipCreateDetachedSurface(WarmRow, 1)
		Pos := _TooltipClampToScreen(120, 120, WarmRow.W, WarmRow.H)
		Pooled := _TooltipBuildBorder(Pos.X, Pos.Y, WarmRow.W, WarmRow.H)
		AssertTrue(IsObject(Pooled), "the warm-up render must create a real layered border")
		PooledHwnd := Pooled.Hwnd
		AssertTrue(_TooltipRecycleBorder(Pooled),
			"the warm-up border must enter the pool like a retired surface")

		; The next same-size render builds its content Gui AFTER the pooled border
		; existed, then reuses that border: the production pool-hit order.
		Row := _TooltipBuildGui(Items)
		Surface := _TooltipCreateDetachedSurface(Row, 2)
		_TooltipPositionPreparedContent(Row, Pos.X, Pos.Y)
		Surface.Border := _TooltipBuildBorder(Pos.X, Pos.Y, Row.W, Row.H)
		AssertTrue(IsObject(Surface.Border), "the second render must obtain a border")
		AssertEqual(PooledHwnd, Surface.Border.Hwnd,
			"precondition: the second render must reuse the pooled layered border")
		ContentHwnd := Row.Gui.Hwnd
		Assert(_TBZ_IsAbove(ContentHwnd, PooledHwnd),
			"precondition: a content Gui created after the pooled border stacks above it")

		_TooltipRevealPreparedSurfaces(Surface)

		AssertTrue(DllCall("User32\IsWindowVisible", "Ptr", ContentHwnd, "Int"),
			"the reveal must show the content")
		AssertTrue(DllCall("User32\IsWindowVisible", "Ptr", PooledHwnd, "Int"),
			"the reveal must show the border")
		Assert(_TBZ_IsAbove(PooledHwnd, ContentHwnd),
			"the revealed border ring must stack above its content, or the opaque content hides it")
		Foreground := DllCall("User32\GetForegroundWindow", "Ptr")
		Assert(Foreground != ContentHwnd and Foreground != PooledHwnd,
			"revealing tooltip surfaces must never activate them")
	} finally {
		if IsObject(Surface) {
			_TooltipHideSurfaceObjects(Surface)
			_TooltipDisposeRetired(Surface)
		}
		if IsObject(Warm)
			_TooltipDisposeRetired(Warm)
		TooltipReleaseRenderResources()
	}
}
Test("tooltip border: a pooled border is revealed above newer content (tooltip-border-zorder)",
	_TBZ_PooledBorderRevealsAboveNewerContent)

_TBZ_RevealPlacesContentThenBorderOnTop() {
	_TBZ_Native.Reset()
	Surface := { Rows: [{ Gui: { Hwnd: 501 } }], Border: { Hwnd: 502 } }
	_TooltipRevealPreparedSurfaces(Surface, _TBZ_Native)
	AssertEqual("top:501,paint:501,top:502", _TBZ_Join(_TBZ_Native.Events),
		"content must be placed and painted first, then the border raised above it")
}
Test("tooltip border: reveal raises the border last (tooltip-border-zorder)",
	_TBZ_RevealPlacesContentThenBorderOnTop)

_TBZ_RefusedBorderPlacementFailsFast() {
	_TBZ_Native.Reset(502)
	Surface := { Rows: [{ Gui: { Hwnd: 501 } }], Border: { Hwnd: 502 } }
	AssertThrows(() => _TooltipRevealPreparedSurfaces(Surface, _TBZ_Native),
		"a refused border placement must surface instead of leaving the ring hidden")
	AssertEqual("top:501,paint:501,top:502", _TBZ_Join(_TBZ_Native.Events))
}
Test("tooltip border: refused border placement fails fast (tooltip-border-zorder)",
	_TBZ_RefusedBorderPlacementFailsFast)

_TBZ_RevealFlagsOrderWithoutActivating() {
	static SWP_NOSIZE := 0x0001, SWP_NOMOVE := 0x0002, SWP_NOZORDER := 0x0004
	static SWP_NOACTIVATE := 0x0010, SWP_SHOWWINDOW := 0x0040, HWND_TOPMOST := -1
	Flags := _TooltipRevealNative.Flags
	AssertEqual(HWND_TOPMOST, _TooltipRevealNative.InsertAfter,
		"tooltip surfaces are placed at the top of the always-on-top band")
	AssertEqual(0, Flags & SWP_NOZORDER,
		"the reveal must apply its z-order placement")
	AssertEqual(SWP_NOACTIVATE, Flags & SWP_NOACTIVATE,
		"the reveal must never activate a tooltip surface")
	AssertEqual(SWP_SHOWWINDOW, Flags & SWP_SHOWWINDOW,
		"the placement is also the reveal")
	AssertEqual(SWP_NOSIZE | SWP_NOMOVE, Flags & (SWP_NOSIZE | SWP_NOMOVE),
		"the reveal must keep the prepared geometry")
}
Test("tooltip border: reveal placement keeps focus and geometry (tooltip-border-zorder)",
	_TBZ_RevealFlagsOrderWithoutActivating)
