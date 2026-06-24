; tests/unit/test_feature_io_locator.ahk

; ==============================================================================
; MODULE: Feature I/O Locator Tests
; DESCRIPTION:
; Validates FeatureLocateV2 (lib/feature_io.ahk) — the v2-native replacement for
; the v1->v2 path translator. Asserts that a canonical v2 manifest path resolves
; to the correct config.toml {section, key} and is_alpha classification purely by
; introspecting a Features fixture, with no PascalCase rename tables. Covers the
; cases the retired translator hand-coded: ahk-prefixed plain (layout), top-level
; Map-with-enabled (gestures), un-prefixed plain (shortcuts bool), alpha toggle +
; alpha property (shortcuts.gpt[.link]), and nested alpha (hotstrings).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================================
; ==============================================================
; ======= 1/ Fixture + resolution assertions ==================
; ==============================================================
; ==============================================================

; Runs Fn with global Features swapped to Fixture, restoring the original after
; so the shared harness state is never polluted.
_FIL_WithFeatures(Fixture, Fn) {
	global Features
	Saved := IsSet(Features) ? Features : ""
	Features := Fixture
	try {
		Fn()
	} finally {
		Features := Saved
	}
}

_FIL_Fixture() {
	return Map(
		"layout",   Map("ergopti_base", false),
		"gestures", Map("enabled", true),
		"shortcuts", Map(
			"microsoft_bold", false,
			"gpt", Map("enabled", false, "link", "https://example")
		),
		"hotstrings", Map(
			"autocorrection", Map("accents", Map("enabled", true))
		)
	)
}

_FIL_AssertLoc(V2Path, ExpSection, ExpKey, ExpAlpha, Prop := "") {
	Loc := FeatureLocateV2(V2Path, Prop)
	AssertTrue(Loc != false, "FeatureLocateV2('" . V2Path . "') must resolve")
	AssertEqual(ExpSection, Loc["section"], "section for '" . V2Path . "'")
	AssertEqual(ExpKey, Loc["key"], "key for '" . V2Path . "'")
	AssertEqual(ExpAlpha, Loc["is_alpha"] ? 1 : 0, "is_alpha for '" . V2Path . "'")
}

_FIL_PlainAhkLayout() {
	_FIL_WithFeatures(_FIL_Fixture(), () =>
		_FIL_AssertLoc("ahk.layout.ergopti_base", "ahk.layout", "ergopti_base", 0))
}
Test("feature_io: ahk-prefixed plain feature -> [ahk.layout] ergopti_base", _FIL_PlainAhkLayout)

_FIL_GesturesMaster() {
	; gestures is a top-level Map carrying "enabled" -> classified alpha, but the
	; resolved {section, key, node} are identical to the translator's, so the
	; write is byte-identical.
	_FIL_WithFeatures(_FIL_Fixture(), () =>
		_FIL_AssertLoc("ahk.gestures.enabled", "ahk.gestures", "enabled", 1))
}
Test("feature_io: gestures master -> [ahk.gestures] enabled", _FIL_GesturesMaster)

_FIL_PlainShortcut() {
	_FIL_WithFeatures(_FIL_Fixture(), () =>
		_FIL_AssertLoc("shortcuts.microsoft_bold", "shortcuts", "microsoft_bold", 0))
}
Test("feature_io: un-prefixed plain bool -> [shortcuts] microsoft_bold", _FIL_PlainShortcut)

_FIL_AlphaToggle() {
	_FIL_WithFeatures(_FIL_Fixture(), () =>
		_FIL_AssertLoc("shortcuts.gpt", "shortcuts.gpt", "enabled", 1))
}
Test("feature_io: alpha feature toggle -> [shortcuts.gpt] enabled", _FIL_AlphaToggle)

_FIL_AlphaPropByPath() {
	_FIL_WithFeatures(_FIL_Fixture(), () =>
		_FIL_AssertLoc("shortcuts.gpt.link", "shortcuts.gpt", "link", 1))
}
Test("feature_io: alpha property via path -> [shortcuts.gpt] link", _FIL_AlphaPropByPath)

_FIL_AlphaPropByArg() {
	; The explicit Prop argument resolves the same alpha property as the dotted path.
	_FIL_WithFeatures(_FIL_Fixture(), () =>
		_FIL_AssertLoc("shortcuts.gpt", "shortcuts.gpt", "link", 1, "link"))
}
Test("feature_io: alpha property via Prop arg -> [shortcuts.gpt] link", _FIL_AlphaPropByArg)

_FIL_NestedAlpha() {
	_FIL_WithFeatures(_FIL_Fixture(), () =>
		_FIL_AssertLoc("hotstrings.autocorrection.accents",
			"hotstrings.autocorrection.accents", "enabled", 1))
}
Test("feature_io: nested alpha -> [hotstrings.autocorrection.accents] enabled", _FIL_NestedAlpha)

_FIL_Unresolved() {
	_FIL_WithFeatures(_FIL_Fixture(), () => (
		AssertEqual(false, FeatureLocateV2("shortcuts.does_not_exist"),
			"unknown path must return false")
	))
}
Test("feature_io: unknown path returns false", _FIL_Unresolved)
