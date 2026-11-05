; tests/fixtures/screenshot_layered_native_body.ahk
#Requires AutoHotkey v2.0
_SCLP_Require(Value, Message) {
	if !Value
		throw Error(Message)
}
_SCLP_ControlPixel(X, Y) {
	Screen := DllCall("GetDC", "Ptr", 0, "Ptr")
	_SCLP_Require(Screen != 0, "screen DC unavailable")
	Mem := DllCall("Gdi32\CreateCompatibleDC", "Ptr", Screen, "Ptr")
	Bitmap := DllCall("Gdi32\CreateCompatibleBitmap", "Ptr", Screen, "Int", 1, "Int", 1, "Ptr")
	Previous := 0
	try {
		_SCLP_Require(Mem && Bitmap, "control bitmap unavailable")
		Previous := DllCall("Gdi32\SelectObject", "Ptr", Mem, "Ptr", Bitmap, "Ptr")
		_SCLP_Require(Previous != 0, "control selection refused")
		_SCLP_Require(DllCall("Gdi32\BitBlt", "Ptr", Mem, "Int", 0, "Int", 0, "Int", 1, "Int", 1, "Ptr", Screen, "Int", X, "Int", Y, "UInt", 0x40CC0020, "Int"), "CAPTUREBLT control refused")
		return DllCall("Gdi32\GetPixel", "Ptr", Mem, "Int", 0, "Int", 0, "UInt")
	} finally {
		if Previous
			DllCall("Gdi32\SelectObject", "Ptr", Mem, "Ptr", Previous, "Ptr")
		if Bitmap
			DllCall("Gdi32\DeleteObject", "Ptr", Bitmap)
		if Mem
			DllCall("Gdi32\DeleteDC", "Ptr", Mem)
		DllCall("ReleaseDC", "Ptr", 0, "Ptr", Screen)
	}
}
_SCLP_ReadPixel(Path) {
	Image := 0, Pixel := 0
	_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipLoadImageFromFile", "WStr", Path, "Ptr*", &Image, "Int"), "load captured PNG")
	try {
		_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipBitmapGetPixel", "Ptr", Image, "Int", 0, "Int", 0, "UInt*", &Pixel, "Int"), "read captured pixel")
		return Pixel & 0xffffff
	} finally _GestureScreenshotGdipDispose(Image)
}
_SCLP_Done(State, Ok, Reason := "") {
	State.Calls += 1, State.Ok := Ok, State.Reason := Reason
}
_SCLP_Main() {
	global DriverPid
	_SCLP_Require(A_Args.Length == 2 && (A_Args[1] == "ordinary" || A_Args[1] == "layered"), "private mode and root required")
	DriverPid := ProcessExist()
	Back := Gui("-Caption +ToolWindow"), Front := Gui("-Caption +ToolWindow")
	State := {Calls: 0, Ok: false, Reason: ""}, Path := A_Args[2] . "\capture.png"
	try {
		Back.BackColor := "FF0000", Front.BackColor := "00FF00"
		Back.Show("x100 y100 w80 h80 NA")
		Front.Show("x100 y100 w80 h80")
		WinActivate("ahk_id " . Front.Hwnd)
		if A_Args[1] == "layered"
			WinSetTransparent(255, "ahk_id " . Front.Hwnd)
		DllCall("dwmapi\DwmFlush", "Int")
		Sleep(150)
		Flags := DllCall("GetWindowLongPtr", "Ptr", Front.Hwnd, "Int", -20, "Ptr")
		_SCLP_Require(!!(Flags & 0x80000) == (A_Args[1] == "layered"), "requested native layered style must be present only in layered control")
		Control := _SCLP_ControlPixel(140, 140)
		_SCLP_Require(Control == 0x00ff00, "CAPTUREBLT native control must see the exact owned green surface")
		Started := GestureCaptureRegion(140, 140, 1, 1, "save", Path, _SCLP_Done.Bind(State))
		_SCLP_Require(Started is Integer && Started == 1, "real public capture must start")
		Tick := A_TickCount
		while !State.Calls && A_TickCount - Tick < 10000
			Sleep(10)
		_SCLP_Require(State.Calls == 1 && State.Ok && FileExist(Path), "real worker must publish exact PNG")
		Pixel := _GestureScreenshotWithGdiplus(_SCLP_ReadPixel.Bind(Path))
		FileAppend("OBSERVATION screenshot-layered-native mode=" . A_Args[1] . " control=" . Control . " published=" . Pixel . " calls=" . State.Calls . "`n", "*")
		_SCLP_Require(Pixel == 0x00ff00, "public screenshot must include the visible owned green surface")
	} finally {
		GestureScreenshotCancelAll("private fixture cleanup")
		Front.Destroy(), Back.Destroy()
	}
	FileAppend("PASS screenshot-layered-native " . A_Args[1] . "`n", "*")
}
try _SCLP_Main()
catch Any as _SCLP_ChildFailure {
	FileAppend("FAIL screenshot-layered-native " . _SCLP_ChildFailure.Message . " [" . _SCLP_ChildFailure.File . ":" . _SCLP_ChildFailure.Line . "]`n", "*")
	ExitApp(1)
}
ExitApp(0)
