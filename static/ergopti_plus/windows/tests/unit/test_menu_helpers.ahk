; static/ergopti_plus/windows/tests/unit/test_menu_helpers.ahk

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
