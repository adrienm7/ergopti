; tests/meta/corpus/test_corpus_hotstrings_config_resolve.ahk

; ==============================================================================
; MODULE: Hotstrings Config Resolve Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the shared cross-driver corpus from
; _shared/tests/corpus/hotstrings/config_resolve_vectors.json and validates
; the AHK resolution cascade (HotstringsResolve,
; infra/hotstrings/hotstrings_catalogue.ahk) against it — proving
; delay/color/show_tooltip/priority precedence (user_section > user_category >
; toml_section > toml_category) matches the macOS driver bit for bit.
; The base expansion delay and the offsets of it are covered by the second
; corpus, base_delay_vectors.json (section 4 below).
;
; Reuses the _HCfgTestReset / _HCfgTestSeedToml fixture helpers from
; unit/modules/hotstrings/catalogue/test_hotstrings_config.ahk (must load before this file — see run_all.ahk).
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





; ============================================
; ============================================
; ======= 4/ Delay offsets of the base =======
; ============================================
; ============================================

_CorpusBaseDelay_Parse() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\base_delay_vectors.json"
	Assert(FileExist(Path), "the base delay corpus must exist")
	return JsonParse(FileRead(Path, "UTF-8"))
}

; Moves the base the way the setter does, without the config.toml write the
; headless harness has no file for: the leaf in memory, then the overrides with it.
_CorpusBaseDelay_MoveBase(Seconds) {
	global Features
	Previous := HotstringsBaseDelay()
	Features["hotstrings"]["expansion_delay"] := Seconds
	HotstringsOverridesRebase(Previous, Seconds)
}

_CorpusBaseDelay_ReplaysEveryVector() {
	global Features, _HotstringsOverridesPath
	Corpus := _CorpusBaseDelay_Parse()
	AssertTrue(Corpus["vectors"].Length > 0, "the corpus must hold vectors")
	Hotstrings := Features["hotstrings"]
	Had := Hotstrings.Has("expansion_delay")
	Saved := Had ? Hotstrings["expansion_delay"] : 0
	try {
		for Vector in Corpus["vectors"] {
			_HCfgTestReset()
			if Hotstrings.Has("expansion_delay")
				Hotstrings.Delete("expansion_delay")
			for Step in Vector["steps"] {
				Section := Step.Has("section") ? Step["section"] : ""
				switch Step["op"] {
					case "set":
						AssertTrue(HotstringsSetOverride(Step["category"], Section, "delay", Step["delay"]), Vector["id"] . ": set")
					case "clear":
						AssertTrue(HotstringsClearOverride(Step["category"], Section, "delay"), Vector["id"] . ": clear")
					case "base":
						_CorpusBaseDelay_MoveBase(Step["seconds"])
					default:
						Assert(false, Vector["id"] . ": unknown step " . Step["op"])
				}
			}
			for Expected in Vector["expect"] {
				Section := Expected.Has("section") ? Expected["section"] : ""
				AssertEqual(Expected["delay"], HotstringsResolve(Expected["category"], Section).Delay,
					Vector["id"] . ": the effective delay of " . Expected["category"] . "." . Section)
			}
			Stored := FileExist(_HotstringsOverridesPath) ? _ParseOverrides(_HotstringsOverridesPath) : Map()
			for Path, Leaves in Vector["stored"] {
				Parts := StrSplit(Path, ".")
				AssertTrue(Stored.Has(Parts[1]), Vector["id"] . ": the file holds " . Path)
				Record := Parts.Length > 1 ? Stored[Parts[1]].Sections[Parts[2]] : Stored[Parts[1]]
				for Key, Value in Leaves {
					if Key == "delay_offset"
						AssertEqual(Value, Record.PendingOffset, Vector["id"] . ": the stored offset of " . Path)
					else
						AssertEqual(0, Record.Delay, Vector["id"] . ": " . Key . " of " . Path)
				}
			}
			if Vector["stored"].Count == 0 && Stored.Has("rolls")
				AssertEqual("", Stored["rolls"].PendingOffset, Vector["id"] . ": nothing stored")
		}
	} finally {
		if Had
			Hotstrings["expansion_delay"] := Saved
		else if Hotstrings.Has("expansion_delay")
			Hotstrings.Delete("expansion_delay")
		HotstringsResolveBumpGen()
	}
}
Test("hotstrings base delay corpus - every vector resolves and stores as the other drivers do",
	_CorpusBaseDelay_ReplaysEveryVector)
