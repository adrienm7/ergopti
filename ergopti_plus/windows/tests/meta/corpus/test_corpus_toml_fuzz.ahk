; static/ergopti_plus/windows/tests/meta/corpus/test_corpus_toml_fuzz.ahk

; ==============================================================================
; MODULE: TOML Fuzz Corpus Consumer (AHK)
; DESCRIPTION:
; Replays every entry of the shared cross-driver fuzz corpus
; (_shared/tests/corpus/toml/fuzz_corpus.json) through both Windows TOML
; readers and compares each result with an expectation written here by hand.
;
; WHY SEMANTIC ORACLES:
; The first version of this consumer only asserted that ParseTomlFile did not
; raise. The flat reader skips every root-level key, so 47 of the 50 vectors
; parsed to an empty Map whatever the parser did with them: a reader that
; decoded "true" as false, kept a trailing comment in a value or dropped an
; escape still passed. Each vector now has four independent observations:
;   1. the semantic reader TOML_ParseDocument: exact value tree or the exact
;      rejection class (ValueError plus the refusal's message);
;   2. ParseTomlFile on the vector as written (root keys stay ignored);
;   3. ParseTomlFile and its typed twin on the vector under a [fuzz] header, so
;      every root assignment reaches value coercion;
;   4. round-trip stability: the sectioned result rendered by the canonical
;      writers (TOML_RenderKey, TOML_RenderValue) re-parses to the same value
;      and is accepted by the semantic reader.
; A mutation control then replays the corpus through deliberately broken
; readers (flipped Booleans, integers as text, dropped escapes, untrimmed
; values, swallowed rejections) and requires every one to fail.
;
; INDEPENDENCE:
; The expectations below are written from the TOML 1.0 specification and the
; documented legacy contract of each reader, never computed by a production
; helper. Where a reader deliberately or knowingly departs from TOML 1.0, the
; oracle states the departure in its note; the corpus-consistency test then
; requires that note for every vector whose corpus "expect" the semantic
; reader does not honour, so a silent change in either direction fails.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 1/ Canonical value encoder =======
; ==========================================
; ==========================================

; One deterministic text form for every reader result. Types stay visible
; (i: integer, f: float, s: string, b: TOML Boolean) so a string "1", an
; integer 1 and a Boolean true can never compare equal by AHK coercion.
; @param Value {Any} A reader result or a nested member of one.
; @return {String} The canonical encoding.
_TomlFuzz_Canon(Value) {
	if Value is TOML_Bool
		return "b:" . (Value.Value ? "true" : "false")
	if Value is Map {
		Keys := []
		for Key in Value
			Keys.Push(Key)
		Text := "{"
		for Index, Key in _TomlFuzz_SortedStrings(Keys)
			Text .= (Index > 1 ? "," : "") . _TomlFuzz_Quote(Key) . ":" . _TomlFuzz_Canon(Value[Key])
		return Text . "}"
	}
	if Value is Array {
		Text := "["
		for Index, Item in Value
			Text .= (Index > 1 ? "," : "") . _TomlFuzz_Canon(Item)
		return Text . "]"
	}
	if Value is Integer
		return "i:" . Value
	if Value is Float
		return "f:" . Value
	if Value is String
		return "s:" . _TomlFuzz_Quote(Value)
	throw TypeError("TOML fuzz canonical form has no encoding for " . Type(Value))
}

; Ordinal key order, so the encoding never depends on a Map's enumeration.
_TomlFuzz_SortedStrings(Keys) {
	Sorted := Keys.Clone()
	loop Sorted.Length - 1 {
		Outer := A_Index
		loop Sorted.Length - Outer {
			Index := A_Index
			if StrCompare(Sorted[Index], Sorted[Index + 1], true) > 0 {
				Swap := Sorted[Index]
				Sorted[Index] := Sorted[Index + 1]
				Sorted[Index + 1] := Swap
			}
		}
	}
	return Sorted
}

; Quotes a string with every control character, quote, backslash and "<"
; spelled as <hh> (two lowercase hex digits), so an expectation can name
; invisible characters exactly and the encoding stays injective.
_TomlFuzz_Quote(Text) {
	Out := ""
	Loop Parse String(Text) {
		Code := Ord(A_LoopField)
		Out .= (Code < 0x20 || Code == 0x22 || Code == 0x3C || Code == 0x5C)
			? Format("<{:02x}>", Code) : A_LoopField
	}
	return '"' . Out . '"'
}

; The public reader returns native AHK Booleans (integer 1/0) where the typed
; readers keep TOML_Bool; derive that projection from the same expectation.
_TomlFuzz_NativeBooleans(Canonical) {
	return StrReplace(StrReplace(Canonical, "b:true", "i:1"), "b:false", "i:0")
}





; ===================================
; ===================================
; ======= 2/ Expected results =======
; ===================================
; ===================================

; Builds one oracle entry.
; @param Doc {String} TOML_ParseDocument(input): canonical tree or "reject:<message>".
; @param Flat {String} ParseTomlFile(input), root keys ignored by contract.
; @param Sectioned {String} ParseTomlFile("[fuzz]" LF input): tree or "reject:<message>".
; @param Note {String} The departure from TOML 1.0, empty when there is none.
_TomlFuzz_Oracle(Doc, Flat, Sectioned, Note := "") {
	return Map("doc", Doc, "flat", Flat, "sectioned", Sectioned, "note", Note)
}

; Hand-written expectation for every corpus vector, keyed by vector id.
; @param LongKey {String} The 1000-character key of FUZZ-011, rebuilt by the caller.
; @return {Map} Vector id -> oracle entry.
_TomlFuzz_Oracles(LongKey) {
	O := _TomlFuzz_Oracle
	Empty := "{}", FuzzOnly := '{"fuzz":{}}'
	Legacy := "legacy scalar contract keeps this TOML literal as raw text"
	FlatMultiline := "the flat reader has no multi-line strings: the value keeps only its quote and the body lines are dropped"
	FlatThrows := "the flat reader raises here although its contract says it never raises"
	return Map(
		"FUZZ-001", O(Empty, Empty, FuzzOnly),
		"FUZZ-002", O(Empty, Empty, FuzzOnly),
		"FUZZ-003", O('{"key":s:"value"}', Empty, '{"fuzz":{"key":s:"value"}}'),
		"FUZZ-004", O('{"count":i:42}', Empty, '{"fuzz":{"count":i:42}}'),
		"FUZZ-005", O('{"enabled":b:true}', Empty, '{"fuzz":{"enabled":b:true}}'),
		"FUZZ-006", O('{"enabled":b:false}', Empty, '{"fuzz":{"enabled":b:false}}'),
		"FUZZ-007", O("reject:Unterminated TOML document record", '{"section":{"key":i:1}}',
			'{"fuzz":{},"section":{"key":i:1}}'),
		"FUZZ-008", O("reject:Unterminated TOML document record", Empty,
			'{"fuzz":{"key":s:"<22>unclosed string"}}'),
		"FUZZ-009", O("reject:Unterminated TOML document record", Empty,
			'{"fuzz":{"key":s:"' . "'" . 'unclosed single"}}'),
		"FUZZ-010", O('{"key":s:"bad q escape"}', Empty, '{"fuzz":{"key":s:"bad q escape"}}',
			"an unknown escape decodes to its character instead of being rejected"),
		"FUZZ-011", O('{"' . LongKey . '":i:1}', Empty, '{"fuzz":{"' . LongKey . '":i:1}}'),
		"FUZZ-012", O("reject:Duplicate TOML semantic assignment", Empty, '{"fuzz":{"key":i:2}}'),
		"FUZZ-013", O("reject:TOML string contains an unsupported Unicode scalar.", Empty,
			"reject:TOML string contains an unsupported Unicode scalar.",
			"U+0000 is a valid TOML escape but AHK strings refuse it; " . FlatThrows),
		"FUZZ-014", O('{"key":s:"bom-test"}', Empty, '{"fuzz":{"key":s:"bom-test"}}'),
		"FUZZ-015", O('{"key":s:"crlf","other":i:1}', Empty, '{"fuzz":{"key":s:"crlf","other":i:1}}'),
		"FUZZ-016", O('{"key":s:"lf","other":i:1}', Empty, '{"fuzz":{"key":s:"lf","other":i:1}}'),
		"FUZZ-017", O('{"big":s:"99999999999999999999999999999999999999999999999999"}', Empty,
			'{"fuzz":{"big":s:"99999999999999999999999999999999999999999999999999"}}',
			"an out-of-range integer stays raw text instead of being rejected"),
		"FUZZ-018", O('{"neg":s:"-99999999999999999999999999999999999999999999999999"}', Empty,
			'{"fuzz":{"neg":s:"-99999999999999999999999999999999999999999999999999"}}',
			"an out-of-range integer stays raw text instead of being rejected"),
		"FUZZ-019", O('{"parent":{"child":{"nested":i:2},"key":i:1}}',
			'{"parent":{"key":i:1},"parent.child":{"nested":i:2}}',
			'{"fuzz":{},"parent":{"key":i:1},"parent.child":{"nested":i:2}}'),
		"FUZZ-020", O('{"items":[{"name":s:"first"},{"name":s:"second"}]}',
			'{"items":{"name":s:"second"}}', '{"fuzz":{},"items":{"name":s:"second"}}'),
		"FUZZ-021", O('{"ml":s:"line one<0a>line two<0a>"}', Empty, '{"fuzz":{"ml":s:"<22>"}}',
			FlatMultiline),
		"FUZZ-022", O('{"ml":s:"line one<0a>line two<0a>"}', Empty, '{"fuzz":{"ml":s:"' . "'" . '"}}',
			FlatMultiline),
		"FUZZ-023", O('{"key":s:""}', Empty, '{"fuzz":{"key":s:""}}',
			"a missing value reads as an empty string instead of being rejected"),
		"FUZZ-024", O("reject:A TOML key path requires a segment", Empty, '{"fuzz":{"":s:"no key"}}'),
		"FUZZ-025", O("reject:A TOML key path requires a segment", '{"":{}}', '{"":{},"fuzz":{}}'),
		"FUZZ-026", O('{"arr":[i:1,i:2,i:3]}', Empty, '{"fuzz":{"arr":[i:1,i:2,i:3]}}'),
		"FUZZ-027", O('{"arr":[s:"a",s:"b",s:"c"]}', Empty, '{"fuzz":{"arr":[s:"a",s:"b",s:"c"]}}'),
		"FUZZ-028", O('{"arr":[i:1,s:"mixed",b:true]}', Empty, '{"fuzz":{"arr":[i:1,s:"mixed",b:true]}}'),
		"FUZZ-029", O('{"key":s:"value"}', Empty, '{"fuzz":{"key":s:"value"}}'),
		"FUZZ-030", O('{"key":s:"value"}', Empty, '{"fuzz":{"key":s:"value"}}'),
		"FUZZ-031", O("reject:Duplicate or closed TOML table namespace", '{"section":{"key":i:1}}',
			'{"fuzz":{},"section":{"key":i:1}}'),
		"FUZZ-032", O('{"key":s:"tab<09>here"}', Empty, '{"fuzz":{"key":s:"tab<09>here"}}'),
		"FUZZ-033", O('{"key":s:"newline<0a>here"}', Empty, '{"fuzz":{"key":s:"newline<0a>here"}}'),
		"FUZZ-034", O('{"key":s:"backslash<5c>here"}', Empty, '{"fuzz":{"key":s:"backslash<5c>here"}}'),
		"FUZZ-035", O('{"key":s:"unicode A"}', Empty, '{"fuzz":{"key":s:"unicode A"}}'),
		"FUZZ-036", O('{"key":s:"bad u00ZZ"}', Empty, '{"fuzz":{"key":s:"bad u00ZZ"}}',
			"a malformed \u escape decodes to its letter instead of being rejected"),
		"FUZZ-037", O('{"a":{"b":{"c":{"deep":i:1}}}}', '{"a.b.c":{"deep":i:1}}',
			'{"a.b.c":{"deep":i:1},"fuzz":{}}'),
		"FUZZ-038", O('{"key":f:1.5}', Empty, '{"fuzz":{"key":f:1.5}}'),
		"FUZZ-039", O('{"key":s:"inf"}', Empty, '{"fuzz":{"key":s:"inf"}}', Legacy),
		"FUZZ-040", O('{"key":s:"nan"}', Empty, '{"fuzz":{"key":s:"nan"}}', Legacy),
		"FUZZ-041", O('{"key":s:"1_000_000"}', Empty, '{"fuzz":{"key":s:"1_000_000"}}', Legacy),
		"FUZZ-042", O('{"key":s:"0xFF"}', Empty, '{"fuzz":{"key":s:"0xFF"}}', Legacy),
		"FUZZ-043", O('{"key":s:"0b1010"}', Empty, '{"fuzz":{"key":s:"0b1010"}}', Legacy),
		"FUZZ-044", O('{"key":s:"0o17"}', Empty, '{"fuzz":{"key":s:"0o17"}}', Legacy),
		"FUZZ-045", O("reject:A TOML key path requires a segment", '{"":{}}', '{"":{},"fuzz":{}}'),
		"FUZZ-046", O('{"quoted.key":i:1}', Empty, '{"fuzz":{"quoted.key":i:1}}'),
		"FUZZ-047", O('{"section":{"key":s:"value","sub":{"nested":b:true}}}',
			'{"section":{"key":s:"value"},"section.sub":{"nested":b:true}}',
			'{"fuzz":{},"section":{"key":s:"value"},"section.sub":{"nested":b:true}}'),
		"FUZZ-048", O('{"key":{"a":i:1,"b":i:2}}', Empty, '{"fuzz":{"key":{"a":i:1,"b":i:2}}}'),
		"FUZZ-049", O("reject:Empty TOML inline table member", Empty, "reject:Empty TOML inline table member",
			FlatThrows),
		"FUZZ-050", O('{"key":[i:1,i:2,i:3]}', Empty, '{"fuzz":{"key":[i:1,i:2,i:3]}}'),
		"FUZZ-051", O("reject:TOML header extends a closed value", '{"tap_hold.keys":{"a":i:1}}',
			'{"fuzz":{"tap_hold":s:"oops"},"tap_hold.keys":{"a":i:1}}'),
		"FUZZ-052", O("reject:TOML table array redefines a value", '{"a":{"x":i:1}}',
			'{"a":{"x":i:1},"fuzz":{"a":i:1}}'))
}

; The FUZZ-011 key, rebuilt from the corpus text rather than from a parse.
_TomlFuzz_LongKey(Data) {
	for Vec in Data {
		if Vec.Get("id", "") == "FUZZ-011" && RegExMatch(Vec["input"], "^(a+) = 1$", &Match)
			return Match[1]
	}
	throw ValueError("FUZZ-011 must remain one long bare key assigned 1")
}





; =====================================
; =====================================
; ======= 3/ Observation owners =======
; =====================================
; =====================================

; Runs one reader and returns its canonical result or "reject:<message>".
; Only ValueError is an admitted rejection class: any other error type is a
; crash and propagates to fail the test.
_TomlFuzz_Observe(Reader) {
	try Result := Reader()
	catch ValueError as Err
		return "reject:" . Err.Message
	return _TomlFuzz_Canon(Result)
}

; Parses a file with the public cached reader after evicting any earlier
; cache entry for the same path, so the observation is of these bytes.
_TomlFuzz_ParsePublic(Path) {
	global _ParseTomlCache
	if _ParseTomlCache.Has(Path)
		_ParseTomlCache.Delete(Path)
	return ParseTomlFile(Path)
}

; Writes Text to a vector-owned temporary file.
_TomlFuzz_WriteTemp(Name, Text) {
	Path := A_Temp . "\toml_fuzz_" . Name . ".toml"
	try FileDelete(Path)
	FileAppend(Text, Path, "UTF-8")
	return Path
}

; Renders a flat reader result through the canonical writers. Empty sections
; carry no data and are omitted; the root section can never hold an entry.
_TomlFuzz_Render(Sections) {
	Text := ""
	for Section, Entries in Sections {
		if !Entries.Count
			continue
		if Section == ""
			throw ValueError("the flat reader returned an entry in the unnamed root section")
		Text .= "[" . Section . "]`n"
		for Key, Value in Entries
			Text .= TOML_RenderKey(Key) . " = " . TOML_RenderValue(Value) . "`n"
	}
	return Text
}

; Drops empty sections, matching what _TomlFuzz_Render can express.
_TomlFuzz_NonEmpty(Sections) {
	Kept := Map()
	for Section, Entries in Sections {
		if Entries.Count
			Kept[Section] := Entries
	}
	return Kept
}

; The production readers every vector check observes. The mutation control in
; section 5 swaps in deliberately broken ones through the same parameter.
; @return {Map} "doc" (text), "typed" (path) and "public" (path) readers.
_TomlFuzz_ProductionReaders() {
	return Map("doc", TOML_ParseDocument, "typed", TOML_ParseFreshFileTyped,
		"public", _TomlFuzz_ParsePublic)
}

; Checks one vector against its oracle; throws on the first mismatch.
; @param VecId {String} The corpus id, also the temp file stem.
; @param Input {String} The TOML text.
; @param Oracle {Map} The expectation from _TomlFuzz_Oracles.
; @param Readers {Map} The readers under test; the production ones by default.
_TomlFuzz_CheckVector(VecId, Input, Oracle, Readers := "") {
	if Readers == ""
		Readers := _TomlFuzz_ProductionReaders()
	Doc := Readers["doc"], Typed := Readers["typed"], Public := Readers["public"]
	Tag := "[" . VecId . "] "
	AssertEqual(Oracle["doc"], _TomlFuzz_Observe(() => Doc(Input)),
		Tag . "TOML_ParseDocument result")

	RootPath := _TomlFuzz_WriteTemp(VecId . "_root", Input)
	SectionedPath := _TomlFuzz_WriteTemp(VecId . "_sectioned", "[fuzz]`n" . Input)
	try {
		AssertEqual(Oracle["flat"], _TomlFuzz_Observe(() => Typed(RootPath)),
			Tag . "typed flat parse of the vector")
		AssertEqual(_TomlFuzz_NativeBooleans(Oracle["flat"]),
			_TomlFuzz_Observe(() => Public(RootPath)), Tag . "ParseTomlFile of the vector")
		AssertEqual(Oracle["sectioned"], _TomlFuzz_Observe(() => Typed(SectionedPath)),
			Tag . "typed flat parse under [fuzz]")
		AssertEqual(_TomlFuzz_NativeBooleans(Oracle["sectioned"]),
			_TomlFuzz_Observe(() => Public(SectionedPath)), Tag . "ParseTomlFile under [fuzz]")
		if SubStr(Oracle["sectioned"], 1, 7) == "reject:"
			return

		; Round trip: what the canonical writers emit must read back unchanged
		; and must be a document the strict semantic reader accepts.
		First := Typed(SectionedPath)
		Rendered := _TomlFuzz_Render(First)
		RenderedPath := _TomlFuzz_WriteTemp(VecId . "_rendered", Rendered)
		try {
			AssertEqual(_TomlFuzz_Canon(_TomlFuzz_NonEmpty(First)),
				_TomlFuzz_Canon(_TomlFuzz_NonEmpty(Typed(RenderedPath))),
				Tag . "rendered result must re-parse to the same value")
		} finally {
			try FileDelete(RenderedPath)
		}
		Assert(SubStr(_TomlFuzz_Observe(() => Doc(Rendered)), 1, 7) != "reject:",
			Tag . "the semantic reader must accept the writers' rendering: " . Rendered)
	} finally {
		try FileDelete(RootPath)
		try FileDelete(SectionedPath)
	}
}





; ===============================
; ===============================
; ======= 4/ Registration =======
; ===============================
; ===============================

_TomlFuzz_CorpusPath() {
	return A_ScriptDir . "\..\..\_shared\tests\corpus\toml\fuzz_corpus.json"
}

_TomlFuzz_RunAll() {
	CorpusPath := _TomlFuzz_CorpusPath()

	_TomlFuzz_FileExists() {
		Assert(FileExist(CorpusPath) != "", "TOML fuzz corpus must exist at: " . CorpusPath)
	}
	Test("TOML fuzz corpus: file exists", _TomlFuzz_FileExists)

	if !FileExist(CorpusPath)
		return

	Data := JsonParse(FileRead(CorpusPath, "UTF-8"))

	_TomlFuzz_IsArray() {
		; The fuzz corpus is a top-level JSON array (not wrapped in a 'vectors' key)
		Assert(Type(Data) = "Array", "TOML fuzz corpus must be a JSON array, got: " . Type(Data))
		Assert(Data.Length >= 50, "TOML fuzz corpus must have >=50 entries, got: " . Data.Length)
	}
	Test("TOML fuzz corpus: valid array with >=50 entries", _TomlFuzz_IsArray)

	if Type(Data) != "Array"
		return

	Oracles := _TomlFuzz_Oracles(_TomlFuzz_LongKey(Data))
	_TomlFuzz_RegisterVectors(Data, Test, Oracles)

	_TomlFuzz_Consistency() {
		_TomlFuzz_AssertCorpusConsistency(Data, Oracles)
	}
	Test("TOML fuzz corpus: every vector has an oracle that honours its expect or names the departure",
		_TomlFuzz_Consistency)
}

; Every vector needs exactly one oracle, and the semantic reader must honour
; the shared corpus's expect unless the oracle names the departure. A note may
; also sit on an honoured vector: the corpus's "ok" only means "must not
; crash", so an accepted out-of-range integer still departs from TOML 1.0.
_TomlFuzz_AssertCorpusConsistency(Data, Oracles) {
	Seen := Map()
	for Vec in Data {
		Id := Vec["id"]
		Assert(Oracles.Has(Id), "TOML fuzz vector " . Id . " has no semantic oracle")
		Assert(!Seen.Has(Id), "TOML fuzz vector id " . Id . " is duplicated")
		Seen[Id] := true
		Oracle := Oracles[Id]
		Rejects := SubStr(Oracle["doc"], 1, 7) == "reject:"
		Honours := (Vec["expect"] == "error") == Rejects
		Assert(Honours || Oracle["note"] != "",
			Id . " expects " . Vec["expect"] . " but the semantic oracle says " . Oracle["doc"] . " without a stated departure")
	}
	for Id in Oracles
		Assert(Seen.Has(Id), "TOML fuzz oracle " . Id . " names no corpus vector")
	Assert(Seen.Count >= 50, "TOML fuzz consistency must cover >=50 vectors, saw " . Seen.Count)
}

; Registers the admitted vectors without executing their file/parser callbacks.
; @param Data {Array} Canonical decoded corpus or independently authored recording vectors.
; @param RegisterTest {Func} The actual test registry owner or a recording sink.
; @param Oracles {Map} Vector id -> expectation; a vector without one fails registration.
; @return {Integer} Count of vectors explicitly excluded for an actual UTF-16 NUL.
_TomlFuzz_RegisterVectors(Data, RegisterTest, Oracles) {
	if !(Data is Array) || !(RegisterTest is Func) || !(Oracles is Map)
		throw TypeError("TOML fuzz registration requires its corpus, registry owner and oracles.")
	Skipped := 0

	for Vec in Data {
		VecId   := Vec.Has("id")          ? Vec["id"]          : "UNKNOWN"
		Input   := Vec.Has("input")       ? Vec["input"]       : ""
		Descr   := Vec.Has("description") ? Vec["description"] : ""

		; Skip inputs containing null bytes — FileAppend on Windows will silently
		; truncate or corrupt the file, making the test meaningless.
		if RegExMatch(Input, "\x00") {
			Skipped++
			continue
		}
		if !Oracles.Has(VecId)
			throw ValueError("TOML fuzz vector " . VecId . " has no semantic oracle")

		RegisterTest.Call("[corpus:TOML-" . VecId . "] " . Descr,
			_TomlFuzz_CheckVector.Bind(VecId, Input, Oracles[VecId]))
	}

	return Skipped
}

_TomlFuzz_RunAll()





; ==========================================
; ==========================================
; ======= 5/ Controls on the harness =======
; ==========================================
; ==========================================

_TomlFuzz_NulRegistrationControls() {
	Data := [
		Map("id", "safe-first", "input", "a=1", "description", "first"),
		Map("id", "nul-head", "input", Chr(0) . "a=1"),
		Map("id", "safe-empty", "input", "", "description", "empty"),
		Map("id", "nul-middle", "input", "a=" . Chr(0) . "1"),
		Map("id", "safe-unicode", "input", "a='é'", "description", "unicode"),
		Map("id", "nul-tail", "input", "a=1" . Chr(0)),
		Map("id", "safe-last", "input", "a=2", "description", "last")]
	Oracles := Map()
	for Id in ["safe-first", "safe-empty", "safe-unicode", "safe-last"]
		Oracles[Id] := _TomlFuzz_Oracle("{}", "{}", "{}")
	Recorded := []
	Register := (Name, Callback) => Recorded.Push(Map("name", Name, "callback", Callback))
	AssertEqual(3, _TomlFuzz_RegisterVectors(Data, Register, Oracles), "only the three actual NUL vectors are excluded")
	AssertEqual(4, Recorded.Length, "all ordinary vectors are registered, including empty and Unicode")
	for Index, Expected in ["[corpus:TOML-safe-first] first", "[corpus:TOML-safe-empty] empty",
		"[corpus:TOML-safe-unicode] unicode", "[corpus:TOML-safe-last] last"] {
		AssertEqual(Expected, Recorded[Index]["name"], "the actual registration preserves each independent id and order")
		Assert(Recorded[Index]["callback"] is Func, "the actual bound vector callback is retained")
	}
	AssertThrows(() => _TomlFuzz_RegisterVectors([Map("id", "orphan", "input", "a=1")], Register, Map()),
		"a vector without an oracle must refuse registration")
}
Test("TOML fuzz corpus: actual UTF-16 registration excludes only NUL vectors", _TomlFuzz_NulRegistrationControls)

; The canonical form must keep the type distinctions the oracles rely on.
_TomlFuzz_CanonControls() {
	Values := [1, "1", 1.0, TOML_Bool(true), TOML_Bool(false), 0, "", [1], Map("1", 1)]
	Seen := Map()
	for Value in Values {
		Text := _TomlFuzz_Canon(Value)
		Assert(!Seen.Has(Text), "two distinct TOML values share the canonical form " . Text)
		Seen[Text] := true
	}
	AssertEqual('{"a":i:1,"b":s:"x<22><3c>"}', _TomlFuzz_Canon(Map("b", 'x"<', "a", 1)),
		"maps encode in ordinal key order with quotes and the escape marker spelled out")
	Assert(_TomlFuzz_Canon("<22>") != _TomlFuzz_Canon('"'), "a literal escape spelling cannot alias a quote")
}
Test("TOML fuzz corpus: canonical form separates integers, strings, floats and Booleans", _TomlFuzz_CanonControls)

; Each observation must be able to fail: a wrong value, a wrong rejection
; message and an accepted vector declared rejected all refuse the vector.
_TomlFuzz_CheckerControls() {
	Good := _TomlFuzz_Oracle('{"enabled":b:true}', "{}", '{"fuzz":{"enabled":b:true}}')
	_TomlFuzz_CheckVector("control-good", "enabled = true", Good)
	Mutants := [
		_TomlFuzz_Oracle('{"enabled":b:false}', "{}", '{"fuzz":{"enabled":b:true}}'),
		_TomlFuzz_Oracle('{"enabled":b:true}', '{"fuzz":{}}', '{"fuzz":{"enabled":b:true}}'),
		_TomlFuzz_Oracle('{"enabled":b:true}', "{}", '{"fuzz":{"enabled":s:"true"}}'),
		_TomlFuzz_Oracle("reject:Duplicate TOML semantic assignment", "{}", '{"fuzz":{"enabled":b:true}}')]
	for Index, Mutant in Mutants
		AssertThrows(_TomlFuzz_CheckVector.Bind("control-mutant-" . Index, "enabled = true", Mutant),
			"wrong oracle " . Index . " must fail the vector check")
	AssertThrows(_TomlFuzz_CheckVector.Bind("control-reject", "key = 1`nkey = 2",
		_TomlFuzz_Oracle("reject:Unterminated TOML document record", "{}", '{"fuzz":{"key":i:2}}')),
		"a rejection with another message must fail the vector check")
}
Test("TOML fuzz corpus: the vector check fails on a wrong value or rejection class", _TomlFuzz_CheckerControls)

; Rewrites a reader result the way one deliberately broken parser would.
; @param Value {Any} A reader result or a nested member of one.
; @param Kind {String} The mutant: flip-bool, int-as-string, drop-escapes or keep-trailing-space.
; @return {Any} A fresh mutated copy; the original result is not modified.
_TomlFuzz_Mutate(Value, Kind) {
	if Value is TOML_Bool
		return Kind == "flip-bool" ? TOML_Bool(!Value.Value) : Value
	if Value is Map {
		Copy := Map()
		for Key, Item in Value
			Copy[Key] := _TomlFuzz_Mutate(Item, Kind)
		return Copy
	}
	if Value is Array {
		Copy := []
		for Item in Value
			Copy.Push(_TomlFuzz_Mutate(Item, Kind))
		return Copy
	}
	if Value is Integer
		return Kind == "int-as-string" ? String(Value) : Value
	if Value is String {
		if Kind == "drop-escapes"
			return RegExReplace(Value, "[\t\n\\]")
		if Kind == "keep-trailing-space"
			return Value . " "
	}
	return Value
}

; Reads through one production reader, then breaks it as the mutant says.
; "accept-invalid" swallows every rejection, as a lenient parser would.
_TomlFuzz_MutantRead(Reader, Kind, Argument) {
	if Kind == "accept-invalid" {
		try return Reader(Argument)
		catch ValueError
			return Map()
	}
	return _TomlFuzz_Mutate(Reader(Argument), Kind)
}

; The production readers, every one broken the same way.
_TomlFuzz_MutantReaders(Kind) {
	Mutant := Map()
	for Name, Reader in _TomlFuzz_ProductionReaders()
		Mutant[Name] := _TomlFuzz_MutantRead.Bind(Reader, Kind)
	return Mutant
}

; Replays the whole corpus against each deliberately broken parser: the fuzz
; must refuse every mutant, and on the vector that by hand must expose it.
_TomlFuzz_ParserMutationControls() {
	Data := JsonParse(FileRead(_TomlFuzz_CorpusPath(), "UTF-8"))
	Oracles := _TomlFuzz_Oracles(_TomlFuzz_LongKey(Data))
	; Chosen from the corpus text, not from a run: each vector's value is the
	; one property its mutant corrupts.
	Expected := Map(
		"flip-bool", "FUZZ-005",
		"int-as-string", "FUZZ-004",
		"drop-escapes", "FUZZ-032",
		"keep-trailing-space", "FUZZ-003",
		"accept-invalid", "FUZZ-012")
	for Kind, Witness in Expected {
		Readers := _TomlFuzz_MutantReaders(Kind)
		Killed := Map()
		for Vec in Data {
			if RegExMatch(Vec["input"], "\x00")
				continue
			try _TomlFuzz_CheckVector(Vec["id"] . "_mutant", Vec["input"], Oracles[Vec["id"]], Readers)
			catch Error
				Killed[Vec["id"]] := true
		}
		Assert(Killed.Count > 0, "the TOML fuzz accepted every vector from the " . Kind . " parser mutant")
		Assert(Killed.Has(Witness), "the TOML fuzz did not refuse " . Witness . " from the " . Kind . " parser mutant")
	}
	; The same loop with the production readers kills nothing.
	for Vec in Data {
		if !RegExMatch(Vec["input"], "\x00")
			_TomlFuzz_CheckVector(Vec["id"] . "_control", Vec["input"], Oracles[Vec["id"]])
	}
}
Test("TOML fuzz corpus: every deliberately broken parser fails the corpus", _TomlFuzz_ParserMutationControls)
