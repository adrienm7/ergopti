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
; so the shared harness state is never polluted. Still needed by Section 3 below,
; which exercises EnsurePersonalHotstringFeature (a real global-Features mutator)
; through the public WriteFeatureV2 wrapper.
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

; Calls FeatureLocateV2 directly against Fixture -- no global Features swap
; needed since it takes its target Map as an explicit parameter
; (feedback_loader_target_explicit).
_FIL_AssertLoc(Fixture, V2Path, ExpSection, ExpKey, ExpAlpha, Prop := "") {
	Loc := FeatureLocateV2(Fixture, V2Path, Prop)
	AssertTrue(Loc != false, "FeatureLocateV2('" . V2Path . "') must resolve")
	AssertEqual(ExpSection, Loc["section"], "section for '" . V2Path . "'")
	AssertEqual(ExpKey, Loc["key"], "key for '" . V2Path . "'")
	AssertEqual(ExpAlpha, Loc["is_alpha"] ? 1 : 0, "is_alpha for '" . V2Path . "'")
}

_FIL_PlainAhkLayout() {
	_FIL_AssertLoc(_FIL_Fixture(), "ahk.layout.ergopti_base", "ahk.layout", "ergopti_base", 0)
}
Test("feature_io: ahk-prefixed plain feature -> [ahk.layout] ergopti_base", _FIL_PlainAhkLayout)

_FIL_GesturesMaster() {
	; gestures is a top-level Map carrying "enabled" -> classified alpha, but the
	; resolved {section, key, node} are identical to the translator's, so the
	; write is byte-identical.
	_FIL_AssertLoc(_FIL_Fixture(), "ahk.gestures.enabled", "ahk.gestures", "enabled", 1)
}
Test("feature_io: gestures master -> [ahk.gestures] enabled", _FIL_GesturesMaster)

_FIL_PlainShortcut() {
	_FIL_AssertLoc(_FIL_Fixture(), "shortcuts.microsoft_bold", "shortcuts", "microsoft_bold", 0)
}
Test("feature_io: un-prefixed plain bool -> [shortcuts] microsoft_bold", _FIL_PlainShortcut)

_FIL_AlphaToggle() {
	_FIL_AssertLoc(_FIL_Fixture(), "shortcuts.gpt", "shortcuts.gpt", "enabled", 1)
}
Test("feature_io: alpha feature toggle -> [shortcuts.gpt] enabled", _FIL_AlphaToggle)

_FIL_AlphaPropByPath() {
	_FIL_AssertLoc(_FIL_Fixture(), "shortcuts.gpt.link", "shortcuts.gpt", "link", 1)
}
Test("feature_io: alpha property via path -> [shortcuts.gpt] link", _FIL_AlphaPropByPath)

_FIL_AlphaPropByArg() {
	; The explicit Prop argument resolves the same alpha property as the dotted path.
	_FIL_AssertLoc(_FIL_Fixture(), "shortcuts.gpt", "shortcuts.gpt", "link", 1, "link")
}
Test("feature_io: alpha property via Prop arg -> [shortcuts.gpt] link", _FIL_AlphaPropByArg)

_FIL_NestedAlpha() {
	_FIL_AssertLoc(_FIL_Fixture(), "hotstrings.autocorrection.accents",
		"hotstrings.autocorrection.accents", "enabled", 1)
}
Test("feature_io: nested alpha -> [hotstrings.autocorrection.accents] enabled", _FIL_NestedAlpha)

_FIL_Unresolved() {
	AssertEqual(false, FeatureLocateV2(_FIL_Fixture(), "shortcuts.does_not_exist"),
		"unknown path must return false")
}
Test("feature_io: unknown path returns false", _FIL_Unresolved)




; =================================================================
; =================================================================
; ======= 2/ Mutex sibling enumeration (real manifest) ============
; =================================================================
; =================================================================

; The mutex enumerator reads the live manifest (not the Features fixture), so it
; certifies that enabling one modifier-combo key forces exactly the other keys
; of its [ahk.shortcuts.<group>] section off — the v2-native equivalent of the
; retired translator's hand-written sibling table.

_FIL_MutexEnumeratesGroupSiblings() {
	ManifestEnsureLoaded()
	Siblings := _MutexSiblingPathsForV2("ahk.shortcuts.alt_gr_lalt.backspace")
	; The alt_gr_lalt group declares 10 keys; enabling one leaves 9 siblings.
	AssertEqual(9, Siblings.Length, "alt_gr_lalt has 9 siblings of backspace")
	for _, P in Siblings {
		AssertTrue(SubStr(P, 1, 25) == "ahk.shortcuts.alt_gr_lalt", "sibling stays in the group: " . P)
		AssertTrue(P != "ahk.shortcuts.alt_gr_lalt.backspace", "the toggled key is excluded")
	}
}
Test("feature_io: mutex enumerator returns the group's other keys", _FIL_MutexEnumeratesGroupSiblings)

_FIL_MutexStripsAhkPrefix() {
	ManifestEnsureLoaded()
	; The bare (ahk-stripped) shape must resolve to the same group + sibling count.
	Siblings := _MutexSiblingPathsForV2("shortcuts.alt_gr_caps_lock.tab")
	AssertEqual(9, Siblings.Length, "alt_gr_caps_lock has 9 siblings of tab (bare prefix)")
}
Test("feature_io: mutex enumerator strips the ahk. prefix", _FIL_MutexStripsAhkPrefix)

_FIL_MutexEmptyForPlain() {
	ManifestEnsureLoaded()
	; A plain (non-mutex) shortcut toggle has no siblings.
	AssertEqual(0, _MutexSiblingPathsForV2("shortcuts.microsoft_bold").Length,
		"plain shortcut has no mutex siblings")
	AssertEqual(0, _MutexSiblingPathsForV2("ahk.layout.ergopti_base").Length,
		"layout feature has no mutex siblings")
}
Test("feature_io: mutex enumerator empty for non-mutex paths", _FIL_MutexEmptyForPlain)




; =================================================================
; =================================================================
; ======= 3/ Personal-hotstring section seeding (F4) ==============
; =================================================================
; =================================================================

; Regression for personal-hotstring-live-toggle-seed: WriteFeatureV2 must fail
; fast (return false, and log) for an unseeded personal section, and succeed
; once EnsurePersonalHotstringFeature has seeded the Features node — exactly
; what the editor's _NewSection fix now does before the tray menu can ever
; reach the section's toggle.
_FIL_PersonalSectionUnseededFailsBody() {
	global Features
	AssertEqual(false, WriteFeatureV2(Features, "hotstrings.personal.voyage", true),
		"WriteFeatureV2 must fail (not silently mutate nothing) when the section was never seeded")
}
_FIL_PersonalSectionUnseededFails() {
	_FIL_WithFeatures(Map("hotstrings", Map()), _FIL_PersonalSectionUnseededFailsBody)
}
Test("feature_io: WriteFeatureV2 fails for an unseeded personal section (personal-hotstring-live-toggle-seed)",
	_FIL_PersonalSectionUnseededFails)

_FIL_PersonalSectionSeededSucceedsBody() {
	global Features
	EnsurePersonalHotstringFeature("voyage")
	AssertTrue(WriteFeatureV2(Features, "hotstrings.personal.voyage", true),
		"WriteFeatureV2 must succeed once EnsurePersonalHotstringFeature has seeded the section")
}
_FIL_PersonalSectionSeededSucceeds() {
	_FIL_WithFeatures(Map("hotstrings", Map()), _FIL_PersonalSectionSeededSucceedsBody)
}
Test("feature_io: WriteFeatureV2 succeeds after EnsurePersonalHotstringFeature seeds the section (personal-hotstring-live-toggle-seed)",
	_FIL_PersonalSectionSeededSucceeds)

_FIL_FailedPersistenceDoesNotPublishLiveState() {
	global ConfigurationFile
	OriginalPath := ConfigurationFile
	FeatureCandidate := Map("layout", Map("ergopti_base", false))
	; The parent is deliberately absent: TOML_BatchWrite must fail before its
	; atomic FileMove, and the live candidate must remain untouched.
	ConfigurationFile := A_Temp . "\ergopti_missing_parent_" . A_TickCount . "\config.toml"
	try {
		AssertFalse(WriteFeatureV2(FeatureCandidate, "layout.ergopti_base", true),
			"a failed durable write must report failure")
		AssertFalse(FeatureCandidate["layout"]["ergopti_base"],
			"a failed durable write must not publish the live feature mutation")
	} finally {
		ConfigurationFile := OriginalPath
	}
}
Test("feature_io: failed persistence does not publish a live feature mutation", _FIL_FailedPersistenceDoesNotPublishLiveState)
