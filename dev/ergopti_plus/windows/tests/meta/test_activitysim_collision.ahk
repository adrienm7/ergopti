; tests/meta/test_activitysim_collision.ahk

#Requires AutoHotkey v2.0

_ASC_GestureUsesCanonicalToggle() {
	; Move-resilient: scope the gesture-specific usage to the modules tree and the
	; "must be deleted" checks to the whole driver source (strengthens them)
	Src := _DriverDirConcat("modules")
	Whole := _DriverSourceConcat()
	Assert(InStr(Src, "IsSet(ToggleActivitySimulation) ? ToggleActivitySimulation()") > 0, "gestures.ahk must use the canonical ToggleActivitySimulation() from shortcuts/win.ahk (activitysim-global-collision)")
	Assert(InStr(Whole, "GestureToggleActivitySimulation") == 0, "GestureToggleActivitySimulation must be deleted in favor of ToggleActivitySimulation (activitysim-global-collision)")
	Assert(InStr(Whole, "GestureSimulateActivity") == 0, "GestureSimulateActivity must be deleted in favor of win.ahk's keep-awake system (activitysim-global-collision)")
}
Test("gestures: Gesture action uses ToggleActivitySimulation from win.ahk (activitysim-global-collision)", _ASC_GestureUsesCanonicalToggle)
