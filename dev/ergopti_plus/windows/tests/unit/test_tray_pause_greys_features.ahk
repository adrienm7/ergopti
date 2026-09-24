; tests/unit/test_tray_pause_greys_features.ahk

; ==============================================================================
; MODULE: Tray Pause Greys Feature Submenus
; DESCRIPTION:
; Regression guard for tray-pause-greys-features. While the driver is paused,
; every FEATURE submenu of the tray (layout, hotstrings, IA, metrics, shortcuts,
; tap-holds, gestures) must be greyed out, while the global rows (actions,
; language, about, « Suspendre », reload, quit, debug) stay enabled so resume
; still works.
;
; ROOT CAUSE ENCODED: UpdateTrayIcon only swapped the icon and the « Suspendre »
; checkmark, and tray rebuilds are refused while paused, so nothing ever touched
; the live feature rows. The fix records the feature head rows at their single
; staging point (TrayMenuStage_AddFeature), and TrayMenu_ApplyPauseGreying
; disables or re-enables exactly those rows on the live root, from UpdateTrayIcon
; and right after every publication. The behaviour is read back through the Win32
; GetMenuState of a real native menu, not through bookkeeping.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPGF_IsGreyed(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400, MF_GRAYED := 0x1, MF_DISABLED := 0x2
	State := DllCall("GetMenuState", "ptr", TargetMenu.Handle, "uint", Position,
		"uint", MF_BYPOSITION, "uint")
	Assert(State != 0xFFFFFFFF, "GetMenuState must find row " . Position)
	return (State & (MF_GRAYED | MF_DISABLED)) != 0
}

; Publishes the staged tree into a detached native menu, never the test's tray.
_TPGF_ReplayInto(TargetMenu, Stage) {
	for _, Entry in Stage {
		if (Entry["kind"] == "submenu")
			TargetMenu.Add(Entry["label"], Entry["target"])
	}
	return true
}

_TPGF_PauseGreysOnlyFeatureRows() {
	global _TrayMenuStage, _TrayFeatureHeadLabels
	SavedStage := _TrayMenuStage
	SavedLabels := _TrayFeatureHeadLabels
	Root := Menu()
	try {
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		TrayMenuStage_AddFeature("Layout", Menu())
		TrayMenuStage_AddFeature("Hotstrings (12)", Menu())
		TrayMenuStage_AddFeature("Gestures", Menu())
		TrayMenuStage_Add("Global actions", Menu())
		TrayMenuStage_Add("Language", Menu())
		TrayMenuStage_Add("Pause", Menu())
		TrayMenuStage_Add("Debug", Menu())
		AssertTrue(TrayMenuStage_Publish(0, _TPGF_ReplayInto.Bind(Root)))
		AssertEqual(3, _TrayFeatureHeadLabels.Length,
			"publication must record exactly the staged feature head rows")

		AssertEqual(3, TrayMenu_ApplyPauseGreying(true, Root))
		Loop 3
			AssertTrue(_TPGF_IsGreyed(Root, A_Index - 1),
				"feature row " . A_Index . " must be greyed while paused")
		Loop 4
			AssertFalse(_TPGF_IsGreyed(Root, A_Index + 2),
				"global row " . (A_Index + 3) . " must stay enabled while paused")

		AssertEqual(3, TrayMenu_ApplyPauseGreying(false, Root))
		Loop 7
			AssertFalse(_TPGF_IsGreyed(Root, A_Index - 1),
				"every row must be enabled again after resume (row " . A_Index . ")")
	} finally {
		_TrayMenuStage := SavedStage
		_TrayFeatureHeadLabels := SavedLabels
	}
}

; The live-root owners must actually call the greying: the pause transition
; (UpdateTrayIcon) and the default publication path.
_TPGF_OwnersApplyGreying() {
	Icon := _DriverFuncBody("UpdateTrayIcon")
	Assert(Icon != "", "UpdateTrayIcon must be readable")
	Assert(InStr(Icon, "TrayMenu_ApplyPauseGreying(A_IsSuspended)") > 0,
		"UpdateTrayIcon must grey or restore the feature rows on every pause transition")
	Publish := _DriverFuncBody("TrayMenuStage_Publish")
	Assert(Publish != "", "TrayMenuStage_Publish must be readable")
	Assert(InStr(Publish, "TrayMenu_ApplyPauseGreying(A_IsSuspended)") > 0,
		"a freshly published root must receive the current pause state")
}

; Every head row declared before the tail must be staged as a feature row, so a
; new head submenu cannot silently stay live while paused.
_TPGF_EveryHeadRowIsAFeature() {
	Body := _StripFullLineComments(_DriverFuncBody("initMenu"))
	Assert(Body != "", "initMenu must be readable")
	Head := SubStr(Body, 1, InStr(Body, "_MI_AssertHeadOrder(") - 1)
	Assert(Head != "", "initMenu must stage its head before _MI_AssertHeadOrder")
	AssertEqual(0, InStr(Head, "TrayMenuStage_Add("),
		"a head row staged with the plain TrayMenuStage_Add would stay live while paused")
	AssertEqual(6, StrLen(Head) - StrLen(StrReplace(Head, "TrayMenuStage_AddFeature(", "TrayMenuStage_AddFeature")),
		"initMenu must stage its six non-IA head rows as feature rows")
	Llm := _StripFullLineComments(_DriverFuncBody("LLM_Menu_Init"))
	Assert(Llm != "", "LLM_Menu_Init must be readable")
	AssertEqual(0, InStr(Llm, 'TrayMenuStage_Add(t("menu.llm.title")'),
		"the IA head row must be staged as a feature row")
}

Test("tray pause: feature submenus greyed, global rows live, restored on resume (tray-pause-greys-features)",
	_TPGF_PauseGreysOnlyFeatureRows)
Test("tray pause: UpdateTrayIcon and publication apply the greying (tray-pause-greys-features)",
	_TPGF_OwnersApplyGreying)
Test("tray pause: every tray head row is staged as a feature row (tray-pause-greys-features)",
	_TPGF_EveryHeadRowIsAFeature)
