; tests/meta/test_tooltip_border_ring_region.ahk

; ==============================================================================
; MODULE: Tooltip Border Ring Region Meta Test
; DESCRIPTION:
; Source guard for the tooltip-border-ring-region finding. The content window is
; clipped by SetWindowRgn to a CreateRoundRectRgn shape, while the layered border
; ring used to be stroked independently with RoundRect. Two rasterizers produce
; two arcs, so the ring's corner pixels could fall outside the clipped content or
; leave its boundary unframed. The behavioural twin
; (unit/test_tooltip_border_ring_region.ahk) compares the real pixels; this guard
; keeps the class closed: both surfaces take one physical geometry, the ring is
; framed from the region owner, and no tooltip code strokes its own arc again.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ One shape for content and ring =======
; =================================================
; =================================================

_TBRRM_BorderFramesTheContentRegion() {
	Build := _DriverFuncBody("_TooltipBuildBorder")
	Assert(Build != "", "the layered border build must remain discoverable")
	Assert(InStr(Build, "RoundRect") == 0 and InStr(Build, "CreatePen") == 0,
		"the border must not stroke an arc of its own; it frames the content region")
	Assert(InStr(Build, "_TooltipRasterizeBorderRing(MemDC, Geometry)") > 0,
		"the border DIB must be painted by the shared-region ring rasterizer")
	Assert(InStr(Build, "_TooltipSurfaceGeometry(W, H, _TooltipDpiScale())") > 0,
		"the border must take its physical size and diameter from the shared geometry")

	Corners := _DriverFuncBody("_TooltipApplyStackedCorners")
	Assert(Corners != "", "the content region routine must remain discoverable")
	Assert(InStr(Corners, "_TooltipSurfaceGeometry(Row.W, Row.H, _TooltipDpiScale())") > 0,
		"the content region must take its physical size and diameter from the shared geometry")

	Ring := _DriverFuncBody("_TooltipRasterizeBorderRing")
	Assert(Ring != "", "the ring rasterizer must remain discoverable")
	Create := InStr(Ring, "Native.CreateRegion(Geometry.W, Geometry.H,")
	Frame := InStr(Ring, "Native.FrameRegion(DeviceContext,")
	Assert(Create > 0 and Frame > Create,
		"the ring must frame a region built by the same owner as the window region")
}
Test("tooltip: the border ring frames the content region (tooltip-border-ring-region)",
	_TBRRM_BorderFramesTheContentRegion)

_TBRRM_OneRoundedShapeFactory() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable for the shape guard")
	Factories := 0
	Pos := 1
	while (Pos := InStr(Src, "Gdi32\CreateRoundRectRgn", true, Pos)) {
		Factories += 1
		Pos += 1
	}
	AssertEqual(1, Factories,
		"one CreateRoundRectRgn factory must shape both the content window and its ring")
	TooltipSrc := _StripFullLineComments(_DriverDirConcat("ui/tooltip"))
	Assert(TooltipSrc != "", "the ui/tooltip sources must be readable for the shape guard")
	Assert(InStr(TooltipSrc, "Gdi32\RoundRect") == 0,
		"no tooltip surface may stroke an independent RoundRect arc")
}
Test("tooltip: one rounded-shape factory serves content and ring (tooltip-border-ring-region)",
	_TBRRM_OneRoundedShapeFactory)
