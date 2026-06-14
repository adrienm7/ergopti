; tests/meta/test_activitysim_collision.ahk

#Requires AutoHotkey v2.0

_ASC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_ASC_GestureUsesCanonicalToggle() {
	Src := _ASC_ReadSource("modules/gestures.ahk")
	Assert(InStr(Src, "ToggleActivitySimulation") > 0, "gestures.ahk must use the canonical ToggleActivitySimulation() from shortcuts/win.ahk (activitysim-global-collision)")
	Assert(InStr(Src, "GestureToggleActivitySimulation") == 0, "GestureToggleActivitySimulation must be deleted in favor of ToggleActivitySimulation (activitysim-global-collision)")
	Assert(InStr(Src, "GestureSimulateActivity") == 0, "GestureSimulateActivity must be deleted in favor of win.ahk's keep-awake system (activitysim-global-collision)")
}
Test("gestures: Gesture action uses ToggleActivitySimulation from win.ahk (activitysim-global-collision)", _ASC_GestureUsesCanonicalToggle)
