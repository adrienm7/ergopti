; tests/meta/test_mouse_park_gate.ahk

#Requires AutoHotkey v2.0

_MPG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_MPG_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	return Rest
}

_MPG_AssertMouseParkGate() {
	Src := _MPG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	
	Body := _MPG_FuncBodyStripped(Src, "KL_Mouse_ParkTick() {")
	
	SuspendedIdx := InStr(Body, "if (!A_IsSuspended")
	Assert(SuspendedIdx > 0, "KL_Mouse_ParkTick must evaluate MF_ShouldFilter only when not suspended (mouse-park-distance-no-gate)")
	
	ReturnIdx := InStr(Body, "return", false, SuspendedIdx)
	DistanceIdx := InStr(Body, "KL_BumpMouseDistance", false, SuspendedIdx)
	
	Assert(ReturnIdx < DistanceIdx, "KL_Mouse_ParkTick must return early when suspended/filtered BEFORE accumulating distance (mouse-park-distance-no-gate)")
}

Test("keylogger_mouse: KL_Mouse_ParkTick gates distance accumulation (mouse-park-distance-no-gate)", _MPG_AssertMouseParkGate)
