; tests/unit/ui/menu/test_tray_pause_greys_features.ahk

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

; The top-level ids a pause switches off: the rows the manifest marks
; `greyed_when_paused`, visible on this platform. Each one's root builder must
; stage its row as a feature row so the pause greys it, and every other builder
; must stage a plain row so « Suspendre », language, reload, quit and debug stay
; live. Read from the manifest, which the macOS and Linux roots read too, so the
; three trays grey the same rows.
_TPGF_MarkedFeatureIds() {
	Ids := []
	for _, Entry in MenuManifest_LoadTopLevel() {
		if (Entry is Map) && _MR_IsForAhk(Entry) && (Entry.Get("greyed_when_paused", false) == true)
			Ids.Push(Entry["id"])
	}
	return Ids
}

; The marked rows that stay live while paused (EDD-1): their configuration rows
; run then, and the rows that wait for the resume are greyed with why
; (_LAY_GreyPausedRows). They stay marked, so the boot shell still leaves them
; out until the features are ready.
_TPGF_LiveWhilePausedIds() {
	return Map("keyboard_layout", true)
}

_TPGF_EveryFeatureRowIsStagedAsAFeature() {
	Builders := _MI_TopLevelBuilders()
	Features := Map()
	Live := _TPGF_LiveWhilePausedIds()
	Marked := _TPGF_MarkedFeatureIds()
	Assert(Marked.Length >= 7, "the manifest must mark the feature rows a pause greys, got " . Marked.Length)
	for _, Id in Marked {
		Assert(Builders.Has(Id), "the tray root must have a builder for the feature row " . Id)
		Features[Id] := true
	}
	DeclaredFeatureBody := _StripFullLineComments(_DriverFuncBody("_MI_StageDeclaredFeature"))
	Assert(DeclaredFeatureBody != "", "the shared feature staging owner must be readable")
	Assert(RegExMatch(DeclaredFeatureBody, 's)if Feature\s+TrayMenuStage_AddFeature\(Row\["label"\], Child\)\s+else\s+TrayMenuStage_Add\(Row\["label"\], Child\)'),
		"the declared parent stages a feature unless its caller keeps it live while paused")
	Checked := 0
	for Id, Builder in Builders {
		Body := _StripFullLineComments(_DriverFuncBody(Builder.Name))
		Assert(Body != "", "the actual tray root builder " . Builder.Name . " must be readable")
		; Only a genuine direct call reaches this shared feature staging owner.
		Declared := RegExMatch(Body, "m)^[ \t]*_MI_StageDeclaredFeature\((.*)\)\s*$", &Call)
		; The IA row is staged by LLM_Menu_Init, which owns its persistent submenu.
		if (Id == "llm")
			Body .= _StripFullLineComments(_DriverFuncBody("LLM_Menu_Init"))
		KeptLive := Declared && RegExMatch(Call[1], ", true, false$")
		if Features.Has(Id) && Live.Has(Id) {
			Assert(KeptLive, "the " . Id . " row stays live while paused (EDD-1)")
		} else if Features.Has(Id) {
			Assert(!KeptLive, "the " . Id . " row must be greyed by a pause")
			Assert(Declared || InStr(Body, "TrayMenuStage_AddFeature(") > 0 || InStr(Body, "TrayMenuStage_AddFeatureAction(") > 0,
				"the " . Id . " row must be staged as a feature row so a pause greys it")
			AssertEqual(0, InStr(Body, "TrayMenuStage_Add("),
				"the " . Id . " row staged with the plain TrayMenuStage_Add would stay live while paused")
		} else {
			AssertFalse(Declared, "the " . Id . " row is no feature: greyed by a pause, it could not be used to resume or leave")
			AssertEqual(0, InStr(Body, "TrayMenuStage_AddFeature(") + InStr(Body, "TrayMenuStage_AddFeatureAction("),
				"the " . Id . " row is no feature: greyed by a pause, it could not be used to resume or leave")
		}
		Checked += 1
	}
	Assert(Checked >= 12, "the tray root must dispatch at least twelve builders, read " . Checked)
}

; The Layout rows that wait for the resume are greyed with why while paused, and
; the others, the magic key capture among them, stay live (paused-layout-live).
_TPGF_LayoutRowsWaitOnlyWhereNeeded() {
	Target := Menu()
	Noop := (*) => 0
	Keys := _LAY_PausedRowKeys()
	AssertEqual(2, Keys.Length, "the layout manager and the layout editor wait for the resume")
	for Key in Keys
		Target.Add(t(Key), Noop)
	Capture := t("menu.layout.magic_key_source.capture")
	Target.Add(Capture, Noop)
	AssertEqual(0, _LAY_GreyPausedRows(Target, false), "an active driver greys no Layout row")
	Loop 3
		AssertFalse(_TPGF_IsGreyed(Target, A_Index - 1), "row " . A_Index . " is live while active")
	AssertEqual(2, _LAY_GreyPausedRows(Target, true))
	Reason := _MR_ReasonHead(t("menu.shortcuts.keyboard.magic_editor_reason.paused"))
	for Index, Key in Keys {
		AssertTrue(_TPGF_IsGreyed(Target, Index - 1), Key . " waits for the resume")
		AssertEqual(t(Key) . " — " . Reason, _TPGF_Label(Target, Index - 1), Key . " says why")
	}
	AssertFalse(_TPGF_IsGreyed(Target, 2), "the magic key capture runs while paused")
	AssertEqual(Capture, _TPGF_Label(Target, 2))
}

_TPGF_Label(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Buf := Buffer(1024, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position, "ptr", Buf, "int", 512,
		"uint", MF_BYPOSITION, "int")
	return StrGet(Buf, "UTF-16")
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

Test("tray pause: feature submenus greyed, global rows live, restored on resume (tray-pause-greys-features)",
	_TPGF_PauseGreysOnlyFeatureRows)
Test("tray pause: UpdateTrayIcon and publication apply the greying (tray-pause-greys-features)",
	_TPGF_OwnersApplyGreying)
Test("tray pause: every feature row of the root is staged as a feature row (tray-pause-greys-features)",
	_TPGF_EveryFeatureRowIsStagedAsAFeature)
Test("tray pause: the Layout rows that wait for the resume are greyed with why, the others live (paused-layout-live)",
	_TPGF_LayoutRowsWaitOnlyWhereNeeded)
Test("tray pause: a pause or a resume builds the live Layout submenu again (paused-layout-live)",
	_TPGF_RearmRebuildsAtNextOpen)
