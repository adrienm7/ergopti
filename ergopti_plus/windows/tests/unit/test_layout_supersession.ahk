; tests/unit/test_layout_supersession.ahk

; ==============================================================================
; MODULE: Layout Features An Emulated Layout Supersedes — Tests
; DESCRIPTION:
; The Ergopti emulation's features (its layers and their overlays: typography,
; selection wrapping, the Ergopti+ changes) only apply while no registry layout
; is emulated. The independent digit-row swap stays available. The manifest
; declares the historical layer registrations, with the
; reason the menu shows, by superseded_reason_key (layout-supersession-declared):
; - the declared set is read from the manifest, not from a driver list;
; - the master gate turns off exactly what it is given;
; - the menu greys a superseded row and names the reason, only while a
;   registry layout is emulated;
; - MenuRowFromManifest (not loadable headlessly) is wired to that decision.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ The declared features =======
; ========================================
; ========================================

Test("layout supersession: the manifest declares the Ergopti emulation features and why (layout-supersession-declared)",
	_LSD_DeclaredCase)

_LSD_DeclaredCase() {
	Declared := Map()
	for Entry in LayoutSupersededFeatures()
		Declared[Entry["path"]] := Entry["superseded_reason_key"]
	Assert(Declared.Count >= 3, "the three Ergopti emulation features must remain declared, got " . Declared.Count)
	for Path in ["layout.ergopti_base", "layout.ergopti_alt_gr", "layout.ergopti_variant"]
		Assert(Declared.Has(Path), Path . " must be declared as superseded by an emulated layout")
	for Path in ["layout.ctrl_magic_save", "layout.emulated_layout", "layout.direct_access_digits"]
		AssertFalse(Declared.Has(Path), Path . " works whatever the layout and must not be declared")
	NumberRow := ManifestFindEntryByPath("layout.direct_access_digits")
	AssertEqual("enum", NumberRow["type"], "number-row policy cannot use boolean supersession")
	AssertEqual("native", ManifestDefaultFor("layout.direct_access_digits"))
	AssertEqual("native", NumberRowPolicyMode("native"))
	AssertEqual("digits", NumberRowPolicyMode("digits"))
	AssertEqual("symbols", NumberRowPolicyMode("symbols"))
	AssertEqual("", NumberRowPolicyMode(true), "legacy booleans must be migrated rather than coerced")
	for Path, Reason in Declared
		AssertTrue(t(Reason) != Reason, Path . " names a reason that does not translate: " . Reason)
}

Test("layout supersession: the master gate turns off the declared features it is given (layout-supersession-declared)",
	_LSD_GateCase)

_LSD_GateCase() {
	Target := Map("layout", Map("ergopti_base", true, "ctrl_magic_save", true, "emulated_layout", "ergol"))
	Only := [Map("section", "layout", "id", "ctrl_magic_save", "superseded_reason_key", "x")]
	AssertEqual(1, _MG_SupersedeForEmulatedLayout(Target, Only))
	AssertFalse(Target["layout"]["ctrl_magic_save"], "the declared feature is turned off")
	AssertTrue(Target["layout"]["ergopti_base"], "an undeclared feature is left alone")
	Target["layout"]["emulated_layout"] := ""
	Target["layout"]["ctrl_magic_save"] := true
	AssertEqual(0, _MG_SupersedeForEmulatedLayout(Target, Only), "nothing is superseded without an emulated layout")
	AssertTrue(Target["layout"]["ctrl_magic_save"])
}





; ====================================
; ====================================
; ======= 2/ The menu says why =======
; ====================================
; ====================================

Test("layout supersession: a superseded row is greyed with its reason while a layout is emulated (layout-supersession-declared)",
	_LSD_ReasonCase)

_LSD_ReasonCase() {
	Entry := ManifestFindEntryByPath("layout.ergopti_variant")
	Assert(Entry is Map, "layout.ergopti_variant must be in the manifest")
	Emulating := Map("layout", Map("emulated_layout", "ergol"))
	NotEmulating := Map("layout", Map("emulated_layout", ""))
	AssertEqual(Entry["superseded_reason_key"], LayoutSupersededReason(Entry, Emulating))
	AssertEqual("", LayoutSupersededReason(Entry, NotEmulating), "no reason without an emulated layout")
	Other := ManifestFindEntryByPath("layout.ctrl_magic_save")
	AssertEqual("", LayoutSupersededReason(Other, Emulating), "a feature that works on any layout keeps its row")
	for Path in ["layout.ergopti_base", "layout.ergopti_alt_gr", "layout.direct_access_digits"]
		AssertEqual("", LayoutSupersededReason(ManifestFindEntryByPath(Path), Emulating),
			Path . " remains editable as an independent layer choice")
}

Test("layout preferences: explicitly enabled geometry hotstrings survive every layout (layout-ergopti-hotstrings)",
	_LSD_ErgoptiHotstringsCase)

_LSD_ErgoptiHotstringsCase() {
	for Emulated in ["ergol", "ergopti_ansi", "unrecorded", ""] {
		Target := Map(
			"layout", Map("emulated_layout", Emulated),
			"hotstrings", Map(
				"sfbs_reduction", Map("comma", Map("enabled", true), "bu", Map("enabled", false)),
				"rolls", Map("hc", Map("enabled", true)),
				"autocorrection", Map("accents", Map("enabled", true))))
		ApplyMasterGatesToFeatures(Target, Map(), (*) => true)
		AssertTrue(Target["hotstrings"]["sfbs_reduction"]["comma"]["enabled"],
			"an explicit SFB choice remains active under '" . Emulated . "'")
		AssertTrue(Target["hotstrings"]["rolls"]["hc"]["enabled"],
			"an explicit roll choice remains active under '" . Emulated . "'")
		AssertFalse(Target["hotstrings"]["sfbs_reduction"]["bu"]["enabled"],
			"changing layout never enables an unselected geometry rule")
		AssertTrue(Target["hotstrings"]["autocorrection"]["accents"]["enabled"])
	}
}

Test("layout preferences: geometry hotstring menus never depend on layout family (layout-ergopti-hotstrings)",
	_LSD_ErgoptiHotstringsWiringCase)

_LSD_ErgoptiHotstringsWiringCase() {
	Gate := _DriverFuncBody("ApplyMasterGatesToFeatures")
	Assert(Gate != "", "the runtime category gate must resolve")
	Assert(InStr(Gate, "_MG_SupersedeErgoptiHotstrings") == 0,
		"a layout choice must never cut off enabled geometry hotstrings")
	Rows := _DriverFuncBody("_HS_BoundCategoryRows")
	Assert(Rows != "", "the Ergopti hotstring menu builder must resolve")
	Assert(InStr(Rows, "LayoutErgoptiHotstringsReason") == 0,
		"geometry hotstrings stay editable under any detected or emulated layout")
	Assert(InStr(Rows, "SubMenus[Category]") > 0,
		"the configurable category submenus remain reachable")
}

Test("layout supersession: MenuRowFromManifest greys and labels a superseded row (layout-supersession-declared)",
	_LSD_MenuWiringCase)

_LSD_MenuWiringCase() {
	Body := _DriverFuncBody("MenuRowFromManifest")
	Assert(Body != "", "MenuRowFromManifest must exist in ui/menu/menu_engine.ahk")
	ReasonPos := InStr(Body, "LayoutSupersededReason(ManifestEntry)")
	Assert(ReasonPos > 0, "MenuRowFromManifest must ask LayoutSupersededReason about its entry")
	Assert(RegExMatch(Body, 's)LayoutSupersededReason\(ManifestEntry\).*Row\["disabled"\] := true'),
		"a superseded row must be disabled")
	Assert(RegExMatch(Body, 's)LayoutSupersededReason\(ManifestEntry\).*Row\["label"\] := .*t\('),
		"a superseded row must carry its translated reason")
}
