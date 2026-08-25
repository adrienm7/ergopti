; ui/tooltip/position_receipt.ahk

#Requires AutoHotkey v2.0+

; A cached screen coordinate is only reusable while the foreground window is
; still attached to the same monitor environment. HWND alone is insufficient:
; Windows keeps it stable while a window crosses monitors, the taskbar changes
; a work area, or per-monitor DPI changes.

_TooltipNativeMonitorFromWindow(Hwnd) {
	try return DllCall("User32\MonitorFromWindow", "Ptr", Hwnd, "UInt", 2, "Ptr")
	return 0
}

_TooltipNativeMonitorWorkArea(MonitorHandle) {
	Info := Buffer(40, 0)
	NumPut("UInt", 40, Info, 0)
	Ok := false
	try Ok := DllCall("User32\GetMonitorInfoW", "Ptr", MonitorHandle,
		"Ptr", Info.Ptr, "Int")
	if !Ok
		return 0
	return Map(
		"left", NumGet(Info, 20, "Int"),
		"top", NumGet(Info, 24, "Int"),
		"right", NumGet(Info, 28, "Int"),
		"bottom", NumGet(Info, 32, "Int")
	)
}

_TooltipNativeWindowDpi(Hwnd) {
	try return DllCall("User32\GetDpiForWindow", "Ptr", Hwnd, "UInt")
	return 0
}

_TooltipReadPositionReceipt(Hwnd, MonitorFn?, WorkAreaFn?, DpiFn?) {
	if !Hwnd
		return 0
	if !IsSet(MonitorFn)
		MonitorFn := _TooltipNativeMonitorFromWindow
	if !IsSet(WorkAreaFn)
		WorkAreaFn := _TooltipNativeMonitorWorkArea
	if !IsSet(DpiFn)
		DpiFn := _TooltipNativeWindowDpi

	MonitorHandle := 0
	try MonitorHandle := MonitorFn.Call(Hwnd)
	if !MonitorHandle
		return 0
	WorkArea := 0
	try WorkArea := WorkAreaFn.Call(MonitorHandle)
	Required := ["left", "top", "right", "bottom"]
	if !IsObject(WorkArea)
		return 0
	for , Key in Required {
		if !WorkArea.Has(Key)
			return 0
	}
	Dpi := 0
	try Dpi := DpiFn.Call(Hwnd)
	if !(Dpi is Integer) or Dpi <= 0
		return 0

	return Map(
		"monitor", MonitorHandle,
		"work_left", WorkArea["left"],
		"work_top", WorkArea["top"],
		"work_right", WorkArea["right"],
		"work_bottom", WorkArea["bottom"],
		"dpi", Dpi
	)
}

_TooltipPositionReceiptsEqual(Left, Right) {
	if !IsObject(Left) or !IsObject(Right)
		return false
	for , Key in ["monitor", "work_left", "work_top", "work_right",
			"work_bottom", "dpi"] {
		if !Left.Has(Key) or !Right.Has(Key) or Left[Key] != Right[Key]
			return false
	}
	return true
}

_TooltipPositionCacheCanReuse(Cache, Hwnd, CurrentEnvironment, NowTick,
		MaxAgeMs) {
	if !IsObject(Cache)
		return false
	for , Key in ["hwnd", "tick", "environment"] {
		if !Cache.Has(Key)
			return false
	}
	return (Cache["hwnd"] == Hwnd
		and TickElapsed(Cache["tick"], NowTick) <= MaxAgeMs
		and _TooltipPositionReceiptsEqual(Cache["environment"], CurrentEnvironment))
}
