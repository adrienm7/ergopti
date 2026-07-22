; tests/unit/test_config_io_feature_section_prefix.ahk

; ==============================================================================
; MODULE: Config I/O ahk.-Prefix Section Resolution Tests
; DESCRIPTION:
; Validates that flattening the ahk.-stripped in-memory Features tree back into
; TOML {section, key, value} writes re-derives the correct ahk.-prefixed section
; per leaf via the manifest (ManifestResolveFeatureSection), instead of reusing
; the already-stripped Features nesting as the section verbatim. Covers both
; call sites that flatten Features: _CollectFeatureUpdates (SaveFullConfig, the
; boot-time full-config flush) and _CollectFeatureFlipUpdates (ToggleAllFeatures,
; the tray menu's "Tout activer"/"Tout desactiver").
;
; ROOT CAUSE:
; ManifestBuildFeaturesMap strips the "ahk." prefix uniformly when building the
; Features tree, so several top-level Features keys (e.g. "shortcuts",
; "metrics", "gestures") merge entries from BOTH a shared (unprefixed) manifest
; section and an ahk.-only one. Before the fix, both walkers reused the
; already-stripped SectionPath verbatim, writing every AHK-only leaf (Layout,
; ahk.shortcuts.* sub-Maps, ahk.gestures.*, ahk.category_enabled.*, ahk.metrics.*)
; to a spurious bare TOML section alongside the correct ahk.-prefixed one.
; TOML_BatchWrite sorts sections alphabetically and ApplyConfigToml applies them
; in file order, so a later stale bare section silently overwrites a
; hand-edited [ahk.*] section back to its old value on the next reload.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================================
; ==============================================================
; ======= 1/ Shared fixture ====================================
; ==============================================================
; ==============================================================

; A Features fixture shaped like the real manifest output: mixes AHK-only
; sub-trees (layout, shortcuts.personal, gestures, category_enabled -- all
; nested under "ahk." in the manifest) with shared, un-prefixed sub-trees
; (shortcuts.microsoft_bold, shortcuts.gpt) inside the SAME top-level
; "shortcuts" key -- exactly the collision that hides the bug from a naive
; per-top-level-key prefix heuristic.
_CFP_Fixture() {
	return Map(
		"layout", Map("ergopti_base", false),
		"gestures", Map("enabled", false, "swipe_3_down", "tab_close"),
		"shortcuts", Map(
			"microsoft_bold", false,
			"gpt", Map("enabled", false, "link", "https://example"),
			"personal", Map("laptop_broken_key", false)
		),
		"category_enabled", Map("hotstrings", false)
	)
}

; Returns true when Updates contains an entry matching Section/Key/Value exactly.
_CFP_HasUpdate(Updates, Section, Key, Value) {
	for U in Updates {
		if (U.Section = Section and U.Key = Key and U.Value = Value)
			return true
	}
	return false
}





; ===============================================================
; ===============================================================
; ======= 2/ _CollectFeatureUpdates (SaveFullConfig path) =======
; ===============================================================
; ===============================================================

_CFP_CollectFeatureUpdates_AhkLeavesPrefixed() {
	ManifestEnsureLoaded()
	Updates := []
	_CollectFeatureUpdates(Updates, "", _CFP_Fixture())

	; AHK-only leaves must land under their real ahk.-prefixed section.
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.layout", "ergopti_base", false),
		"layout.ergopti_base must be written to [ahk.layout], not [layout]")
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.shortcuts.personal", "laptop_broken_key", false),
		"shortcuts.personal.laptop_broken_key must be written to [ahk.shortcuts.personal], not [shortcuts.personal]")
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.category_enabled", "hotstrings", false),
		"category_enabled.hotstrings must be written to [ahk.category_enabled], not [category_enabled]")
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.gestures", "enabled", false),
		"gestures.enabled must be written to [ahk.gestures], not [gestures]")
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.gestures", "swipe_3_down", "tab_close"),
		"gestures.swipe_3_down must be written to [ahk.gestures], not [gestures]")

	; No bare, un-prefixed duplicate of any AHK-only section may be emitted --
	; that duplicate is exactly what lets a later stale write clobber a
	; hand-edited [ahk.*] section back on the next reload.
	AssertFalse(_CFP_HasUpdate(Updates, "layout", "ergopti_base", false),
		"a spurious bare [layout] write must not be emitted")
	AssertFalse(_CFP_HasUpdate(Updates, "shortcuts.personal", "laptop_broken_key", false),
		"a spurious bare [shortcuts.personal] write must not be emitted")
	AssertFalse(_CFP_HasUpdate(Updates, "category_enabled", "hotstrings", false),
		"a spurious bare [category_enabled] write must not be emitted")
	AssertFalse(_CFP_HasUpdate(Updates, "gestures", "enabled", false),
		"a spurious bare [gestures] write must not be emitted")
}
Test("config_io: _CollectFeatureUpdates re-prefixes every AHK-only leaf with ahk. (F5)",
	_CFP_CollectFeatureUpdates_AhkLeavesPrefixed)

_CFP_CollectFeatureUpdates_SharedLeavesStayUnprefixed() {
	; Shared (non-ahk) leaves that merge into the SAME top-level "shortcuts" key
	; must keep their un-prefixed section -- confirms the fix resolves per-leaf
	; via the manifest instead of blanket-prefixing every top-level key.
	ManifestEnsureLoaded()
	Updates := []
	_CollectFeatureUpdates(Updates, "", _CFP_Fixture())

	AssertTrue(_CFP_HasUpdate(Updates, "shortcuts", "microsoft_bold", false),
		"shortcuts.microsoft_bold is a shared feature and must stay at [shortcuts]")
	AssertTrue(_CFP_HasUpdate(Updates, "shortcuts.gpt", "enabled", false),
		"shortcuts.gpt.enabled is a shared alpha feature and must stay at [shortcuts.gpt]")
	AssertTrue(_CFP_HasUpdate(Updates, "shortcuts.gpt", "link", "https://example"),
		"shortcuts.gpt.link is a shared alpha feature and must stay at [shortcuts.gpt]")
}
Test("config_io: _CollectFeatureUpdates leaves shared (non-ahk) sections un-prefixed (F5)",
	_CFP_CollectFeatureUpdates_SharedLeavesStayUnprefixed)





; ==============================================================================
; ==============================================================================
; ======= 3/ _CollectFeatureFlipUpdates (ToggleAllFeatures path, F48) ========
; ==============================================================================
; ==============================================================================

; Mirrors ToggleAllFeatures's own top-level loop, without ever calling
; ToggleAllFeatures itself -- ToggleAllFeatures ends with an unconditional
; Reload(), which would tear down the headless test runner (see
; tests/meta/test_updater_setchannel_cancels_async.ahk for the same
; constraint). _CollectFeatureFlipUpdates is a plain module function (not a
; nested closure), so it is directly reachable here.
_CFP_RunAllFeaturesFlip(Bool, Fixture) {
	Updates := []
	for TopKey, TopVal in Fixture {
		if (Type(TopVal) == "Map")
			_CollectFeatureFlipUpdates(Bool, TopKey, TopVal, Updates)
	}
	return Updates
}

_CFP_ToggleAllFeatures_AhkLeavesPrefixed() {
	ManifestEnsureLoaded()
	Updates := _CFP_RunAllFeaturesFlip(false, _CFP_Fixture())

	AssertTrue(_CFP_HasUpdate(Updates, "ahk.layout", "ergopti_base", false),
		"ToggleAllFeatures must write layout.ergopti_base to [ahk.layout], not [layout]")
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.shortcuts.personal", "laptop_broken_key", false),
		"ToggleAllFeatures must write shortcuts.personal.laptop_broken_key to [ahk.shortcuts.personal]")
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.category_enabled", "hotstrings", false),
		"ToggleAllFeatures must write category_enabled.hotstrings to [ahk.category_enabled]")
	; "gestures" is itself alpha-shaped (carries "enabled" alongside action
	; strings), so the flip walker's alpha branch fires and flips ONLY "enabled".
	AssertTrue(_CFP_HasUpdate(Updates, "ahk.gestures", "enabled", false),
		"ToggleAllFeatures must write gestures.enabled to [ahk.gestures], not [gestures]")

	AssertFalse(_CFP_HasUpdate(Updates, "layout", "ergopti_base", false),
		"ToggleAllFeatures must not emit a spurious bare [layout] write")
	AssertFalse(_CFP_HasUpdate(Updates, "shortcuts.personal", "laptop_broken_key", false),
		"ToggleAllFeatures must not emit a spurious bare [shortcuts.personal] write")
	AssertFalse(_CFP_HasUpdate(Updates, "category_enabled", "hotstrings", false),
		"ToggleAllFeatures must not emit a spurious bare [category_enabled] write")
	AssertFalse(_CFP_HasUpdate(Updates, "gestures", "enabled", false),
		"ToggleAllFeatures must not emit a spurious bare [gestures] write")
}
Test("config_io: ToggleAllFeatures's flip walker re-prefixes every AHK-only leaf with ahk. (F48)",
	_CFP_ToggleAllFeatures_AhkLeavesPrefixed)

_CFP_ToggleAllFeatures_MutatesFixtureInPlace() {
	; The flip walker must still mutate Features nodes in place (the in-memory
	; state the rest of the driver reads) in addition to collecting the writes.
	Fixture := _CFP_Fixture()
	_CFP_RunAllFeaturesFlip(true, Fixture)
	AssertEqual(true, Fixture["layout"]["ergopti_base"])
	AssertEqual(true, Fixture["gestures"]["enabled"])
	AssertEqual(true, Fixture["shortcuts"]["microsoft_bold"])
}
Test("config_io: ToggleAllFeatures's flip walker still mutates Features in place (F48)",
	_CFP_ToggleAllFeatures_MutatesFixtureInPlace)
