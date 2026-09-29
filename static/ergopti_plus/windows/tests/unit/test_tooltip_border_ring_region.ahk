; tests/unit/test_tooltip_border_ring_region.ahk

; ==============================================================================
; MODULE: Tooltip Border Ring / Content Region Coincidence Tests
; DESCRIPTION:
; The content Gui is clipped by SetWindowRgn to a rounded region, and the border
; ring is a separate layered bitmap laid exactly over it. The corners only look
; clean when every ring pixel is a boundary pixel of that region: a ring pixel
; outside the region is drawn over the desktop (a pale speck beside the tooltip),
; and an unframed boundary pixel leaves the clipped edge bare. The ring used to be
; stroked with RoundRect, whose arc rasterizer is independent of the region's, so
; nothing tied the two shapes together (tooltip-border-ring-region).
;
; The ring is now framed from the content region itself. These tests paint the
; real region with FillRgn and the real ring with the production rasterizer,
; then compare them pixel for pixel at the physical sizes several DPI scales
; produce. The headless harness never loads the TOML corner radius, so each case
; sets the style global it needs and restores it.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ DIB and mask helpers =======
; =======================================
; =======================================

; Top-down 32-bpp DIB cleared to transparent black, like the border build.
_TBRR_NewDib(W, H) {
	BmpInfo := Buffer(40, 0)
	NumPut("UInt", 40, BmpInfo, 0)    ; biSize
	NumPut("Int", W, BmpInfo, 4)      ; biWidth
	NumPut("Int", -H, BmpInfo, 8)     ; biHeight (negative = top-down)
	NumPut("UShort", 1, BmpInfo, 12)  ; biPlanes
	NumPut("UShort", 32, BmpInfo, 14) ; biBitCount
	ScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	Assert(ScreenDC, "the screen DC must be available for the ring test")
	PixPtr := 0
	HBmp := DllCall("Gdi32\CreateDIBSection", "Ptr", ScreenDC, "Ptr", BmpInfo,
		"UInt", 0, "Ptr*", &PixPtr, "Ptr", 0, "UInt", 0, "Ptr")
	MemDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
	DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC)
	Assert(HBmp and MemDC and PixPtr, "the ring test DIB must be allocated")
	OldBmp := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HBmp, "Ptr")
	DllCall("Gdi32\PatBlt", "Ptr", MemDC,
		"Int", 0, "Int", 0, "Int", W, "Int", H, "UInt", 0x42)  ; BLACKNESS
	return { HBmp: HBmp, MemDC: MemDC, OldBmp: OldBmp, PixPtr: PixPtr }
}

_TBRR_FreeDib(D) {
	DllCall("Gdi32\SelectObject", "Ptr", D.MemDC, "Ptr", D.OldBmp)
	DllCall("Gdi32\DeleteDC", "Ptr", D.MemDC)
	DllCall("Gdi32\DeleteObject", "Ptr", D.HBmp)
}

; FillRgn paints exactly the pixels SetWindowRgn keeps visible on the content.
_TBRR_PaintRegionMask(D, Geometry) {
	Region := _TooltipRegionNative.CreateRegion(Geometry.W, Geometry.H,
		Geometry.Diam)
	Assert(Region, "the content region must be created for the mask")
	try {
		Brush := DllCall("Gdi32\GetStockObject", "Int",
			_TooltipRegionNative.MaskBrush, "Ptr")
		Assert(DllCall("Gdi32\FillRgn", "Ptr", D.MemDC, "Ptr", Region,
			"Ptr", Brush, "Int"), "FillRgn must paint the content region mask")
	} finally {
		DllCall("Gdi32\DeleteObject", "Ptr", Region)
	}
}

_TBRR_WithCornerDiameter(Diameter, Fn) {
	global _TOOLTIP_CORNER_RADIUS
	Saved := _TOOLTIP_CORNER_RADIUS
	_TOOLTIP_CORNER_RADIUS := Diameter
	try Fn.Call()
	finally _TOOLTIP_CORNER_RADIUS := Saved
}

_TBRR_WithRegionDebtIsolated(Fn) {
	global _TooltipRegionCleanupDebt
	Saved := _TooltipRegionCleanupDebt
	_TooltipRegionCleanupDebt := []
	try Fn.Call()
	finally _TooltipRegionCleanupDebt := Saved
}





; ====================================
; ====================================
; ======= 2/ Pixel coincidence =======
; ====================================
; ====================================

; Every ring pixel lies in the region; every region pixel with a 4-neighbour
; outside it (or on the bitmap edge) is framed; every ring pixel touches the
; outside, so the ring stays one pixel thin.
_TBRR_AssertRingFramesRegion(Label, Geometry) {
	W := Geometry.W
	H := Geometry.H
	Mask := _TBRR_NewDib(W, H)
	Ring := 0
	try {
		_TBRR_PaintRegionMask(Mask, Geometry)
		Ring := _TBRR_NewDib(W, H)
		_TooltipRasterizeBorderRing(Ring.MemDC, Geometry)
		MaskPtr := Mask.PixPtr
		RingPtr := Ring.PixPtr
		Stride := W * 4

		; Non-vacuity: the region reaches all four window edges and cuts the corners.
		Assert(NumGet(MaskPtr, (W // 2) * 4, "UInt")
			and NumGet(MaskPtr, (H // 2) * Stride, "UInt")
			and NumGet(MaskPtr, (H // 2) * Stride + (W - 1) * 4, "UInt")
			and NumGet(MaskPtr, (H - 1) * Stride + (W // 2) * 4, "UInt"),
			Label . ": the content region must reach every window edge")
		Assert(!NumGet(MaskPtr, 0, "UInt")
			and !NumGet(MaskPtr, (H - 1) * Stride + (W - 1) * 4, "UInt"),
			Label . ": the content region corners must be rounded")

		RingCount := 0
		Loop H {
			Y := A_Index - 1
			RowOff := Y * Stride
			Loop W {
				X := A_Index - 1
				Off := RowOff + X * 4
				InRing := NumGet(RingPtr, Off, "UInt") != 0
				InMask := NumGet(MaskPtr, Off, "UInt") != 0
				if InRing {
					RingCount += 1
					if !InMask
						throw Error(Format("{1}: ring pixel ({2},{3}) lies outside the content region, over the desktop",
							Label, X, Y))
				}
				if !InMask
					continue
				Edge4 := X == 0 or Y == 0 or X == W - 1 or Y == H - 1
					or !NumGet(MaskPtr, Off - 4, "UInt")
					or !NumGet(MaskPtr, Off + 4, "UInt")
					or !NumGet(MaskPtr, Off - Stride, "UInt")
					or !NumGet(MaskPtr, Off + Stride, "UInt")
				if (Edge4 and !InRing)
					throw Error(Format("{1}: region boundary pixel ({2},{3}) is not framed by the ring",
						Label, X, Y))
				if (InRing and !Edge4) {
					Edge8 := !NumGet(MaskPtr, Off - Stride - 4, "UInt")
						or !NumGet(MaskPtr, Off - Stride + 4, "UInt")
						or !NumGet(MaskPtr, Off + Stride - 4, "UInt")
						or !NumGet(MaskPtr, Off + Stride + 4, "UInt")
					if !Edge8
						throw Error(Format("{1}: ring pixel ({2},{3}) is interior; the ring must stay 1 px thin",
							Label, X, Y))
				}
			}
		}
		; Each rounded corner shortens a rectangle outline (2W + 2H - 4 pixels) by
		; fewer than Diam pixels, so a ring missing a whole side falls below this.
		Assert(RingCount >= 2 * (W + H) - 4 - 4 * Geometry.Diam,
			Label . ": the ring must frame the whole perimeter, painted " . RingCount)
	} finally {
		_TBRR_FreeDib(Mask)
		if IsObject(Ring)
			_TBRR_FreeDib(Ring)
	}
}

; Layout sizes of a one-row preview and a stacked tooltip, at the physical sizes
; the common Windows scaling factors produce. The corner diameter is not DPI
; scaled; 14 is the shipped 2 x corner_radius, 6 and 28 bracket it.
_TBRR_RegisterCoincidenceCases() {
	Cases := []
	for Scale in [1.0, 1.25, 1.5, 1.75, 2.0]
		Cases.Push({ W: 150, H: 31, Scale: Scale, Diam: 14 })
	Cases.Push({ W: 150, H: 31, Scale: 1.0, Diam: 6 })
	Cases.Push({ W: 120, H: 80, Scale: 1.5, Diam: 28 })
	for C in Cases {
		Label := Format("{1}x{2} scale {3} diameter {4}", C.W, C.H,
			Round(C.Scale * 100), C.Diam)
		Test("tooltip border ring: frames the content region at " . Label
			. " (tooltip-border-ring-region)",
			_TBRR_RunCoincidenceCase.Bind(Label, C.W, C.H, C.Scale, C.Diam))
	}
}

_TBRR_RunCoincidenceCase(Label, W, H, Scale, Diam) {
	_TBRR_WithRegionDebtIsolated(
		_TBRR_WithCornerDiameter.Bind(Diam,
			_TBRR_CheckCoincidence.Bind(Label, W, H, Scale, Diam)))
}

_TBRR_CheckCoincidence(Label, W, H, Scale, Diam) {
	Geometry := _TooltipSurfaceGeometry(W, H, Scale)
	AssertEqual(Diam, Geometry.Diam,
		Label . ": the case must exercise the requested corner diameter")
	_TBRR_AssertRingFramesRegion(Label, Geometry)
}

_TBRR_RegisterCoincidenceCases()





; ================================================
; ================================================
; ======= 3/ Shared geometry and ownership =======
; ================================================
; ================================================

; AutoHotkey sizes a DPI-scaled Gui with MulDiv(n, dpi, 96). The region and the
; ring must land on that exact physical size, or one clips a column the other
; still paints.
_TBRR_GeometryMatchesTheScaledContentWindow() {
	; 14 is the shipped diameter; the harness leaves the style global at 0.
	_TBRR_WithCornerDiameter(14, _TBRR_CheckScaledGeometry)
}

_TBRR_CheckScaledGeometry() {
	global _TOOLTIP_CORNER_RADIUS
	for Dpi in [96, 120, 144, 168, 192, 216, 240, 288] {
		for Size in [[150, 31], [213, 95], [7, 5]] {
			G := _TooltipSurfaceGeometry(Size[1], Size[2], Dpi / 96)
			Where := Format(" ({1}x{2} at {3} dpi)", Size[1], Size[2], Dpi)
			AssertEqual(DllCall("Kernel32\MulDiv", "Int", Size[1], "Int", Dpi,
				"Int", 96, "Int"), G.W, "surface width must match the scaled Gui" . Where)
			AssertEqual(DllCall("Kernel32\MulDiv", "Int", Size[2], "Int", Dpi,
				"Int", 96, "Int"), G.H, "surface height must match the scaled Gui" . Where)
			AssertEqual(Min(_TOOLTIP_CORNER_RADIUS, G.W, G.H), G.Diam,
				"the corner diameter must be clamped to the surface" . Where)
		}
	}
}
Test("tooltip border ring: region and ring share the scaled window size (tooltip-border-ring-region)",
	_TBRR_GeometryMatchesTheScaledContentWindow)

class _TBRR_RegionNative {
	static Events := []
	static FrameResult := true

	static Reset(FrameResult := true) {
		this.Events := []
		this.FrameResult := FrameResult
	}

	static CreateRegion(W, H, Diameter) {
		this.Events.Push("create:" . W . "x" . H . ":" . Diameter)
		return 1301
	}

	static FrameRegion(DeviceContext, Region) {
		this.Events.Push("frame:" . DeviceContext . ":" . Region)
		if (this.FrameResult == "throw")
			throw Error("injected FrameRgn exception")
		return this.FrameResult
	}

	static DeleteRegion(Region) {
		this.Events.Push("delete:" . Region)
		return true
	}
}

_TBRR_Join(Values) {
	Output := ""
	for Value in Values
		Output .= (Output == "" ? "" : ",") . Value
	return Output
}

_TBRR_RingFramesTheWindowRegionGeometry() {
	_TBRR_RegionNative.Reset()
	AssertTrue(_TooltipRasterizeBorderRing(77, { W: 120, H: 40, Diam: 14 },
		_TBRR_RegionNative))
	AssertEqual("create:120x40:14,frame:77:1301,delete:1301",
		_TBRR_Join(_TBRR_RegionNative.Events),
		"the ring must frame a region built by the window-region owner from the same geometry, then free it")
}
Test("tooltip border ring: frames the window-region geometry and frees it (tooltip-border-ring-region)",
	_TBRR_WithRegionDebtIsolated.Bind(_TBRR_RingFramesTheWindowRegionGeometry))

_TBRR_RefusedFrameStillFreesTheRegion() {
	Geometry := { W: 120, H: 40, Diam: 14 }
	for Outcome in [false, "throw"] {
		_TBRR_RegionNative.Reset(Outcome)
		AssertThrows(() => _TooltipRasterizeBorderRing(77, Geometry, _TBRR_RegionNative),
			"a failed frame must abort the border build")
		AssertEqual("create:120x40:14,frame:77:1301,delete:1301",
			_TBRR_Join(_TBRR_RegionNative.Events),
			"a failed frame must still delete its region")
	}
}
Test("tooltip border ring: a failed frame still frees its region (tooltip-border-ring-region)",
	_TBRR_WithRegionDebtIsolated.Bind(_TBRR_RefusedFrameStillFreesTheRegion))
