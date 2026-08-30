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

_TooltipBorderGdiSelectSucceeded(Handle) {
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
			if !_TooltipBorderGdiSelectSucceeded(Restored)
				return false
			Receipt["brush_selected"] := false
		}
		if Receipt.Get("pen_selected", false) {
			Restored := Native.SelectObject(Receipt["memory_dc"],
				Receipt["old_pen"])
			if !_TooltipBorderGdiSelectSucceeded(Restored)
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
			if !_TooltipBorderGdiSelectSucceeded(Restored)
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
