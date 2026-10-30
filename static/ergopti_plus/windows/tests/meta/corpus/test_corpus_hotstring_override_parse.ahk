; tests/meta/corpus/test_corpus_hotstring_override_parse.ahk

; ==============================================================================
; MODULE: Hotstring Override Parser Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/override_parse_vectors.json through
; the production _ParseOverrides, from the exact bytes of a file on disk.
;
; FEATURES & RATIONALE:
; 1. Windows names tables by the lowercase_bare policy of the shared parser
;    (hotstrings/overrides.lua): every vector of that policy is replayed. A
;    verbatim vector is replayed only for its verdict that the bytes are invalid,
;    which holds under every policy; the trees of that policy are Linux's.
; 2. The record of a table (Delay, PendingOffset, LegacyDelay...) is spelled as
;    the shared tree does, so the two compare as one text.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Corpus and spelling =======
; ======================================
; ======================================

_COP_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\override_parse_vectors.json", "UTF-8"))
	return Corpus
}

; The canonical spelling of one number, whatever its AHK type.
_COP_Number(Value) => Format("{:g}", Value)

; The leaves of one table of the expected tree, sorted.
_COP_ExpectedLeaves(Table) {
	Parts := ""
	for Name in ["color", "delay_offset", "delay_unlimited", "legacy_delay", "priority", "show_tooltip"] {
		if !Table.Has(Name)
			continue
		Value := Table[Name]
		Parts .= Name . "=" . ((Name == "color") ? Value : _COP_Number(Value)) . ";"
	}
	return Parts
}

; The leaves of one parsed override record, in the same spelling.
_COP_ParsedLeaves(Record) {
	Parts := ""
	if (Record.Color != "")
		Parts .= "color=" . Record.Color . ";"
	if (Record.PendingOffset != "")
		Parts .= "delay_offset=" . _COP_Number(Record.PendingOffset) . ";"
	if (Record.Delay != "") {
		AssertEqual(0, Record.Delay, "the parser's only direct delay is the unlimited one")
		Parts .= "delay_unlimited=1;"
	}
	if (Record.LegacyDelay != "")
		Parts .= "legacy_delay=" . _COP_Number(Record.LegacyDelay) . ";"
	if (Record.Priority != "")
		Parts .= "priority=" . _COP_Number(Record.Priority) . ";"
	if (Record.ShowTooltip != "")
		Parts .= "show_tooltip=" . _COP_Number(Record.ShowTooltip) . ";"
	return Parts
}

_COP_SpellExpected(Tree) {
	Lines := ""
	for Category, Table in Tree {
		Lines .= Category . ":" . _COP_ExpectedLeaves(Table) . "`n"
		for Section, Leaves in Table["sections"]
			Lines .= Category . "." . Section . ":" . _COP_ExpectedLeaves(Leaves) . "`n"
	}
	return Lines == "" ? "" : Sort(Lines)
}

_COP_SpellParsed(Tree) {
	Lines := ""
	for Category, Record in Tree {
		Lines .= Category . ":" . _COP_ParsedLeaves(Record) . "`n"
		for Section, Leaves in Record.Sections
			Lines .= Category . "." . Section . ":" . _COP_ParsedLeaves(Leaves) . "`n"
	}
	return Lines == "" ? "" : Sort(Lines)
}





; ===================================
; ===================================
; ======= 2/ Replay and tests =======
; ===================================
; ===================================

_COP_ParseBytes(Content) {
	Path := A_Temp . "\ergopti_override_vector_" . ProcessExist() . "_" . A_TickCount . "_" . Random(1000, 999999) . ".toml"
	FileAppend(Content, Path, "UTF-8-RAW")
	try return _ParseOverrides(Path)
	finally FileDelete(Path)
}

_COP_ReplayVector(Vector) {
	if (Vector.Has("error") && Vector["error"]) {
		Refused := ""
		try _COP_ParseBytes(Vector["content"])
		catch ValueError as Err
			Refused := Err.Message
		AssertTrue(Refused != "", Vector["name"] . ": invalid TOML must raise")
		return
	}
	AssertEqual(_COP_SpellExpected(Vector["expect"]), _COP_SpellParsed(_COP_ParseBytes(Vector["content"])), Vector["name"])
}

_COP_ReplaysThePolicyOfThisDriver() {
	Replayed := 0
	for Vector in _COP_Corpus()["vectors"] {
		if (Vector["policy"] == "lowercase_bare" || (Vector.Has("error") && Vector["error"]))
			Replayed += 1
	}
	AssertEqual(13, Replayed, "override_parse_vectors.json changed: review what Windows replays")
}
Test("hotstring override corpus: replays every vector of its policy and every invalid file", _COP_ReplaysThePolicyOfThisDriver)

_COP_RegisterVectors() {
	for Vector in _COP_Corpus()["vectors"] {
		if (Vector["policy"] == "lowercase_bare" || (Vector.Has("error") && Vector["error"]))
			Test("hotstring override corpus: " . Vector["name"], _COP_ReplayVector.Bind(Vector))
	}
}
_COP_RegisterVectors()
