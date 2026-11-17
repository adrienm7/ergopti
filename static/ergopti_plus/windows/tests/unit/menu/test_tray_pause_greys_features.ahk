; tests/unit/menu/test_tray_pause_greys_features.ahk

; ==============================================================================
; MODULE: Tray Pause Keeps Feature Submenus Live
; DESCRIPTION:
; A pause stops typing, not configuration (EDD-1, maintainer 2026-11-12): every
; tray row stays live while the driver is paused, as on macOS and Linux, and no
; row inside a submenu is greyed by the pause either.
;
; ROOT CAUSE ENCODED: the tray greyed every feature head on a pause
; (tray-pause-greys-features), so the configuration a pause must keep was out of
; reach. A root built before a pause or a resume would also show a stale state
; once the heads stay live, so the watchdog rebuilds the published root once the
; transition settled (pause-root-rebuild). The file keeps its historical name.
; ==============================================================================

#Requires AutoHotkey v2.0

; The greying owners are gone, and nothing on the pause path disables a head row.
_TPGF_NoHeadGreying() {
	for Name in ["TrayMenu_ApplyPauseGreying", "TrayMenuStage_AddFeature",
			"TrayMenuStage_AddFeatureAction", "_TrayStageFeatureLabels"]
		AssertEqual("", _DriverFuncBodyOrEmpty(Name), Name . " must stay deleted (EDD-1)")
	Icon := _StripFullLineComments(_DriverFuncBody("UpdateTrayIcon"))
	AssertEqual(0, InStr(Icon, ".Disable("), "a pause transition greys no tray row")
	Publish := _StripFullLineComments(_DriverFuncBody("TrayMenuStage_Publish"))
	AssertEqual(0, InStr(Publish, "A_IsSuspended"), "a publication reads no pause state: each row reads it while built")
}

; Each top-level builder stages a plain row: no entry carries a feature mark a
; pause could grey (Ergopti Studio stands for the command rows).
_TPGF_StudioRowStagedPlain() {
	global _TrayMenuStage
	Builders := _MI_TopLevelBuilders()
	Stage := TrayMenuStage_Begin()
	try {
		Builders["ergopti_studio"].Call()
		AssertEqual(1, Stage.Length)
		AssertEqual("action", Stage[1]["kind"])
		AssertFalse(Stage[1].Has("feature"), "the row carries no pause mark")
	} finally TrayMenuStage_Abort()
	AssertFalse(IsObject(_TrayMenuStage), "the stage is released")
}

; The watchdog rebuilds the published root once a transition settled, and never
; before a first root: the boot build reads the pause state itself.
_TPGF_TransitionRebuildsThePublishedRoot() {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration, _TrayRootBootDetailsPending
	Watchdog := _StripFullLineComments(_DriverFuncBody("_SuspendStateWatchdog"))
	BusyPos := InStr(Watchdog, "_TransitionBusy := false", false,
		InStr(Watchdog, "_TransitionBusy := true"))
	RebuildPos := InStr(Watchdog, "TrayMenu_RebuildForPauseState()", false, BusyPos)
	Assert(BusyPos > 0 && RebuildPos > BusyPos,
		"the watchdog must rebuild the root after the transition released its owner")
	Body := _StripFullLineComments(_DriverFuncBody("TrayMenu_RebuildForPauseState"))
	Assert(InStr(Body, "return RebuildTrayMenu()") > 0, "a settled transition requests one ordinary root rebuild")
	Saved := [_TrayRootRequestedGeneration, _TrayRootPublishedGeneration, _TrayRootBootDetailsPending]
	try {
		_TrayRootRequestedGeneration := 0, _TrayRootPublishedGeneration := 0, _TrayRootBootDetailsPending := false
		AssertFalse(TrayMenu_RebuildForPauseState(), "no root is published yet")
		_TrayRootRequestedGeneration := 2, _TrayRootPublishedGeneration := 1, _TrayRootBootDetailsPending := true
		AssertFalse(TrayMenu_RebuildForPauseState(), "the boot build is still publishing its details")
	} finally {
		_TrayRootRequestedGeneration := Saved[1]
		_TrayRootPublishedGeneration := Saved[2]
		_TrayRootBootDetailsPending := Saved[3]
	}
}

; No Layout row waits for the resume any more: the layout manager and the
; layout editor save while paused (EDD-1), so the pause greying of their rows is
; gone with its owners, and the Layout build reads no pause state
; (paused-layout-live).
_TPGF_LayoutRowsAllLive() {
	for Name in ["_LAY_GreyPausedRows", "_LAY_PausedRowKeys"]
		AssertEqual("", _DriverFuncBodyOrEmpty(Name), Name . " must stay deleted (EDD-1)")
	Build := _StripFullLineComments(_DriverFuncBody("_LAY_BuildLayoutMenu"))
	Assert(InStr(Build, "MenuRenderer_Build(") > 0, "the Layout submenu is built by the shared renderer")
	AssertEqual(0, InStr(Build, "A_IsSuspended"), "the Layout build reads no pause state")
	AssertEqual(0, InStr(Build, ".Disable("), "the Layout build greys no row")
}

; A pause or a resume builds the live Layout submenu again at its next open, so
; it shows what waits; a submenu still waiting for its build is left as it is.
_TPGF_RearmRebuildsAtNextOpen() {
	global _MenuDeferredChildren
	Count := Map("built", 0)
	Build := (Target) => (Count["built"] += 1, Target.Add("row", (*) => 0))
	Child := Menu()
	Build.Call(Child)
	AssertTrue(MenuDeferred_Rearm(Child, Build, "layout_menu"), "a built submenu is armed again")
	AssertTrue(_MenuDeferredChildren.Has(Child.Handle), "its next open builds it")
	AssertFalse(MenuDeferred_Rearm(Child, Build, "layout_menu"), "a pending submenu is left as it is")
	AssertTrue(MenuDeferred_Build(Child.Handle, "test"))
	AssertEqual(2, Count["built"], "the next open builds it from the state of that moment")
	AssertFalse(_MenuDeferredChildren.Has(Child.Handle))
	Enter := _DriverFuncBody("Ergopti_OnSuspendEnter"), Resume := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(InStr(Enter, "_MI_LayoutRearmForPause()") > 0 && InStr(Resume, "_MI_LayoutRearmForPause()") > 0,
		"a pause and a resume arm the Layout submenu again")
}

Test("tray pause: no head row is greyed by a pause or a publication (pause-keeps-features-live)",
	_TPGF_NoHeadGreying)
Test("tray pause: a root builder stages a plain row without a pause mark (pause-keeps-features-live)",
	_TPGF_StudioRowStagedPlain)
Test("tray pause: a settled transition rebuilds the published root, never the boot one (pause-root-rebuild)",
	_TPGF_TransitionRebuildsThePublishedRoot)
Test("tray pause: every Layout row stays live while paused (paused-layout-live)",
	_TPGF_LayoutRowsAllLive)
Test("tray pause: a pause or a resume builds the live Layout submenu again (paused-layout-live)",
	_TPGF_RearmRebuildsAtNextOpen)
