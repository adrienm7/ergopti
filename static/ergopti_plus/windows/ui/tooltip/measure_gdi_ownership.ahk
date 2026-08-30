; ui/tooltip/measure_gdi_ownership.ahk

; ==============================================================================
; MODULE: Tooltip measurement GDI ownership
; DESCRIPTION:
; Serializes first publication of cached HFONT handles and retains DC/font
; cleanup receipts when native release is refused.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TooltipMeasureGdiCleanupDebt := []





class _TooltipMeasureGdiNative {
	static GetScreenDC() {
		return DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	}

	static ReleaseScreenDC(DeviceContext) {
		return DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", DeviceContext,
			"Int") != 0
	}

	static GetVerticalDpi(DeviceContext) {
		return DllCall("Gdi32\GetDeviceCaps", "Ptr", DeviceContext,
			"Int", 90, "Int")
	}

	static CreateFont(HeightPx, FontName) {
		return DllCall("Gdi32\CreateFontW",
			"Int", HeightPx, "Int", 0, "Int", 0, "Int", 0,
			"Int", 400, "UInt", 0, "UInt", 0, "UInt", 0,
			"UInt", 1, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0,
			"WStr", FontName, "Ptr")
	}

	static DeleteObject(ObjectHandle) {
		return DllCall("Gdi32\DeleteObject", "Ptr", ObjectHandle, "Int") != 0
	}

	static SelectObject(DeviceContext, ObjectHandle) {
		return DllCall("Gdi32\SelectObject", "Ptr", DeviceContext,
			"Ptr", ObjectHandle, "Ptr")
	}

	static MeasureText(DeviceContext, Text, Size) {
		return DllCall("Gdi32\GetTextExtentPoint32W", "Ptr", DeviceContext,
			"WStr", Text, "Int", StrLen(Text), "Ptr", Size)
	}
}





_TooltipMeasureNewGdiReceipt() {
	return Map("screen_dc", 0, "old_font", 0, "font_selected", false,
		"uncached_font", 0)
}

_TooltipMeasureGdiRelease(Receipt, Native := _TooltipMeasureGdiNative) {
	if !(Receipt is Map)
		return true
	try {
		if Receipt.Get("font_selected", false) {
			Restored := Native.SelectObject(Receipt["screen_dc"],
				Receipt["old_font"])
			if _TooltipGdiSelectSucceeded(Restored)
				Receipt["font_selected"] := false
		}
		if Receipt.Get("screen_dc", 0) {
			if Native.ReleaseScreenDC(Receipt["screen_dc"]) == true {
				Receipt["screen_dc"] := 0
				; Destroying the DC also retires any unresolved selection.
				Receipt["font_selected"] := false
			}
		}
		if Receipt.Get("uncached_font", 0)
				and !Receipt.Get("font_selected", false) {
			if Native.DeleteObject(Receipt["uncached_font"]) == true
				Receipt["uncached_font"] := 0
		}
		return Receipt.Get("screen_dc", 0) == 0
			and !Receipt.Get("font_selected", false)
			and Receipt.Get("uncached_font", 0) == 0
	} catch {
		return false
	}
}

_TooltipMeasureSettleGdiReceipt(Receipt,
		Native := _TooltipMeasureGdiNative) {
	global _TooltipMeasureGdiCleanupDebt
	if !(Receipt is Map)
		return true
	PreviousCritical := Critical("On")
	try {
		if _TooltipMeasureGdiRelease(Receipt, Native)
			return true
		_TooltipMeasureGdiCleanupDebt.Push(Receipt)
		return false
	} finally Critical(PreviousCritical)
}

_TooltipMeasureDrainGdiDebt(Native := _TooltipMeasureGdiNative) {
	global _TooltipMeasureGdiCleanupDebt
	PreviousCritical := Critical("On")
	try {
		Pending := _TooltipMeasureGdiCleanupDebt
		_TooltipMeasureGdiCleanupDebt := []
		for Receipt in Pending {
			if !_TooltipMeasureGdiRelease(Receipt, Native)
				_TooltipMeasureGdiCleanupDebt.Push(Receipt)
		}
		return _TooltipMeasureGdiCleanupDebt.Length == 0
	} finally Critical(PreviousCritical)
}

; The cache check, native creation, and publication form one non-interruptible
; transaction. Otherwise two AHK threads can both observe a miss and the later
; Map assignment silently loses the first process-lifetime HFONT handle.
_TooltipMeasureAcquireCachedFont(HeightPx, FontName, FontCache,
		Native := _TooltipMeasureGdiNative) {
	if !(FontCache is Map)
		throw TypeError("Tooltip measurement font cache must be a Map")
	CandidateReceipt := _TooltipMeasureNewGdiReceipt()
	PreviousCritical := Critical("On")
	try {
		if FontCache.Has(HeightPx)
			return FontCache[HeightPx]
		CandidateReceipt["uncached_font"] := Native.CreateFont(HeightPx,
			FontName)
		if !CandidateReceipt["uncached_font"]
			return 0
		FontCache[HeightPx] := CandidateReceipt["uncached_font"]
		CandidateReceipt["uncached_font"] := 0
		return FontCache[HeightPx]
	} finally {
		try _TooltipMeasureSettleGdiReceipt(CandidateReceipt, Native)
		finally Critical(PreviousCritical)
	}
}
