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
		"bitmap_selected", false,
		"pen", 0,
		"old_pen", 0,
		"pen_selected", false,
		"old_brush", 0,
		"brush_selected", false)
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
		if Receipt.Get("brush_selected", false) {
			Restored := Native.SelectObject(Receipt["memory_dc"],
				Receipt["old_brush"])
			if !_TooltipGdiSelectSucceeded(Restored)
				return false
			Receipt["brush_selected"] := false
		}
		if Receipt.Get("pen_selected", false) {
			Restored := Native.SelectObject(Receipt["memory_dc"],
				Receipt["old_pen"])
			if !_TooltipGdiSelectSucceeded(Restored)
				return false
			Receipt["pen_selected"] := false
		}
		if Receipt.Get("pen", 0) {
			if Native.DeleteObject(Receipt["pen"]) != true
				return false
			Receipt["pen"] := 0
		}
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
