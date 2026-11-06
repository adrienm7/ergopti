; static/ergopti_plus/windows/tests/unit/ui/menu/test_menu_helpers.ahk

; ==============================================================================
; MODULE: Menu Helpers Tests
; DESCRIPTION:
; Pure-helper tests for infra/menu_helpers.ahk's personal-section label
; disambiguation (duplicate-personal-section-desc-menu-mistarget).
; ==============================================================================




_MH_Fixture(DescA, DescB, DescC := "") {
	Sections := Map(
		"alpha", Map("description", DescA, "entries", []),
		"beta",  Map("description", DescB, "entries", []),
	)
	Order := ["alpha", "beta"]
	if (DescC != "") {
		Sections["gamma"] := Map("description", DescC, "entries", [])
		Order.Push("gamma")
	}
	return Map("sections_order", Order, "sections", Sections)
}

TestMH_UniqueDescriptionsUnchanged() {
	Data := _MH_Fixture("Voyage", "Travail")
	Labels := _HS_BuildDisambiguatedSectionLabels(Data)
	AssertEqual("Voyage", Labels["alpha"])
	AssertEqual("Travail", Labels["beta"])
}
Test("menu_helpers: unique descriptions pass through unchanged (duplicate-personal-section-desc-menu-mistarget)",
	TestMH_UniqueDescriptionsUnchanged)

TestMH_DuplicateDescriptionsDisambiguated() {
	Data := _MH_Fixture("Voyage", "Voyage")
	Labels := _HS_BuildDisambiguatedSectionLabels(Data)
	AssertEqual("Voyage", Labels["alpha"], "the first occurrence keeps the bare description")
	AssertEqual("Voyage #2", Labels["beta"], "the second occurrence gets a disambiguating suffix")
	AssertTrue(Labels["alpha"] != Labels["beta"],
		"disambiguated labels must be unique so Menu.Check/Uncheck cannot mistarget the wrong section")
}
Test("menu_helpers: duplicate descriptions get a unique numeric suffix (duplicate-personal-section-desc-menu-mistarget)",
	TestMH_DuplicateDescriptionsDisambiguated)

TestMH_TripleDuplicateDescriptions() {
	Data := _MH_Fixture("Voyage", "Voyage", "Voyage")
	Labels := _HS_BuildDisambiguatedSectionLabels(Data)
	AssertEqual("Voyage", Labels["alpha"])
	AssertEqual("Voyage #2", Labels["beta"])
	AssertEqual("Voyage #3", Labels["gamma"])
}
Test("menu_helpers: three-way duplicate descriptions each get a distinct suffix (duplicate-personal-section-desc-menu-mistarget)",
	TestMH_TripleDuplicateDescriptions)

TestMH_SeparatorSkipped() {
	Data := Map("sections_order", ["alpha", "-", "beta"], "sections", Map(
		"alpha", Map("description", "Voyage", "entries", []),
		"beta",  Map("description", "Voyage", "entries", []),
	))
	Labels := _HS_BuildDisambiguatedSectionLabels(Data)
	AssertEqual("Voyage", Labels["alpha"])
	AssertEqual("Voyage #2", Labels["beta"], "the '-' separator entry must not consume a disambiguation slot")
}
Test("menu_helpers: '-' separator entries do not affect disambiguation counting (duplicate-personal-section-desc-menu-mistarget)",
	TestMH_SeparatorSkipped)


; Shared boundaries retain the existing native source order and fail closed.
_MH_SharedSectionBoundary() {
	Row := _HS_DeclaredSectionBoundary()
	AssertTrue(Row is Map, "the actual shared boundary renders provider data")
	AssertTrue(Row.Get("separator", false), "the original boundary remains a separator")
	AssertFalse(Row.Has("action"), "a boundary has no click command")
	AssertFalse(Row.Has("submenu"), "a boundary has no borrowed child")
}
Test("menu_helpers: hotstring sections consume the shared inert boundary", _MH_SharedSectionBoundary)

_MH_WithdrawnSectionBoundary() {
	Root := _MR_GetManifestRoot()
	AssertTrue(Root is Map, "the actual menu root must load")
	AssertTrue(Root.Has("hotstrings_parameter_boundary"), "the existing declaration must be present")
	Saved := Root["hotstrings_parameter_boundary"]
	try {
		Root.Delete("hotstrings_parameter_boundary")
		AssertThrows(_HS_DeclaredSectionBoundary, "withdrawn boundary must refuse detached construction")
	} finally {
		Root["hotstrings_parameter_boundary"] := Saved
	}
	AssertTrue(_HS_DeclaredSectionBoundary().Get("separator", false), "restoring the genuine declaration restores construction")
}
Test("menu_helpers: a withdrawn shared section boundary refuses construction", _MH_WithdrawnSectionBoundary)

_MH_MalformedSectionBoundary() {
	Root := _MR_GetManifestRoot()
	AssertTrue(Root is Map, "the actual menu root must load")
	AssertTrue(Root.Has("hotstrings_parameter_boundary"), "the existing declaration must be present")
	Saved := Root["hotstrings_parameter_boundary"]
	try {
		Root["hotstrings_parameter_boundary"] := []
		AssertThrows(_HS_DeclaredSectionBoundary, "an empty boundary must refuse construction")
		Root["hotstrings_parameter_boundary"] := [Map("type", "---"), Map("type", "---")]
		AssertThrows(_HS_DeclaredSectionBoundary, "duplicate boundaries must refuse construction")
	} finally {
		Root["hotstrings_parameter_boundary"] := Saved
	}
	AssertTrue(_HS_DeclaredSectionBoundary().Get("separator", false), "a refused proposal cannot retire the genuine declaration")
}
Test("menu_helpers: empty and duplicated shared boundaries refuse construction", _MH_MalformedSectionBoundary)

; Free-text section descriptions can already contain the generated suffix.
; The actual helper and native RegisterMenuItem path must preserve each choice.
_MH_NativeSuffixCollision(Order) {
	Descriptions := Order == "generated-first" ? ["LPUL section", "LPUL section", "LPUL section #2"]
		: Order == "literal-first" ? ["LPUL section #2", "LPUL section", "LPUL section"]
		: Order == "case-generated-first" ? ["LPUL section", "lpul section", "LPUL SECTION #2"]
		: ["LPUL SECTION #2", "LPUL section", "lpul section"]
	Model := _MH_Fixture(Descriptions[1], Descriptions[2], Descriptions[3])
	Labels := _HS_BuildDisambiguatedSectionLabels(Model)
	MenuOwner := Menu(), Count := -1, Receipts := []
	try {
		for Key in ["alpha", "beta", "gamma"] {
			Callback := ((Value, *) => Value).Bind(Key)
			Receipts.Push(RegisterMenuItem(MenuOwner, Labels[Key], Callback))
		}
		Count := DllCall("GetMenuItemCount", "ptr", MenuOwner.Handle, "int")
		_TestPrint("# personal-suffix order=" . Order . " labels=" . Labels["alpha"] . "|" . Labels["beta"]
			. "|" . Labels["gamma"] . " native=" . Count)
		for Receipt in Receipts
			AssertEqual(1, Receipt, "Each actual personal section row must be admitted by the native dispatcher")
		AssertTrue(Labels["alpha"] != Labels["beta"] && Labels["alpha"] != Labels["gamma"]
			&& Labels["beta"] != Labels["gamma"], "Each real section description must receive a unique label")
		AssertEqual(3, Count, "The real native menu must retain all three personal section choices")
	} finally _CTC_ReleaseMenu(MenuOwner)
}
for _MH_SuffixOrder in ["generated-first", "literal-first", "case-generated-first", "case-literal-first"]
	Test("menu_helpers: " . _MH_SuffixOrder . " preserves literal personal section suffixes (personal-suffix-menu-owner)",
		_MH_NativeSuffixCollision.Bind(_MH_SuffixOrder))

; Observe actual Win32/AHK Menu.Add equality without presuming case semantics.
_MH_NativeCaseReceipt() {
	MenuOwner := Menu()
	try {
		First := RegisterMenuItem(MenuOwner, "LPUL Case", (*) => 1)
		Second := RegisterMenuItem(MenuOwner, "lpul case", (*) => 2)
		Count := DllCall("GetMenuItemCount", "ptr", MenuOwner.Handle, "int")
		_TestPrint("# menu-native-case first=" . First . " second=" . Second . " native_count=" . Count)
		AssertTrue(Count == 1 || Count == 2, "The isolated actual Menu must settle to an observable count")
	} finally _CTC_ReleaseMenu(MenuOwner)
}
Test("menu_helpers: native case comparison is observed on an owned menu (menu-native-case-receipt)", _MH_NativeCaseReceipt)
