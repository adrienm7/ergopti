; tests/meta/test_tray_build_critical_restore.ahk
#Requires AutoHotkey v2.0

Test_TrayBuildRestoresCriticalAfterFailure() {
	Body := _DriverFuncBody("BuildTrayMenuDeferred")
	Acquire := InStr(Body, '_MenuBuildCritical := Critical("On")')
	FinallyAt := InStr(Body, "finally", false, Acquire)
	Restore := InStr(Body, "Critical(_MenuBuildCritical)", false, FinallyAt)
	Assert(Acquire > 0 and FinallyAt > Acquire and Restore > FinallyAt,
		"tray menu construction must restore the caller Critical state in an outer finally")
	Assert(!InStr(Body, 'Critical("Off")'),
		"tray menu construction must restore the prior Critical state, not blindly turn it off")
}

Test("tray menu: failed deferred build restores Critical state", Test_TrayBuildRestoresCriticalAfterFailure)
