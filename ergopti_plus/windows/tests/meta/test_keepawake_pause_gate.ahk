; tests/meta/test_keepawake_pause_gate.ahk

#Requires AutoHotkey v2.0

_KPG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_KPG_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_KPG_AssertPauseGates() {
	Src := _KPG_ReadSource("modules/shortcuts/win.ahk")
	
	Funcs := ["SimulateActivity", "AwakeCheckMouseMoved", "AwakeReturnToOrigin", "AwakeCancelOnKeypress", "AwakeCancelOnMouse"]
	
	for _, FuncDef in Funcs {
		Body := _KPG_FuncBodyStripped(Src, FuncDef . "(")
		Assert(InStr(Body, "if A_IsSuspended") > 0, FuncDef . " must have an early return for A_IsSuspended (keepawake-bypasses-pause)")
	}
}

_KPG_AssertOnSuspendEnter() {
	Src := _DriverSourceConcat()
	Body := _KPG_FuncBodyStripped(Src, "Ergopti_OnSuspendEnter() {")
	Assert(InStr(Body, "StopActivitySimulation()") > 0, "Ergopti_OnSuspendEnter must call StopActivitySimulation (keepawake-bypasses-pause)")
}

Test("shortcuts: keep-awake functions have A_IsSuspended gates (keepawake-bypasses-pause)", _KPG_AssertPauseGates)
Test("core: Ergopti_OnSuspendEnter stops activity simulation (keepawake-bypasses-pause)", _KPG_AssertOnSuspendEnter)
