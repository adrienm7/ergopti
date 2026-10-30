; tests/meta/corpus/test_corpus_toml_hotstring_reader.ahk

; ==============================================================================
; MODULE: Hotstring TOML Reader Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/toml/hotstring_reader_vectors.json through the two
; Windows readers of a hotstring file: _TomlWarmFileCounts for the sections and
; ParseTomlGroupConfig for the [_meta.sections.<name>] delays.
;
; FEATURES & RATIONALE:
; 1. The Windows readers scan line by line and have no whole-file verdict: there is
;    no source receipt to compare, so a vector the shared reader refuses has no
;    Windows entry. Those are counted, not replayed.
; 2. The corpus writes an entry as { output = "x" }, which is not one of the two
;    entry shapes Windows registers (the full inline table, key = "value"). Output
;    and entry count therefore have no Windows reading, and a section is compared
;    by its presence, lower-cased as the Windows reader keys it.
; 3. Every case agrees or is pinned in _CTHR_PENDING with its reason.
; ==============================================================================

#Requires AutoHotkey v2.0



global _CTHR_VECTOR_COUNT := 55
global _CTHR_NO_VERDICT_COUNT := 18

; None is decided: which rule the drivers share is a maintainer call.
global _CTHR_HEADER_GRAMMAR := "the Windows header pattern (HS_TOML_SECTION_HEADER_PATTERN) excludes brackets in a name and an empty name"
global _CTHR_QUOTE_COMMENT := "TOML_StripInlineComment honours a quote inside a literal group name, so a comment after it stays on the header line and the header is not recognised"
global _CTHR_META_GRAMMAR := "ParseTomlGroupConfig reads bare [_meta.sections.<name>] names only, so a quoted or non-ASCII name has no delay"

global _CTHR_PENDING := Map(
	"historical-literal-name-1-preserved", _CTHR_HEADER_GRAMMAR,
	"historical-literal-name-3-preserved", _CTHR_HEADER_GRAMMAR,
	"historical-literal-name-10-preserved", _CTHR_HEADER_GRAMMAR,
	"historical-literal-name-11-preserved", _CTHR_HEADER_GRAMMAR,
	"exact-literal-name-4-before-a-comment", _CTHR_QUOTE_COMMENT,
	"exact-literal-name-5-before-a-comment", _CTHR_QUOTE_COMMENT,
	"exact-literal-name-6-before-a-comment", _CTHR_QUOTE_COMMENT,
	"exact-literal-name-7-before-a-comment", _CTHR_QUOTE_COMMENT,
	"exact-literal-name-8-before-a-comment", _CTHR_QUOTE_COMMENT,
	"exact-literal-name-9-before-a-comment", _CTHR_QUOTE_COMMENT,
	"accepted-identity-1-never-reinterpreted", _CTHR_QUOTE_COMMENT,
	"accepted-identity-2-never-reinterpreted", _CTHR_QUOTE_COMMENT,
	"quoted-metadata-path-distinct-from-the-literal-rule-name", _CTHR_META_GRAMMAR)

_CTHR_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\toml\hotstring_reader_vectors.json", "UTF-8"))
	return Corpus
}

_CTHR_Difference(Vector) {
	static Sequence := 0
	Sequence += 1
	Expect := Vector["expect"]
	Path := A_Temp . "\ergopti_hotstring_reader_" . DllCall("GetCurrentProcessId", "UInt") . "_" . Sequence . ".toml"
	FileAppend(Vector["text"], Path, "UTF-8-RAW")
	try {
		Counts := _TomlWarmFileCounts(Path)
		if Expect.Has("sections") {
			for Section in Expect["sections"] {
				if !Counts.Has(StrLower(Section["name"]))
					return "the section is missing: " . Section["name"]
			}
		}
		if Expect.Has("meta_delays") {
			Config := ParseTomlGroupConfig("corpus", Path)
			for Meta in Expect["meta_delays"] {
				Name := StrLower(Meta["name"])
				if !Config.Sections.Has(Name) || Config.Sections[Name].Delay != Meta["delay"]
					return "the metadata delay differs for " . Meta["name"]
			}
		}
		return ""
	} finally {
		_ParseTomlGroupConfig_InvalidatePath(Path)
		FileDelete(Path)
	}
}

_CTHR_Replay(Vector) {
	global _CTHR_PENDING
	Difference := _CTHR_Difference(Vector)
	if _CTHR_PENDING.Has(Vector["id"])
		AssertTrue(Difference != "", Vector["id"] . " now agrees: remove it from _CTHR_PENDING")
	else
		AssertEqual("", Difference, Vector["id"])
}

_CTHR_InventoryIsCurrent() {
	global _CTHR_VECTOR_COUNT, _CTHR_NO_VERDICT_COUNT, _CTHR_PENDING
	Vectors := _CTHR_Corpus()["vectors"]
	AssertEqual(_CTHR_VECTOR_COUNT, Vectors.Length, "hotstring_reader_vectors.json changed size")
	Known := Map(), NoVerdict := 0
	for Vector in Vectors {
		Known[Vector["id"]] := true
		NoVerdict += Vector["expect"]["committed"] ? 0 : 1
	}
	AssertEqual(_CTHR_NO_VERDICT_COUNT, NoVerdict, "the vectors without a Windows entry changed")
	for Id, Reason in _CTHR_PENDING {
		AssertTrue(Known.Has(Id), "stale pending entry: " . Id)
		AssertTrue(Reason != "", "a pending entry states its reason: " . Id)
	}
}
Test("toml hotstring reader corpus: the count and the pending inventory are current", _CTHR_InventoryIsCurrent)

_CTHR_Register() {
	for Vector in _CTHR_Corpus()["vectors"]
		if Vector["expect"]["committed"]
			Test("toml hotstring reader corpus: " . Vector["id"], _CTHR_Replay.Bind(Vector))
}
_CTHR_Register()
