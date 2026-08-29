; tests/meta/test_corpus_hotstrings_config_resolve.ahk

; ==============================================================================
; MODULE: Hotstrings Config Resolve Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the shared cross-driver corpus from
; _shared/tests/corpus/hotstrings/config_resolve_vectors.json and validates
; the AHK resolution cascade (HotstringsResolve,
; infra/hotstrings/hotstrings_catalogue.ahk) against it — proving
; delay/color/show_tooltip/priority precedence (user_section > user_category >
; toml_section > toml_category) matches the macOS driver bit for bit.
; The AHK-only "_global" menu delay tier remains outside this corpus's scope.
;
; Reuses the _HCfgTestReset / _HCfgTestSeedToml fixture helpers from
; unit/test_hotstrings_config.ahk (must load before this file — see run_all.ahk).
;
; The macOS half lives in
; macos/tests/unit/meta/test_corpus_hotstrings_config_resolve.lua.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus file loading =============
; ============================================
; ============================================

_CorpusHCfg_Parse() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\config_resolve_vectors.json"
	if !FileExist(Path) {
		return ""
	}
	Raw := FileRead(Path, "UTF-8")
	if Raw == "" {
		return ""
	}
	return JsonParse(Raw)
}

; Returns Field from Level (a Map, or "" when the whole level is absent from
; the vector), or "" — the AHK "unset" sentinel throughout the resolve cascade
; — when the level itself or the field within it is missing.
_CorpusHCfg_Get(Level, Field) {
	if !(Level is Map) or !Level.Has(Field)
		return ""
	return Level[Field]
}




; ============================================
; ============================================
; ======= 2/ Corpus integrity =================
; ============================================
; ============================================

_CorpusHCfg_FileIsReadableAndParseable() {
	Corpus := _CorpusHCfg_Parse()
	AssertTrue(Corpus != "", "corpus JSON must be readable and parse without error")
	AssertTrue(Corpus.Has("vectors"), "corpus must have a vectors key")
	AssertTrue(Corpus["vectors"].Length > 0, "corpus must contain at least one vector")
}
Test("hotstrings config resolve corpus — file is readable and parseable", _CorpusHCfg_FileIsReadableAndParseable)




; ============================================
; ============================================
; ======= 3/ HotstringsResolve parity ========
; ============================================
; ============================================

_CorpusHCfg_ResolveMatchesCorpus() {
	global HotstringGroupConfig
	Corpus := _CorpusHCfg_Parse()
	if Corpus == "" {
		Assert(false, "corpus must be parseable")
		return
	}

	Mismatches := ""
	for Vector in Corpus["vectors"] {
		_HCfgTestReset()

		Cat := Vector["category"]
		OverrideCat := Vector.Has("override_category") ? Vector["override_category"] : Cat
		ResolveCat := Vector.Has("resolve_category") ? Vector["resolve_category"] : Cat
		Sec := Vector.Has("section") ? Vector["section"] : ""

		TomlCat := Vector.Has("toml_category") ? Vector["toml_category"] : ""
		TomlSec := Vector.Has("toml_section") ? Vector["toml_section"] : ""

		Sections := Map()
		if (TomlSec != "" and Sec != "") {
			Sections[Sec] := {
				Delay: _CorpusHCfg_Get(TomlSec, "delay"),
				Color: _CorpusHCfg_Get(TomlSec, "color"),
				ShowTooltip: _CorpusHCfg_Get(TomlSec, "show_tooltip"),
				Priority: _CorpusHCfg_Get(TomlSec, "priority")
			}
		}
		_HCfgTestSeedToml(Cat, _CorpusHCfg_Get(TomlCat, "delay"), _CorpusHCfg_Get(TomlCat, "color"), Sections)
		if (TomlCat != "" and TomlCat.Has("show_tooltip"))
			HotstringGroupConfig[Cat].ShowTooltip := TomlCat["show_tooltip"]
		if (TomlCat != "" and TomlCat.Has("priority"))
			HotstringGroupConfig[Cat].Priority := TomlCat["priority"]

		UserCat := Vector.Has("user_category") ? Vector["user_category"] : ""
		if (UserCat != "") {
			for Field in ["delay", "color", "show_tooltip", "priority"]
				if UserCat.Has(Field)
					HotstringsSetOverride(OverrideCat, "", Field, UserCat[Field])
		}
		UserSec := Vector.Has("user_section") ? Vector["user_section"] : ""
		if (UserSec != "") {
			for Field in ["delay", "color", "show_tooltip", "priority"]
				if UserSec.Has(Field)
					HotstringsSetOverride(Cat, Sec, Field, UserSec[Field])
		}

		R := HotstringsResolve(ResolveCat, Sec)
		Expected := Vector["expected"]

		if R.Delay != Expected["delay"]
			Mismatches .= "`n  [" . Vector["id"] . "] delay: got " . R.Delay . ", expected " . Expected["delay"]
		if R.Color != Expected["color"]
			Mismatches .= "`n  [" . Vector["id"] . "] color: got " . R.Color . ", expected " . Expected["color"]
		if (R.ShowTooltip != Expected["show_tooltip"])
			Mismatches .= "`n  [" . Vector["id"] . "] show_tooltip: got " . (R.ShowTooltip ? "true" : "false") . ", expected " . (Expected["show_tooltip"] ? "true" : "false")
		if R.Priority != Expected["priority"]
			Mismatches .= "`n  [" . Vector["id"] . "] priority: got " . R.Priority . ", expected " . Expected["priority"]
		if (R.HasOverride != Expected["has_override"])
			Mismatches .= "`n  [" . Vector["id"] . "] has_override: got " . (R.HasOverride ? "true" : "false") . ", expected " . (Expected["has_override"] ? "true" : "false")
	}

	Assert(Mismatches == "", "HotstringsResolve mismatches against the corpus:" . Mismatches)
}
Test("hotstrings config resolve corpus — HotstringsResolve matches every vector", _CorpusHCfg_ResolveMatchesCorpus)
