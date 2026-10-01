; static/ergopti_plus/windows/tests/unit/test_uninstall_source_run.ahk

; ==============================================================================
; MODULE: Uninstall Row On A Source Run (Windows)
; DESCRIPTION:
; « Désinstaller Ergopti » stayed live on a local version run from the source
; tree, where a click could only end in « Ergopti n'a pas pu être
; désinstallé ». The About row is now greyed there like every row greyed with
; a reason, « label — head of the reason » (the manifest's
; disabled_reason_key), with nothing to run, and live on an installed build; a
; click that still reaches the handler on a source run does nothing and shows
; no dialog. The row is drawn from the real manifest into a native menu.
; ==============================================================================





; ====================================
; ====================================
; ======= 1/ The Uninstall Row =======
; ====================================
; ====================================

; The text of a native menu row at a zero-based position.
_USR_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Text := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Text, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Text, "UTF-16")
}

; Draws the About menu's uninstall row into a native menu with the
; installed-build getter given, and reads it back.
; @param {Boolean} Installed What the installed_build getter answers.
; @returns {Map} { label, greyed, clicks } of the drawn row.
_USR_Draw(Installed) {
	static MF_BYPOSITION := 0x400, GREYED := 0x3
	Clicks := [0]
	Target := Menu()
	try {
		Drawn := MenuRenderer_AppendCommand(Target, "about_menu", "uninstall",
			Map("uninstall", (*) => Clicks[1] += 1), Map("installed_build", () => Installed))
		AssertEqual(1, Drawn, "the uninstall row is drawn")
		AssertEqual(1, TrayMenuItemCount(Target), "one row, nothing else")
		State := DllCall("GetMenuState", "ptr", Target.Handle, "uint", 0, "uint", MF_BYPOSITION, "uint")
		return Map("label", _USR_LabelAt(Target, 0), "greyed", (State & GREYED) != 0, "clicks", Clicks)
	} finally {
		Target.Delete()
		MenuDispatcher_PruneMenu(Target)
	}
}

_TestUninstallRowInstalled() {
	Row := _USR_Draw(true)
	AssertEqual(t("menu.global.uninstall"), Row["label"], "an installed build shows the plain label")
	AssertFalse(Row["greyed"], "an installed build keeps Uninstall live")
}
Test("uninstall row: an installed build offers it live (menu-uninstall-source)", _TestUninstallRowInstalled)

_TestUninstallRowSource() {
	Row := _USR_Draw(false)
	AssertTrue(Row["greyed"], "a source run greys Uninstall")
	Head := _MR_ReasonHead(t("menu.about.source_run_reason"))
	Assert(Head != "" && !InStr(Head, ":") && Head != "menu.about.source_run_reason",
		"the reason is translated and cut to its head")
	AssertEqual(t("menu.global.uninstall") . " — " . Head, Row["label"],
		"a source run names why as every greyed row with a reason")
	AssertEqual(0, Row["clicks"][1], "drawing it runs nothing")
}
Test("uninstall row: a source run greys it and names why (menu-uninstall-source)", _TestUninstallRowSource)

; A provider row greyed with a reason reads the same, and has nothing to run.
_TestGreyedProviderRow() {
	static MF_BYPOSITION := 0x400, GREYED := 0x3
	Target := Menu()
	try {
		Drawn := _MR_RenderRows(Target, [Map("label", "Update to v9", "disabled", true,
			"disabled_reason_key", "menu.about.source_run_reason", "action", (*) => "")], "test_rows", 1)
		AssertEqual(1, Drawn, "the provider row is drawn")
		AssertEqual("Update to v9 — " . _MR_ReasonHead(t("menu.about.source_run_reason")),
			_USR_LabelAt(Target, 0), "a greyed provider row names why like a manifest one")
		State := DllCall("GetMenuState", "ptr", Target.Handle, "uint", 0, "uint", MF_BYPOSITION, "uint")
		Assert((State & GREYED) != 0, "the provider row is disabled")
	} finally {
		Target.Delete()
		MenuDispatcher_PruneMenu(Target)
	}
}
Test("uninstall row: a greyed provider row names its reason the same way (menu-uninstall-source)",
	_TestGreyedProviderRow)

_TestUninstallAboutGetter() {
	Body := _DriverFuncBody("_MI_BuildAboutMenu")
	AssertTrue(RegExMatch(Body, '"installed_build",\s*\(\)\s*=>\s*!Updater_IsLocalSource\(\)') > 0,
		"the About menu must answer installed_build from Updater_IsLocalSource")
	AssertTrue(InStr(Body, "Providers, Commands, StateGetters)") > 0,
		"the About menu must hand its getters to the renderer")
}
Test("uninstall row: the About menu answers installed_build from the one owner (menu-uninstall-source)",
	_TestUninstallAboutGetter)





; ==========================================
; ==========================================
; ======= 2/ A Click On A Source Run =======
; ==========================================
; ==========================================

_TestUninstallSourceClickDoesNothing() {
	; The runner is a source run: A_IsCompiled is false here.
	AssertTrue(Updater_IsLocalSource(), "the test runner runs from source")
	Dialogs := TestMsgBoxCount()
	AssertFalse(ShowUninstallErgopti(), "a source run removes nothing")
	AssertEqual(Dialogs, TestMsgBoxCount(), "and shows no dialog")
	AssertFalse(UninstallState().Has("Owner"), "and starts no removal transaction")
}
Test("uninstall row: a click on a source run does nothing (menu-uninstall-source)",
	_TestUninstallSourceClickDoesNothing)
