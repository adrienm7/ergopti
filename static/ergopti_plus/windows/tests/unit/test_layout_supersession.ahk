; tests/unit/test_layout_supersession.ahk

; ==============================================================================
; MODULE: Layout Features An Emulated Layout Supersedes — Tests
; DESCRIPTION:
; The Ergopti emulation's features (its layers and their overlays: typography,
; selection wrapping, the Ergopti+ changes) and the digit-row swap only apply
; while no registry layout is emulated. The manifest declares them, with the
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
	Assert(Declared.Count >= 4, "at least the four Ergopti emulation features must be declared, got " . Declared.Count)
	for Path in ["layout.ergopti_base", "layout.ergopti_alt_gr", "layout.ergopti_plus", "layout.direct_access_digits"]
		Assert(Declared.Has(Path), Path . " must be declared as superseded by an emulated layout")
	for Path in ["layout.ctrl_magic_save", "layout.emulated_layout"]
		AssertFalse(Declared.Has(Path), Path . " works whatever the layout and must not be declared")
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
	Entry := ManifestFindEntryByPath("layout.ergopti_base")
	Assert(Entry is Map, "layout.ergopti_base must be in the manifest")
	Emulating := Map("layout", Map("emulated_layout", "ergol"))
	NotEmulating := Map("layout", Map("emulated_layout", ""))
	AssertEqual(Entry["superseded_reason_key"], LayoutSupersededReason(Entry, Emulating))
	AssertEqual("", LayoutSupersededReason(Entry, NotEmulating), "no reason without an emulated layout")
	Other := ManifestFindEntryByPath("layout.ctrl_magic_save")
	AssertEqual("", LayoutSupersededReason(Other, Emulating), "a feature that works on any layout keeps its row")
}

Test("layout supersession: the Ergopti hotstrings are off under a layout of another family (layout-ergopti-hotstrings)",
	_LSD_ErgoptiHotstringsCase)

_LSD_ErgoptiHotstringsCase() {
	Families := Map("ergol", "ergol", "ergopti_ansi", "ergopti")
	EntryFn := (Id) => Families.Has(Id) ? Map("id", Id, "family", Families[Id]) : 0
	Make(Emulated) => Map(
		"layout", Map("emulated_layout", Emulated),
		"hotstrings", Map(
			"sfbs_reduction", Map("comma", Map("enabled", true), "bu", Map("enabled", false)),
			"rolls", Map("hc", Map("enabled", true)),
			"autocorrection", Map("accents", Map("enabled", true))))
	Groups := _MG_ErgoptiHotstringGroups()
	AssertEqual("sfbs_reduction,rolls", _LSD_Join(Groups), "the groups come from hotstring_groups.ergopti")

	Target := Make("ergol")
	AssertEqual(2, _MG_SupersedeErgoptiHotstrings(Target, Groups, EntryFn))
	AssertFalse(Target["hotstrings"]["sfbs_reduction"]["comma"]["enabled"])
	AssertFalse(Target["hotstrings"]["rolls"]["hc"]["enabled"])
	AssertTrue(Target["hotstrings"]["autocorrection"]["accents"]["enabled"], "a hotstring of any layout stays on")
	AssertEqual(LAYOUT_ERGOPTI_HOTSTRINGS_REASON, LayoutErgoptiHotstringsReason(Target, EntryFn))
	AssertTrue(t(LAYOUT_ERGOPTI_HOTSTRINGS_REASON) != LAYOUT_ERGOPTI_HOTSTRINGS_REASON, "the reason translates")

	for Emulated in ["ergopti_ansi", ""] {
		Target := Make(Emulated)
		AssertEqual(0, _MG_SupersedeErgoptiHotstrings(Target, Groups, EntryFn), "nothing is off under '" . Emulated . "'")
		AssertTrue(Target["hotstrings"]["sfbs_reduction"]["comma"]["enabled"])
		AssertEqual("", LayoutErgoptiHotstringsReason(Target, EntryFn))
	}
	AssertEqual(LAYOUT_ERGOPTI_HOTSTRINGS_REASON, LayoutErgoptiHotstringsReason(Make("unrecorded"), EntryFn),
		"a layout the record does not vouch for is not an Ergopti layout")
}

_LSD_Join(Items) {
	Out := ""
	for Item in Items
		Out .= (A_Index > 1 ? "," : "") . Item
	return Out
}

Test("layout supersession: the gate and the menu apply the Ergopti hotstrings decision (layout-ergopti-hotstrings)",
	_LSD_ErgoptiHotstringsWiringCase)

_LSD_ErgoptiHotstringsWiringCase() {
	Gate := _DriverFuncBody("ApplyMasterGatesToFeatures")
	Assert(InStr(Gate, "_MG_SupersedeErgoptiHotstrings(FeaturesTarget)"),
		"every path that rebuilds Features must turn the Ergopti hotstrings off")
	Rows := _DriverFuncBody("_HS_CategoryRowsErgopti")
	Assert(Rows != "", "_HS_CategoryRowsErgopti must exist in ui/menu/menu_hotstrings.ahk")
	Assert(RegExMatch(Rows, 's)LayoutErgoptiHotstringsReason\(\).*Row\["disabled"\] := true'),
		"an Ergopti category row must be greyed while its hotstrings are off")
	Assert(RegExMatch(Rows, 's)Row\["label"\] := .*t\(Reason\)'), "the greyed row must say why")
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
