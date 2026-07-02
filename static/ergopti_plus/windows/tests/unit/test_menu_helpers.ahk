; static/ergopti_plus/windows/tests/unit/test_menu_helpers.ahk

; ==============================================================================
; MODULE: Menu Helpers Tests
; DESCRIPTION:
; Pure-helper tests for lib/menu_helpers.ahk's personal-section label
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
