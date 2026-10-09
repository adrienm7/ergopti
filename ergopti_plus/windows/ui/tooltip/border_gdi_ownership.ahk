; ui/tooltip/border_gdi_ownership.ahk

; ==============================================================================
; MODULE: Tooltip border GDI ownership
; DESCRIPTION:
; Retains the complete selected-object dependency graph for one layered border
; build and releases it in exact reverse order on every terminal path.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TooltipBorderGdiBusy := false
global _TooltipBorderGdiCleanupDebt := 0





class _TooltipBorderGdiNative {
	static SelectObject(DeviceContext, ObjectHandle) {
		return DllCall("Gdi32\SelectObject", "Ptr", DeviceContext,
			"Ptr", ObjectHandle, "Ptr")
	}

	static DeleteObject(ObjectHandle) {
		return DllCall("Gdi32\DeleteObject", "Ptr", ObjectHandle, "Int") != 0
	}

	static DeleteDC(DeviceContext) {
		return DllCall("Gdi32\DeleteDC", "Ptr", DeviceContext, "Int") != 0
	}

	static ReleaseScreenDC(DeviceContext) {
		return DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", DeviceContext,
			"Int") != 0
	}
}





_TooltipBorderNewGdiReceipt() {
	return Map(
		"screen_dc", 0,
		"bitmap", 0,
		"memory_dc", 0,
		"old_bitmap", 0,
		"bitmap_selected", false)
}

_TooltipGdiSelectSucceeded(Handle) {
	return Handle != 0 and Handle != -1
}

; Restore selections before deleting their owned objects. A refused step leaves
; that handle and every dependency below it in the receipt for an exact retry.
_TooltipBorderGdiRelease(Receipt, Native := _TooltipBorderGdiNative) {
	if !(Receipt is Map)
		return true
	try {
		if Receipt.Get("bitmap_selected", false) {
			Restored := Native.SelectObject(Receipt["memory_dc"],
				Receipt["old_bitmap"])
			if !_TooltipGdiSelectSucceeded(Restored)
				return false
			Receipt["bitmap_selected"] := false
		}
		if Receipt.Get("bitmap", 0) {
			if Native.DeleteObject(Receipt["bitmap"]) != true
				return false
			Receipt["bitmap"] := 0
		}
		if Receipt.Get("memory_dc", 0) {
			if Native.DeleteDC(Receipt["memory_dc"]) != true
				return false
			Receipt["memory_dc"] := 0
		}
		if Receipt.Get("screen_dc", 0) {
			if Native.ReleaseScreenDC(Receipt["screen_dc"]) != true
				return false
			Receipt["screen_dc"] := 0
		}
		return true
	} catch {
		return false
	}
}

_TooltipBorderGdiTryBegin() {
	global _TooltipBorderGdiBusy
	PreviousCritical := Critical("On")
	try {
		if _TooltipBorderGdiBusy
			return false
		_TooltipBorderGdiBusy := true
		return true
	} finally Critical(PreviousCritical)
}

_TooltipBorderGdiEnd() {
	global _TooltipBorderGdiBusy
	PreviousCritical := Critical("On")
	try _TooltipBorderGdiBusy := false
	finally Critical(PreviousCritical)
}





class _TooltipRegionNative {
	static CreateRegion(W, H, Diameter) {
		return DllCall("Gdi32\CreateRoundRectRgn", "Int", 0, "Int", 0,
			"Int", W + 1, "Int", H + 1, "Int", Diameter,
			"Int", Diameter, "Ptr")
	}

	static SetWindowRegion(Hwnd, Region) {
		return DllCall("User32\SetWindowRgn", "Ptr", Hwnd, "Ptr", Region,
			"Int", 1, "Int") != 0
	}

	static DeleteRegion(Region) {
		return DllCall("Gdi32\DeleteObject", "Ptr", Region, "Int") != 0
	}

	; WHITE_BRUSH: the painted colour is only a coverage mask, because the border
	; build rewrites every painted pixel to the premultiplied border colour.
	static MaskBrush := 0
	; _TooltipFixBorderAlpha rewrites exactly one edge row and column.
	static RingWidthPx := 1

	static FrameRegion(DeviceContext, Region) {
		Brush := DllCall("Gdi32\GetStockObject", "Int", this.MaskBrush, "Ptr")
		if !Brush
			return false
		return DllCall("Gdi32\FrameRgn", "Ptr", DeviceContext, "Ptr", Region,
			"Ptr", Brush, "Int", this.RingWidthPx, "Int", this.RingWidthPx,
			"Int") != 0
	}
}

global _TooltipRegionCleanupDebt := []

_TooltipRegionRelease(Receipt, Native := _TooltipRegionNative) {
	if !(Receipt is Map) or !Receipt.Get("region", 0)
		return true
	try {
		if Native.DeleteRegion(Receipt["region"]) != true
			return false
		Receipt["region"] := 0
		return true
	} catch {
		return false
	}
}

_TooltipRegionSettle(Receipt, Native := _TooltipRegionNative) {
	global _TooltipRegionCleanupDebt
	if _TooltipRegionRelease(Receipt, Native)
		return true
	PreviousCritical := Critical("On")
	try _TooltipRegionCleanupDebt.Push(Receipt)
	finally Critical(PreviousCritical)
	return false
}

_TooltipRegionDrainDebt(Native := _TooltipRegionNative) {
	global _TooltipRegionCleanupDebt
	PreviousCritical := Critical("On")
	try {
		Pending := _TooltipRegionCleanupDebt
		_TooltipRegionCleanupDebt := []
	} finally Critical(PreviousCritical)
	Failed := []
	for Receipt in Pending {
		if !_TooltipRegionRelease(Receipt, Native)
			Failed.Push(Receipt)
	}
	PreviousCritical := Critical("On")
	try {
		for Receipt in Failed
			_TooltipRegionCleanupDebt.Push(Receipt)
		return _TooltipRegionCleanupDebt.Length == 0
	} finally Critical(PreviousCritical)
}

; SetWindowRgn transfers the HRGN to the window only on success. Until that
; exact result is known, the local receipt remains responsible for deletion.
_TooltipApplyOwnedRegion(Hwnd, W, H, Diameter,
		Native := _TooltipRegionNative) {
	if !Hwnd or !IsNumber(W) or !IsNumber(H) or W <= 0 or H <= 0
		return false
	if !_TooltipRegionDrainDebt(Native)
		return false
	Receipt := Map("region", 0)
	Applied := false
	Released := false
	try {
		Receipt["region"] := Native.CreateRegion(W, H, Diameter)
		if !Receipt["region"]
			return false
		Applied := Native.SetWindowRegion(Hwnd, Receipt["region"])
		if Applied
			Receipt["region"] := 0
	} finally {
		Released := _TooltipRegionSettle(Receipt, Native)
	}
	return Applied == true and Released
}

; Rasterize the border ring as the one-pixel inner frame of the same region the
; content window is clipped to. A separately stroked RoundRect follows its own
; arc rasterization, so corner pixels could fall outside the clipped content
; (pale specks over the desktop) or leave region pixels unframed. Framing the
; shared region makes every ring pixel a boundary pixel of the content.
; @param DeviceContext {Ptr} Memory DC holding the cleared 32-bpp border DIB.
; @param Geometry {Object} Physical { W, H, Diam } from _TooltipSurfaceGeometry.
_TooltipRasterizeBorderRing(DeviceContext, Geometry,
		Native := _TooltipRegionNative) {
	if !_TooltipRegionDrainDebt(Native)
		throw Error("Previous tooltip region cleanup is still pending")
	Receipt := Map("region", 0)
	Framed := false
	Released := false
	try {
		Receipt["region"] := Native.CreateRegion(Geometry.W, Geometry.H,
			Geometry.Diam)
		if !Receipt["region"]
			throw Error("CreateRoundRectRgn failed for the tooltip border ring")
		Framed := Native.FrameRegion(DeviceContext, Receipt["region"])
	} finally {
		Released := _TooltipRegionSettle(Receipt, Native)
	}
	if (Framed != true)
		throw Error("FrameRgn failed for the tooltip border ring")
	if !Released
		throw Error("Tooltip border ring region cleanup was refused")
	return true
}
