; tests/meta/corpus/test_corpus_hotstring_family_samples.ahk

; ==============================================================================
; MODULE: Shipped Hotstring Family Samples (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/family_samples.json: two or three
; SHIPPED expansions per family of the menu manifest. Each entry is read from
; its shipped file with the pattern and the flags of LoadHotstringsSection,
; registered through HSE_RegisterFromTomlFlags, typed through HSE_FeedChar and
; expanded through HSE_DispatchMatch. A renamed, removed or re-flagged shipped
; entry fails here, as it fails the Lua harnesses (hotstring_family_samples.lua).
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Corpus and manifest =======
; ======================================
; ======================================

; Samples each family needs, as _shared/lua/test/hotstring_family_samples.lua
; requires, so a new family cannot ship without the data pin.
global _CHFS_MIN_SAMPLES_PER_FAMILY := 2

_CHFS_SharedPath(Relative) => A_ScriptDir . "\..\..\_shared\" . Relative

_CHFS_Corpus() {
	static Corpus := JsonParse(FileRead(_CHFS_SharedPath("tests\corpus\hotstrings\family_samples.json"), "UTF-8"))
	return Corpus
}

; One entry of a shipped file, as LoadHotstringsSection matches it.
_CHFS_ShippedEntry(Sample) {
	global _HOTSTRING_ENTRY_PATTERN
	Path := A_ScriptDir . "\..\..\..\" . StrReplace(Sample["file"], "/", "\")
	Section := StrLower(Sample["section"])
	Current := ""
	loop parse, FileRead(Path, "UTF-8"), "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#")
			continue
		if RegExMatch(TOML_StripInlineComment(Line), "^\[+([^\[\]]+)\]+$", &Header) {
			Current := StrLower(Trim(Header[1]))
			continue
		}
		if (Current == Section && RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match)
				&& UnescapeTomlString(Match[1]) == Sample["trigger"])
			return Match
	}
	throw Error(Sample["id"] . ": [[" . Sample["section"] . "]] of " . Sample["file"] . " no longer ships the trigger '" . Sample["trigger"] . "'")
}





; =============================
; =============================
; ======= 2/ The replay =======
; =============================
; =============================

; Registers one shipped entry as the loader does, types the sample and expands it.
_CHFS_ReplaySample(Sample) {
	global ScriptInformation, HSE_LastEndChar, _Stub_RecordedSends
	Match := _CHFS_ShippedEntry(Sample)
	Magic := ScriptInformation["MagicKey"]
	Trigger := StrReplace(UnescapeTomlString(Match[1]), "★", Magic)
	Output := StrReplace(UnescapeTomlString(Match[2]), "★", Magic)
	Flags := (Match[4] == "true" ? "*" : "") . (Match[3] == "true" ? "" : "?") . (Match[7] == "true" ? "C" : "")
	Options := Map("TimeActivationSeconds", 0, "FinalResult", Match[6] == "true",
		"Category", Sample["family"], "Section", Sample["section"], "Priority", 10)
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_RegistryClear()
	HSE_FeedReset(true)
	try {
		HSE_RegisterFromTomlFlags(Match[5] == "true", Flags, Trigger, Output, Options)
		Spec := ""
		for Char in StrSplit(StrReplace(Sample["buffer"], "★", Magic)) {
			Spec := HSE_FeedChar(Char, true)
			if (Spec != "")
				break
		}
		if (Spec == "")
			Spec := HSE_FeedChar(Sample["terminator"], true)
		Expected := Sample["expected"]
		AssertTrue(Expected["matched"] == 1, Sample["id"] . ": every shipped sample expands")
		AssertTrue(Spec != "", Sample["id"] . ": the shipped entry must fire")
		AssertEqual(Expected["backspace_count"], _TextCodepointLength(Spec.Trigger), Sample["id"] . ": the replaced codepoints")
		EndChar := HSE_LastEndChar
		AssertTrue(HSE_DispatchMatch(Spec, EndChar) ? true : false, Sample["id"] . ": the dispatch must commit")
		Sent := ""
		for Call in _Stub_RecordedSends
			Sent .= Call.args[1]
		; Case-sensitive compare: AssertEqual's != ignores case and ADN is the point.
		AssertTrue(InStr(Sent, Expected["replacement"], true) > 0,
			Sample["id"] . ": the keystrokes '" . Sent . "' must type '" . Expected["replacement"] . "'")
	} finally {
		HSE_RegistryClear()
		HSE_FeedReset(true)
	}
}





; ============================
; ============================
; ======= 3/ The tests =======
; ============================
; ============================

_CHFS_EveryFamilyIsSampled() {
	global _CHFS_MIN_SAMPLES_PER_FAMILY
	Manifest := JsonParse(FileRead(_CHFS_SharedPath("modules\menu\menu_manifest.json"), "UTF-8"))
	Families := Manifest["hotstring_category_keys"]
	Corpus := _CHFS_Corpus()
	Excluded := Corpus["excluded_families"]
	Counts := Map()
	for Sample in Corpus["samples"] {
		AssertTrue(Families.Has(Sample["family"]), Sample["id"] . ": no such family in the menu manifest")
		AssertFalse(Excluded.Has(Sample["family"]), Sample["id"] . ": an excluded family cannot be sampled")
		Counts[Sample["family"]] := Counts.Get(Sample["family"], 0) + 1
	}
	AssertTrue(Corpus["samples"].Length > 0, "family_samples.json has no samples")
	for Family in Families {
		if Excluded.Has(Family)
			AssertTrue(Excluded[Family] != "", "the excluded family '" . Family . "' gives no reason")
		else
			AssertTrue(Counts.Get(Family, 0) >= _CHFS_MIN_SAMPLES_PER_FAMILY, "the family '" . Family . "' has too few samples")
	}
}
Test("hotstring family samples: every family of the menu manifest is sampled", _CHFS_EveryFamilyIsSampled)

_CHFS_RegisterSamples() {
	for Sample in _CHFS_Corpus()["samples"]
		Test("hotstring family samples: " . Sample["id"], _CHFS_ReplaySample.Bind(Sample))
}
_CHFS_RegisterSamples()
