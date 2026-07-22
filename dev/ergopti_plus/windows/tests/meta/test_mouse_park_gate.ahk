; tests/meta/test_mouse_park_gate.ahk

#Requires AutoHotkey v2.0

_MPG_AssertMouseParkGate() {
	; Move-resilient: locate KL_Mouse_ParkTick() across the whole driver source
	; via the framework helper instead of a pinned modules path
	Body := _DriverFuncBody("KL_Mouse_ParkTick")

	SuspendedIdx := InStr(Body, "if (!A_IsSuspended")
	Assert(SuspendedIdx > 0, "KL_Mouse_ParkTick must evaluate MF_ShouldFilter only when not suspended (mouse-park-distance-no-gate)")
	
	ReturnIdx := InStr(Body, "return", false, SuspendedIdx)
	DistanceIdx := InStr(Body, "KL_BumpMouseDistance", false, SuspendedIdx)
	
	Assert(ReturnIdx < DistanceIdx, "KL_Mouse_ParkTick must return early when suspended/filtered BEFORE accumulating distance (mouse-park-distance-no-gate)")
}

Test("keylogger_mouse: KL_Mouse_ParkTick gates distance accumulation (mouse-park-distance-no-gate)", _MPG_AssertMouseParkGate)
