; static/ergopti_plus/windows/tests/unit/test_hotstring_language_packs.ahk

; ============================================================================
; MODULE: Hotstring Language Pack Tests
; DESCRIPTION:
; French hotstrings moved out of the neutral packs into
; _shared/modules/hotstrings/french/<stem>.toml and load as the group
; "french_<stem>". Every consumer builds that file path, and every one of them
; used to concatenate "<category>.toml" at the root — so a helper that missed the
; language folder would make the cache, the counters and the menu read a file
; that does not exist, and the French sections would silently register nothing.
; These tests pin the one resolver, the gates the menu needs, and the opt-in
; contract: every bundled hotstring section ships disabled.
; ============================================================================

_HLP_FrenchPack() {
	for _, Pack in HotstringsLanguagePacks() {
		if (Pack["id"] == "french")
			return Pack
	}
	return ""
}

_HLP_IndexDeclaresFrench() {
	Pack := _HLP_FrenchPack()
	Assert(Pack is Map, "the shared index must declare the French language pack")
	AssertEqual("fr", Pack["locale"])
	AssertEqual(3, Pack["categories"].Length, "French ships three category files")
	AssertEqual("Français", HotstringsLanguageName(Pack["locale"]),
		"the submenu is labelled with the locale's native name")
}
Test("hotstring languages: the shared index declares French (hs-language-packs)", _HLP_IndexDeclaresFrench)

_HLP_PathResolvesLanguageFolder() {
	for _, Spelling in ["french_autocorrection", "FrenchAutocorrection"] {
		Path := HotstringsBundledTomlPath(Spelling)
		AssertTrue(SubStr(Path, -StrLen("\french\autocorrection.toml")) == "\french\autocorrection.toml",
			"'" . Spelling . "' must resolve inside the language folder, got " . Path)
		AssertTrue(FileExist(Path) != "", "the French autocorrection pack must exist at " . Path)
	}
	Neutral := HotstringsBundledTomlPath("autocorrection")
	AssertTrue(SubStr(Neutral, -StrLen("\hotstrings\autocorrection.toml")) == "\hotstrings\autocorrection.toml",
		"a neutral category stays at the root")
}
Test("hotstring languages: one resolver finds every spelling of a language file (hs-language-packs)", _HLP_PathResolvesLanguageFolder)

_HLP_CacheCoversLanguageGroups() {
	All := HotstringsBundledCategories()
	Found := Map()
	for _, Cat in All
		Found[Cat] := true
	for _, Group in ["french_autocorrection", "french_distancesreduction", "french_magickey", "autocorrection"]
		AssertTrue(Found.Has(Group), "the bundled cache must cover " . Group)
	AssertTrue(HotstringsIsLanguageGroup("french_magickey"))
	AssertFalse(HotstringsIsLanguageGroup("magickey"))
}
Test("hotstring languages: the cache and catalogue cover every language group (hs-language-packs)", _HLP_CacheCoversLanguageGroups)

_HLP_GatesAreSeededAndKeyed() {
	Gates := Map("Hotstrings", true)
	HotstringsSeedLanguageCategoryGates(Gates)
	AssertTrue(Gates.Has("FrenchAutocorrection"), "each language category owns a gate")
	AssertEqual(true, Gates["FrenchAutocorrection"], "gates default open; sections carry the opt-in")
	AssertEqual("french_autocorrection", _CategoryEnabledKey("FrenchAutocorrection"),
		"the gate persists under the group id config.toml uses")
}
Test("hotstring languages: language gates are seeded and persist under their group id (hs-language-packs)", _HLP_GatesAreSeededAndKeyed)

_HLP_EverySectionShipsDisabled() {
	Built := ManifestBuildFeaturesMap()
	Checked := 0
	for Category, Sections in Built["hotstrings"] {
		if !(Sections is Map) or Category == "personal"
			continue
		for Id, Node in Sections {
			if !(Node is Map) or !Node.Has("enabled")
				continue
			; The J→★ key remap sits under magic_key but is a key assignment.
			if (Category == "magic_key" and Id == "replace")
				continue
			AssertEqual(false, Node["enabled"], "hotstrings." . Category . "." . Id . " must ship disabled")
			Checked++
		}
	}
	AssertTrue(Built["hotstrings"].Has("french_autocorrection")
		and Built["hotstrings"]["french_autocorrection"].Has("accents"),
		"the French sections must be manifest features under their language group")
	AssertTrue(Checked > 50, "the opt-in contract must be checked over the whole corpus")
}
Test("hotstring languages: every bundled hotstring section ships disabled (hs-language-packs)", _HLP_EverySectionShipsDisabled)
