; tests/meta/test_tray_build_critical_restore.ahk
#Requires AutoHotkey v2.0

Test_TrayBuildStagesBeforeCriticalPublication() {
	BuildBody := _DriverFuncBody("BuildTrayMenuDeferred")
	PublishBody := _DriverFuncBody("TrayMenuStage_Publish")
	Assert(InStr(BuildBody, 'Critical("On")') = 0,
		"deferred tray construction must not hold Critical while rendering menus")
	Acquire := InStr(PublishBody, '_PublishCritical := Critical("On")')
	FinallyAt := InStr(PublishBody, "finally", false, Acquire)
	Restore := InStr(PublishBody, "Critical(_PublishCritical)", false, FinallyAt)
	Assert(Acquire > 0 and FinallyAt > Acquire and Restore > FinallyAt,
		"staged publication must restore the caller Critical state after the atomic root replacement")
}

Test("tray menu: staged publication restores Critical state", Test_TrayBuildStagesBeforeCriticalPublication)
