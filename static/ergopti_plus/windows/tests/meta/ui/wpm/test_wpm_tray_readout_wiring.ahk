; tests/meta/ui/wpm/test_wpm_tray_readout_wiring.ahk

; ==============================================================================
; MODULE: WPM Notification-Area Readout Wiring
; DESCRIPTION:
; Windows had no counterpart of the macOS menu bar and Linux tray readout: the
; two Metrics rows were declared hs/linux only (platform_reason
; wpm_readout_needs_a_menubar). Aligned on those drivers (2026-11-06), the
; rows are declared on ahk too and drive wpm_tray_readout.ahk. These checks
; pin each joint a green menu could hide: the ring that feeds the readout, the
; shared canon it paints from, the pause and exit owners, and the menu rows.
; ==============================================================================

#Requires AutoHotkey v2.0

_WTRW_Body(Name) {
	Body := _DriverFuncBody(Name)
	Assert(Body != "", Name . " must exist in the driver source")
	return Body
}

_WTRW_RingFeedsTheReadout() {
	Push := _WTRW_Body("WPMWidget_Push")
	AssertEqual(0, InStr(Push, "!WPMWidget.visible"), "the ring must not fill only for the floating widget")
	AssertTrue(InStr(Push, "_WPMWidget_Collecting()") > 0, "the ring fills while either readout is on")
	AssertContains(_WTRW_Body("_WPMWidget_Collecting"), "WPMTrayReadout.running")
}
Test("wpm tray readout: the keystroke ring fills while the readout runs (wpm-tray-readout)", _WTRW_RingFeedsTheReadout)

_WTRW_FrameFollowsTheSharedModel() {
	Frame := _WTRW_Body("WPMTrayReadout_Frame")
	for Needle in ["WPMWidget_Calc()", "WPMWidget_ActiveSources()", "_WPMWidget_TooltipUp()",
			"WPMWidgetConst.MENUBAR_NEUTRAL_BG", "WPMWidgetConst.MENUBAR_ALPHA", "WPMWidget_ResolveBgColor("]
		AssertContains(Frame, Needle, "the frame follows Model.menubar_frame / menubar_visible: " . Needle)
	Tick := _WTRW_Body("WPMTrayReadout_Tick")
	for Needle in ["NotifyIcon_SetHidden(", "NotifyIcon_Publish(", "!WPMTrayReadout._added",
			"NotifyIcon_PaintNumber(", "WPMWidgetConst.MENUBAR_TEXT", "MetricsShortcuts.enabled"]
		AssertContains(Tick, Needle, "the tick hides, adds once and repaints: " . Needle)
	Config := _WTRW_Body("WPMWidget_LoadSharedConst")
	for Key in ['"menubar", "background_alpha"', '"menubar", "text_color"', '"menubar", "neutral_background"',
			'"ui", "wpm_menubar_update_ms"']
		AssertContains(Config, Key, "the readout reads the shared canon and timings: " . Key)
}
Test("wpm tray readout: frames come from the shared canon and model rules (wpm-tray-readout)",
	_WTRW_FrameFollowsTheSharedModel)

_WTRW_LifecycleOwners() {
	global LIFECYCLE_REQUIRED_OWNERS
	Found := false
	for Owner in LIFECYCLE_REQUIRED_OWNERS["suspend"]
		Found := Found || Owner == "wpm-tray-readout"
	AssertTrue(Found, "the pause transition declares the readout owner")
	AssertContains(_WTRW_Body("Ergopti_OnSuspendEnter"), '"wpm-tray-readout", WPMTrayReadout_HideForPause',
		"pausing hides the icon: the scheduler skips the refresh while paused")
	AssertContains(_WTRW_Body("Ergopti_OnShutdown"), "WPMTrayReadout_Shutdown()",
		"exit removes the icon instead of leaving a dead one")
	Start := _WTRW_Body("WPMTrayReadout_Start")
	AssertContains(Start, "NotifyIcon_TaskbarCreatedMessage()", "an Explorer restart is observed")
	AssertContains(Start, "OnMessage(", "and handled")
	AssertContains(_WTRW_Body("_WPMTrayReadout_OnTaskbarCreated"), "WPMTrayReadout._added := false",
		"TaskbarCreated re-adds the icon on the next frame")
	; Stop delegates the native removal to the one owner that also frees the icon.
	AssertContains(_WTRW_Body("WPMTrayReadout_Stop"), "_WPMTrayReadout_Remove()", "stopping removes the icon")
	AssertContains(_WTRW_Body("_WPMTrayReadout_Remove"), "NotifyIcon_Delete(", "stopping removes the icon")
}
Test("wpm tray readout: pause, exit and Explorer restart owners (wpm-tray-readout)", _WTRW_LifecycleOwners)

_WTRW_MenuRowsAndManifest() {
	Build := _WTRW_Body("BuildMetricsMenu")
	; The source scan reads generated constants as the literal they stand for.
	AssertContains(Build, _DriverResolveConstants("MenuCommand.WPM_MENUBAR") . ",", "the readout row has a Windows handler")
	AssertContains(Build, _DriverResolveConstants("MenuCommand.MENUBAR_COLORS") . ",", "its colour row has a Windows handler")
	Source := FileRead(_DriverProductionFileForSymbol("BuildMetricsMenu", _DriverDir), "UTF-8")
	for Getter in ['"metrics_menubar_wpm",', '"metrics_menubar_colors",', "ConfigLeaf.WPM_MENUBAR_VISIBLE,"]
		AssertContains(Source, Getter, "the declared tick and greying read the readout state: " . Getter)
	Manifest := FileRead(_DriverDir . "\_generated\features_manifest.ahk", "UTF-8")
	for Path in ["metrics.wpm_menubar_visible", "metrics.wpm_menubar_colors"] {
		AssertTrue(RegExMatch(Manifest, 'm)^.*"path", "' . Path . '".*$', &Row) > 0, Path . " is declared")
		AssertContains(Row[0], '"platforms", ["ahk", "hs", "linux"]', Path . " is declared on Windows")
		AssertEqual(0, InStr(Row[0], "reason_key"), Path . " carries no platform-absence reason any more")
	}
	Save := _WTRW_Body("_ConfigCollectFullSaveUpdates")
	AssertContains(Save, _DriverResolveConstants("ConfigLeaf.WPM_MENUBAR_VISIBLE") . ", Value: WPMTrayReadout.running", "a full save keeps the choice")
	AssertContains(Save, _DriverResolveConstants("ConfigLeaf.WPM_MENUBAR_COLORS") . ", Value: WPMTrayReadout.use_colors", "and its colour")
}
Test("wpm tray readout: menu rows, manifest and full save on Windows (wpm-tray-readout)", _WTRW_MenuRowsAndManifest)
