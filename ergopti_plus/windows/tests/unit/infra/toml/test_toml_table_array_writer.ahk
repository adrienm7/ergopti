; tests/unit/infra/toml/test_toml_table_array_writer.ahk

; ==============================================================================
; MODULE: TOML Foreign Table-Array Writer Admission
; DESCRIPTION:
; Foreign table arrays and their siblings, the canonical lexer and comment
; newlines keep the writer from claiming bytes it cannot reproduce.
; ==============================================================================

#Requires AutoHotkey v2.0





_TAOT_Source() {
	return '[layout]`nenabled = true # independently owned`n'
		. '[["hotstrings"."terminators"]] # first record`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`nmetadata = { opaque = "keep", count = 7 }`n'
		. '[[hotstrings.terminators]] # second record`nkey = "smile"`nchar = "😀"`nlabel = "Smile"`nconsume = false`n'
		. '[private]`nvalue = "leave exactly" # untouched`n'
}

_TAOT_AssertFuture(Content) {
	Document := TOML_ParseDocument(Content)
	AssertEqual(2, Document["future"].Length, "both independent table-array records must survive")
	AssertEqual("first", Document["future"][1]["name"])
	AssertEqual("second", Document["future"][2]["name"])
	AssertContains(Content, '[[future]]`nname="first"`n[[future]]`nname="second"`n',
		"the original foreign lexical spans must remain byte-for-byte present")
}

_TAOT_AssertRequested(Content, Update) {
	Document := TOML_ParseDocument(Content), Entries := Document["settings"]
	if Update.HasOwnProp("Delete") && Update.Delete == 1
		AssertFalse(Entries.Has(Update.Key), "the independently requested deletion must take effect")
	else
		AssertTrue(TOML_SameValue(Update.Value, Entries[Update.Key]), "the requested sibling value must take effect")
}

_TAOT_DetachedAndNative() {
	Path := _TBUI_NewPath(), FixtureSource := Chr(0xFEFF) . _TAOT_Source()
	try {
		AssertTrue(FSWriteCreateDurable(Path, FixtureSource) == 1)
		Cached := ParseTomlFile(Path)
		Updates := [{ Section: "layout", Key: "enabled", Value: TOML_Bool(false) }]
		Candidate := TOML_BuildUpdatedContent(Path, Updates)
		AssertEqual("ok", Candidate["status"], "a representable sibling must not borrow the collapsed array row")
		AssertEqual(FixtureSource, Candidate["source_content"], "the complete old source still binds later publication")
		AssertTrue(FSUtf8ExactMatches(Path, FixtureSource), "detached preparation has no disk effects")
		AssertTrue(Cached == ParseTomlFile(Path), "detached preparation retains the live cached receipt")
		Document := TOML_ParseDocument(Candidate["content"])
		AssertTrue(Document["layout"]["enabled"] is TOML_Bool)
		AssertEqual(false, Document["layout"]["enabled"].Value)
		AssertEqual(2, Document["hotstrings"]["terminators"].Length)
		AssertEqual("currency", Document["hotstrings"]["terminators"][1]["key"])
		AssertEqual("¤", Document["hotstrings"]["terminators"][1]["char"])
		AssertEqual(7, Document["hotstrings"]["terminators"][1]["metadata"]["count"])
		AssertEqual("keep", Document["hotstrings"]["terminators"][1]["metadata"]["opaque"])
		AssertEqual("😀", Document["hotstrings"]["terminators"][2]["char"])
		AssertContains(Candidate["content"], SubStr(_TAOT_Source(), InStr(_TAOT_Source(), '[["hotstrings"')),
			"foreign record and private-tail spans must remain exact")
		AssertTrue(TOML_BatchWrite(Path, Updates))
		AssertTrue(FSUtf8ExactMatches(Path, Candidate["content"]), "ordinary publication equals the qualified detached image")
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: actual detached and native sibling update preserves custom record generations and unknown spans", _TAOT_DetachedAndNative)

_TAOT_NestedArray() {
	Path := _TBUI_NewPath()
	FixtureSource := '[[future]] # outer first`nname="first"`n[[future.children]] # child one`nvalue="one"`n[[future.children]]`nvalue="two"`n[[future]]`nname="second"`n[settings]`nowned=1`n'
	try {
		AssertTrue(FSWriteDurable(Path, FixtureSource))
		Candidate := TOML_BuildUpdatedContent(Path, [{ Section: "settings", Key: "owned", Value: 2 }])
		AssertEqual("ok", Candidate["status"], "nested arrays stay with their exact outer row")
		Document := TOML_ParseDocument(Candidate["content"])
		AssertEqual(2, Document["future"].Length)
		AssertEqual("first", Document["future"][1]["name"])
		AssertEqual(2, Document["future"][1]["children"].Length)
		AssertEqual("one", Document["future"][1]["children"][1]["value"])
		AssertEqual("two", Document["future"][1]["children"][2]["value"])
		AssertEqual("second", Document["future"][2]["name"])
		AssertEqual(2, Document["settings"]["owned"])
		AssertContains(Candidate["content"], SubStr(FixtureSource, 1, InStr(FixtureSource, "[settings]") - 1))
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: nested table arrays retain outer record identity and exact lexical spans", _TAOT_NestedArray)

_TAOT_RefusedNamespace(Updates, Prefixes := []) {
	Path := _TBUI_NewPath(), FixtureSource := Chr(0xFEFF) . _TAOT_Source()
	try {
		AssertTrue(FSWriteCreateDurable(Path, FixtureSource) == 1)
		Candidate := TOML_BuildUpdatedContent(Path, Updates, Prefixes)
		AssertEqual("error", Candidate["status"], "a foreign table array cannot lend flat write authority")
		AssertFalse(Candidate.Has("source_content"))
		AssertFalse(TOML_BatchWrite(Path, Updates, Prefixes))
		AssertTrue(FSUtf8ExactMatches(Path, FixtureSource), "refusal must precede any physical replacement")
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: direct collapsed-record mutation refuses without effects", _TAOT_RefusedNamespace.Bind([{ Section: "hotstrings.terminators", Key: "char", Value: "x" }]))
Test("toml-aot-sibling: native case alias cannot acquire a foreign record", _TAOT_RefusedNamespace.Bind([{ Section: "HOTSTRINGS.TERMINATORS", Key: "char", Value: "x" }]))
Test("toml-aot-sibling: replacing the array ancestor refuses without effects", _TAOT_RefusedNamespace.Bind([], ["hotstrings"]))
Test("toml-aot-sibling: replacing an array child refuses without effects", _TAOT_RefusedNamespace.Bind([], ["hotstrings.terminators.metadata"]))

_TAOT_IgnoredRootStillRefuses() {
	Path := _TBUI_NewPath(), FixtureSource := 'root.future = "keep"`n' . _TAOT_Source()
	try {
		AssertTrue(FSWriteDurable(Path, FixtureSource))
		Candidate := TOML_BuildUpdatedContent(Path, [{ Section: "layout", Key: "enabled", Value: TOML_Bool(false) }])
		AssertEqual("error", Candidate["status"], "the AOT partition cannot excuse a second unrepresented namespace")
		AssertFalse(TOML_BatchWrite(Path, [{ Section: "layout", Key: "enabled", Value: TOML_Bool(false) }]))
		AssertTrue(FSUtf8ExactMatches(Path, FixtureSource))
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: an unrelated ignored root still refuses despite preserved array records", _TAOT_IgnoredRootStillRefuses)

_TAOT_SourceRace() {
	Path := _TBUI_NewPath(), FixtureSource := Chr(0xFEFF) . _TAOT_Source()
	Foreign := FixtureSource . '# exact independent concurrent writer`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, FixtureSource) == 1)
		ConcurrentValue := _TBUI_SourceMutatingBoolean(Path, Foreign)
		Candidate := TOML_BuildUpdatedContent(Path, [{ Section: "layout", Key: "enabled", Value: ConcurrentValue }])
		AssertTrue(ConcurrentValue.Calls > 0)
		AssertTrue(ConcurrentValue.WriteAccepted)
		AssertEqual("error", Candidate["status"], "foreign-record retention cannot bypass the old-source fence")
		AssertTrue(FSUtf8ExactMatches(Path, Foreign))
	} finally FSDelete(Path)
}
Test("toml-aot-sibling: actual concurrent source mutation still wins before publication", _TAOT_SourceRace)

; One registered native case owns both merged canonical lexer contracts.
_TBUI_CanonicalSpansAndContainerBoundary() {
	Expected := '{ owned = false, future = "a,}#=b" }'
	Remainder := ' # trailing future marker`nnext = "retain"`n'
	Source := "  " . Expected . Remainder
	Position := 1
	Token := _TOML_DocumentToken(Source, &Position, Chr(0), &Separated,
		&SpanStart, &SpanEnd, true)
	AssertEqual(Expected, Token, "container stopping retains the complete handwritten token")
	AssertFalse(Separated, "balanced container completion does not invent a separator")
	AssertEqual(3, SpanStart, "outside leading trivia does not own the token span")
	AssertEqual(2 + StrLen(Expected), SpanEnd, "the closing container owns the final span byte")
	AssertEqual(SpanEnd + 1, Position, "the retained cursor stops immediately after the matching closure")
	AssertEqual(Remainder, SubStr(Source, Position), "following source comments and records remain unconsumed")
	Document := TOML_ParseDocument("private = " . Token . "`n")
	AssertTrue(Document["private"]["owned"] is TOML_Bool)
	AssertEqual(false, Document["private"]["owned"].Value)
	AssertEqual("a,}#=b", Document["private"]["future"], "quoted structural characters cannot close the container")

	Scalar := '  "a,}#=b" # retained trailing comment'
	Position := 1
	Token := _TOML_DocumentToken(Scalar, &Position, Chr(0), &Separated, &SpanStart, &SpanEnd)
	AssertEqual('"a,}#=b"', Token, "the unchanged default lexer still consumes the complete scalar record")
	AssertFalse(Separated)
	AssertEqual(3, SpanStart)
	AssertEqual(10, SpanEnd, "quoted punctuation belongs to the complete original scalar span")
	AssertEqual(StrLen(Scalar) + 1, Position, "omitted container stopping preserves complete-record consumption")
}
Test("toml canonical lexer: merged spans and balanced-container stopping preserve the same source owner",
	_TBUI_CanonicalSpansAndContainerBoundary)

; Frozen handwritten UTF-16 lexer vectors predate the native-search candidate.
; No file, cache, port, or publication state is mutated by these direct calls.
_TBUI_CommentTokenUnits(Units, Label) {
	Text := ""
	for Unit in Units
		Text .= Chr(Unit)
	_TBUI_CommentTokenAssertUnits(Units, Text, Label)
	return Text
}

_TBUI_CommentTokenAssertUnits(Units, Text, Label) {
	AssertEqual(Units.Length, StrLen(Text), Label . " exact UTF-16 length")
	for Index, Unit in Units
		AssertEqual(Unit, Ord(SubStr(Text, Index, 1)), Label . " UTF-16 unit " . Index)
}

_TBUI_CommentTokenVector(Vector) {
	Source := _TBUI_CommentTokenUnits(Vector.Source, "source")
	Separator := _TBUI_CommentTokenUnits(Vector.Separator, "separator")
	Expected := _TBUI_CommentTokenUnits(Vector.Token, "expected token")
	Position := Vector.Initial, Separated := -1, SpanStart := -1, SpanEnd := -1
	Caught := false, Token := ""
	try Token := _TOML_DocumentToken(Source, &Position, Separator, &Separated,
		&SpanStart, &SpanEnd, Vector.Stop)
	catch Error as Failure
		Caught := Failure
	if Vector.ErrorType != "" {
		AssertTrue(IsObject(Caught), "the original error must remain observable")
		AssertEqual(Vector.ErrorType, Type(Caught), "original error class")
		if Vector.Error != ""
			AssertEqual(Vector.Error, Caught.Message, "original document error")
	} else {
		if IsObject(Caught)
			throw Caught
		AssertEqual(Expected, Token, "handwritten token")
		_TBUI_CommentTokenAssertUnits(Vector.Token, Token, "actual token")
	}
	AssertEqual(Vector.Position, Position, "exact cursor")
	AssertEqual(Vector.PositionType, Type(Position), "cursor value type")
	AssertEqual(Vector.Separated, Separated, "original separator admission")
	AssertEqual(Vector.Start, SpanStart, "original first owned unit")
	AssertEqual(Vector.End, SpanEnd, "original final owned unit")
}

_TBUI_CommentTokenVectors() {
	return [
		{ Id: "line-feed-is-processed-by-original-separator", Source: [35, 120, 10, 55], Separator: [10], Initial: 1, Stop: false, Token: [], Position: 4, PositionType: "Integer", Separated: true, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "comment-at-end-retains-original-eof-cursor", Source: [35, 120], Separator: [10], Initial: 1, Stop: false, Token: [], Position: 3, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "one-unit-comment-at-end", Source: [35], Separator: [10], Initial: 1, Stop: false, Token: [], Position: 2, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "scalar-comment-span", Source: [97, 32, 35, 120, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 6, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "crlf-comment-span", Source: [97, 32, 35, 120, 13, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 7, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "carriage-return-at-eof-is-comment-data", Source: [97, 35, 120, 13], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 5, PositionType: "Integer", Separated: false, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "separator-inside-comment-is-not-owned", Source: [97, 35, 61, 10, 61, 98], Separator: [61], Initial: 1, Stop: false, Token: [97], Position: 6, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "nested-array-comment-keeps-newline", Source: [91, 49, 44, 35, 44, 10, 50, 93, 44, 51], Separator: [44], Initial: 1, Stop: false, Token: [91, 49, 44, 10, 50, 93], Position: 10, PositionType: "Integer", Separated: true, Start: 1, End: 8, ErrorType: "", Error: "" },
		{ Id: "comment-hides-quotes-and-closers", Source: [97, 35, 93, 125, 34, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 7, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "basic-quoted-hash-is-data", Source: [34, 35, 34, 44, 120], Separator: [44], Initial: 1, Stop: false, Token: [34, 35, 34], Position: 5, PositionType: "Integer", Separated: true, Start: 1, End: 3, ErrorType: "", Error: "" },
		{ Id: "literal-quoted-hash-is-data", Source: [39, 35, 39, 44, 120], Separator: [44], Initial: 1, Stop: false, Token: [39, 35, 39], Position: 5, PositionType: "Integer", Separated: true, Start: 1, End: 3, ErrorType: "", Error: "" },
		{ Id: "triple-basic-hashes-are-data", Source: [34, 34, 34, 35, 10, 35, 34, 34, 34, 44, 120], Separator: [44], Initial: 1, Stop: false, Token: [34, 34, 34, 35, 10, 35, 34, 34, 34], Position: 11, PositionType: "Integer", Separated: true, Start: 1, End: 9, ErrorType: "", Error: "" },
		{ Id: "triple-literal-hashes-are-data", Source: [39, 39, 39, 35, 10, 35, 39, 39, 39, 44, 120], Separator: [44], Initial: 1, Stop: false, Token: [39, 39, 39, 35, 10, 35, 39, 39, 39], Position: 11, PositionType: "Integer", Separated: true, Start: 1, End: 9, ErrorType: "", Error: "" },
		{ Id: "supplementary-comment-units-do-not-own-span", Source: [97, 35, 55357, 56832, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 6, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "supplementary-token-keeps-two-unit-span", Source: [55357, 56832, 35, 120, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [55357, 56832], Position: 6, PositionType: "Integer", Separated: true, Start: 1, End: 2, ErrorType: "", Error: "" },
		{ Id: "accent-and-surrogate-comment-units", Source: [97, 35, 233, 55357, 56832, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 7, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "isolated-high-surrogate-comment-unit", Source: [97, 35, 55296, 113, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 6, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "nul-before-line-feed-retains-character-fallback", Source: [97, 35, 0, 113, 10, 98], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 6, PositionType: "Integer", Separated: true, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "nul-comment-at-eof-retains-original-cursor", Source: [97, 35, 0, 113], Separator: [10], Initial: 1, Stop: false, Token: [97], Position: 5, PositionType: "Integer", Separated: false, Start: 1, End: 1, ErrorType: "", Error: "" },
		{ Id: "nul-comment-hidden-closer-still-unterminated", Source: [91, 49, 35, 0, 93, 10, 50], Separator: [44], Initial: 1, Stop: false, Token: [], Position: 8, PositionType: "Integer", Separated: false, Start: 1, End: 7, ErrorType: "ValueError", Error: "Unterminated TOML document record" },
		{ Id: "balanced-container-stops-before-trailing-comment", Source: [91, 35, 120, 10, 49, 93, 32, 35, 122, 10, 113], Separator: [0], Initial: 1, Stop: true, Token: [91, 10, 49, 93], Position: 7, PositionType: "Integer", Separated: false, Start: 1, End: 6, ErrorType: "", Error: "" },
		{ Id: "hash-separator-still-starts-comment", Source: [97, 35, 120, 10, 98], Separator: [35], Initial: 1, Stop: false, Token: [97, 10, 98], Position: 6, PositionType: "Integer", Separated: false, Start: 1, End: 5, ErrorType: "", Error: "" },
		{ Id: "later-start-keeps-absolute-span", Source: [120, 120, 97, 35, 121, 10, 98], Separator: [10], Initial: 3, Stop: false, Token: [97], Position: 7, PositionType: "Integer", Separated: true, Start: 3, End: 3, ErrorType: "", Error: "" },
		{ Id: "comment-hidden-closer-keeps-unterminated-error", Source: [91, 49, 44, 35, 93, 10, 50], Separator: [44], Initial: 1, Stop: false, Token: [], Position: 8, PositionType: "Integer", Separated: false, Start: 1, End: 7, ErrorType: "ValueError", Error: "Unterminated TOML document record" },
		{ Id: "quoted-newline-keeps-original-error", Source: [34, 97, 35, 10, 120, 34], Separator: [10], Initial: 1, Stop: false, Token: [], Position: 4, PositionType: "Integer", Separated: false, Start: 1, End: 4, ErrorType: "ValueError", Error: "A single-line TOML string contains a newline" },
		{ Id: "wrong-closer-after-comment-keeps-original-error", Source: [91, 49, 32, 35, 120, 10, 125], Separator: [44], Initial: 1, Stop: false, Token: [], Position: 7, PositionType: "Integer", Separated: false, Start: 1, End: 7, ErrorType: "ValueError", Error: "Unbalanced TOML document container" },
		{ Id: "unterminated-triple-keeps-original-error", Source: [39, 39, 39, 35, 10], Separator: [44], Initial: 1, Stop: false, Token: [], Position: 6, PositionType: "Integer", Separated: false, Start: 1, End: 5, ErrorType: "ValueError", Error: "Unterminated TOML document record" },
		{ Id: "negative-cursor-uses-old-forward-comment-loop", Source: [35, 120, 35], Separator: [10], Initial: -1, Stop: false, Token: [], Position: 4, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "negative-range-clamp-keeps-old-loop", Source: [35, 120, 35], Separator: [10], Initial: -5, Stop: false, Token: [], Position: 4, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "negative-cursor-line-feed-separator", Source: [35, 120, 10], Separator: [10], Initial: -1, Stop: false, Token: [], Position: 0, PositionType: "Integer", Separated: true, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "fractional-comment-cursor-retains-fraction", Source: [35, 120, 10, 98], Separator: [10], Initial: 1.5, Stop: false, Token: [], Position: 4.5, PositionType: "Float", Separated: true, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "integral-float-cursor-keeps-old-addition", Source: [35, 120, 10, 98], Separator: [10], Initial: 1.0, Stop: false, Token: [], Position: 4.0, PositionType: "Float", Separated: true, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "numeric-string-cursor-keeps-original-coercion", Source: [35, 120, 10, 98], Separator: [10], Initial: "1", Stop: false, Token: [], Position: 4, PositionType: "Integer", Separated: true, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "zero-cursor-keeps-empty-needle-value-error", Source: [35, 120, 35], Separator: [10], Initial: 0, Stop: false, Token: [], Position: 0, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "ValueError", Error: "" },
		{ Id: "fraction-under-one-keeps-empty-needle-value-error", Source: [35, 120, 35], Separator: [10], Initial: 0.5, Stop: false, Token: [], Position: 0.5, PositionType: "Float", Separated: false, Start: 0, End: 0, ErrorType: "ValueError", Error: "" },
		{ Id: "past-end-cursor-is-unchanged", Source: [35, 120, 35], Separator: [10], Initial: 4, Stop: false, Token: [], Position: 4, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "far-past-end-cursor-is-unchanged", Source: [35, 120, 35], Separator: [10], Initial: 100, Stop: false, Token: [], Position: 100, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "", Error: "" },
		{ Id: "empty-source-with-ordinary-cursor", Source: [], Separator: [10], Initial: 1, Stop: false, Token: [], Position: 1, PositionType: "Integer", Separated: false, Start: 0, End: 0, ErrorType: "", Error: "" }
	]
}

for _TBUI_CommentTokenCase in _TBUI_CommentTokenVectors()
	Test("toml-comment-newline-native: " . _TBUI_CommentTokenCase.Id,
		_TBUI_CommentTokenVector.Bind(_TBUI_CommentTokenCase))

; Comments leave their LF for the existing separator/container owner to consume.
_TBUI_CommentCursorAndSpans() {
	for CommentVector in [
		{Source: "  a # ignored`nnext", Separator: Chr(10), Token: "a", Cursor: 15, First: 3, Last: 3, Split: true},
		{Source: "  a # ignored`r`nnext", Separator: Chr(10), Token: "a", Cursor: 16, First: 3, Last: 3, Split: true},
		{Source: " a#junk`rb", Separator: Chr(10), Token: "a", Cursor: 10, First: 2, Last: 2, Split: false},
		{Source: ' # fake } ] "', Separator: Chr(10), Token: "", Cursor: 14, First: 0, Last: 0, Split: false},
		{Source: "# comment`nnext", Separator: Chr(10), Token: "", Cursor: 11, First: 0, Last: 0, Split: true},
		{Source: "a # discarded`nb", Separator: ",", Token: "a `nb", Cursor: 16, First: 1, Last: 15, Split: false},
		{Source: "[1,# ] fake`n 2],tail", Separator: ",", Token: "[1,`n 2]", Cursor: 17, First: 1, Last: 15, Split: true}
	] {
		CommentPosition := 1
		CommentToken := _TOML_DocumentToken(CommentVector.Source, &CommentPosition,
			CommentVector.Separator, &CommentSeparated, &CommentStart, &CommentEnd)
		AssertEqual(CommentVector.Token, CommentToken, "comment skipping preserves the exact decoded token")
		AssertEqual(CommentVector.Cursor, CommentPosition, "the cursor consumes exactly the original line boundary")
		AssertEqual(CommentVector.First, CommentStart, "comments cannot acquire a token span start")
		AssertEqual(CommentVector.Last, CommentEnd, "comments cannot acquire a token span end")
		AssertEqual(CommentVector.Split, CommentSeparated, "only the original top-level separator splits")
	}
	CommentSource := "discarded prefix`n  a # tail`nnext"
	CommentPosition := 20
	AssertEqual("a", _TOML_DocumentToken(CommentSource, &CommentPosition,
		Chr(10), &CommentSeparated, &CommentStart, &CommentEnd))
	AssertEqual(29, CommentPosition, "native comment search starts at the caller's retained cursor")
	AssertEqual(20, CommentStart)
	AssertEqual(20, CommentEnd)
	AssertTrue(CommentSeparated)
}
Test("toml canonical lexer: comment cursor and spans preserve LF CRLF EOF and nested boundaries",
	_TBUI_CommentCursorAndSpans)

_TBUI_CommentQuoteAndContainerOwnership() {
	CommentQuote := Chr(34), CommentLiteral := Chr(39)
	for CommentQuoted in [
		CommentQuote . "literal#[]{}" . CommentQuote,
		CommentLiteral . "literal#[]{}" . CommentLiteral,
		CommentQuote . CommentQuote . CommentQuote . "first#[]`nsecond{}"
			. CommentQuote . CommentQuote . CommentQuote,
		CommentLiteral . CommentLiteral . CommentLiteral . "first#[]`nsecond{}"
			. CommentLiteral . CommentLiteral . CommentLiteral
	] {
		CommentSource := "  " . CommentQuoted . " # fake } ] ' " . CommentQuote . "`nnext"
		CommentPosition := 1
		AssertEqual(CommentQuoted, _TOML_DocumentToken(CommentSource, &CommentPosition,
			Chr(10), &CommentSeparated, &CommentStart, &CommentEnd),
			"quoted hashes and multiline content remain lexical data")
		AssertEqual(3, CommentStart)
		AssertEqual(2 + StrLen(CommentQuoted), CommentEnd)
		AssertEqual("next", SubStr(CommentSource, CommentPosition))
		AssertTrue(CommentSeparated)
	}
	CommentSource := '{ a = "#", # } fake`n b = 2 } remainder'
	CommentPosition := 1
	AssertEqual('{ a = "#", `n b = 2 }', _TOML_DocumentToken(CommentSource,
		&CommentPosition, Chr(0), &CommentSeparated, &CommentStart, &CommentEnd, true),
		"a closer inside a comment cannot end the actual balanced container")
	AssertEqual(" remainder", SubStr(CommentSource, CommentPosition))
	AssertEqual(1, CommentStart)
	AssertEqual(CommentPosition - 1, CommentEnd)
	AssertFalse(CommentSeparated)
	CommentDocument := TOML_ParseDocument("values = [1,# ] fake`n 2] # trailing`nnext = 3`n")
	AssertEqual(2, CommentDocument["values"].Length)
	AssertEqual(1, CommentDocument["values"][1])
	AssertEqual(2, CommentDocument["values"][2])
	AssertEqual(3, CommentDocument["next"])
	for CommentInvalid in ["values = [1,# ]", "values = { a = 1,# }", 'value = "# unterminated']
		AssertThrows(TOML_ParseDocument.Bind(CommentInvalid),
			"comment text cannot repair an unterminated real quote or container")
}
Test("toml canonical lexer: comment skipping preserves quoted data and real container refusal",
	_TBUI_CommentQuoteAndContainerOwnership)


; Comment search must preserve physical LF boundaries beyond an embedded NUL.
_TBUI_CommentEmbeddedNulBoundary() {
	NulCommentSource := "#x" . Chr(0) . "y" . Chr(10) . "next=3" . Chr(10)
	NulCommentPosition := 1
	NulCommentToken := _TOML_DocumentToken(NulCommentSource, &NulCommentPosition,
		Chr(10), &NulCommentSeparated, &NulCommentStart, &NulCommentEnd)
	AssertEqual("", NulCommentToken)
	AssertEqual(6, NulCommentPosition, "the comment's LF remains the original physical separator")
	AssertTrue(NulCommentSeparated)
	AssertEqual(0, NulCommentStart)
	AssertEqual(0, NulCommentEnd)
	NulCommentToken := _TOML_DocumentToken(NulCommentSource, &NulCommentPosition,
		Chr(10), &NulCommentSeparated, &NulCommentStart, &NulCommentEnd)
	AssertEqual("next=3", NulCommentToken, "the record after the NUL-bearing comment is retained")
	AssertEqual(13, NulCommentPosition)
	AssertTrue(NulCommentSeparated)
	AssertEqual(6, NulCommentStart)
	AssertEqual(11, NulCommentEnd)
}
Test("toml canonical lexer: comment search retains the physical LF beyond embedded NUL",
	_TBUI_CommentEmbeddedNulBoundary)


; A current stamp and readonly preparation do not replace the actual boot owner.
_TBUI_CurrentFixtureRequiresRealBootAdmission() {
	Path := _TBUI_NewPath()
	Source := _CMJFixtureCurrentSource(Chr(0xFEFF) . 'layout.ergopti_base = true`nfuture.value = "001" # retained`n')
	Expected := _CMJFixtureCurrentSource(Chr(0xFEFF) . 'layout.ergopti_base = false`nfuture.value = "001" # retained`n')
	Updates := [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }]
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		Prepared := ConfigSchemaPrepareSource(Path)
		AssertTrue(Prepared is Map, "the real source preparation must produce its readonly receipt")
		AssertEqual("current", Prepared["status"])
		AssertEqual(1, Prepared["read_only"])
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "readonly source preparation grants no write admission")
		AssertFalse(TOML_ConfigBatchWrite(Path, Updates), "even a current stamp cannot bypass real boot")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		Stages := 0
		Loop Files, Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		AssertTrue(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, Source))
		AssertTrue(TOML_ConfigBatchWrite(Path, Updates) == 1)
		AssertTrue(FSUtf8ExactMatches(Path, Expected), "only the actual admitted publisher changes the owned leaf")
		Stages := 0
		Loop Files, Path . ".*.tmp"
			Stages += 1
		AssertEqual(0, Stages, "acknowledged publication must retire every owned stage")
	} finally FSDelete(Path)
}
Test("toml config document writer: current source preparation requires real boot admission",
	_TBUI_CurrentFixtureRequiresRealBootAdmission)


; New sections are admitted by one parse of the retained headers. A bulk change
; that introduced many sections paid one complete source parse per section
; (8 s for one tray click on a 830-line config). The writer reports its
; admission parses: a wall-clock ratio against one parse went red on hosted
; runners once the tokenizer got faster, while the 16 ms tick hid the unit.
_TBUI_NewSectionsShareOneAdmission() {
	Source := ""
	Loop 300
		Source .= "[existing.section_" . A_Index . "]`nenabled = true`n`n"
	Updates := []
	Loop 40
		Updates.Push({ Section: "fresh.section_" . A_Index, Key: "enabled", Value: TOML_Bool(true) })
	Result := TOML_BuildConfigDocumentCandidate(Source, Updates, [])
	Parsed := TOML_ParseDocument(Result["content"])
	AssertTrue(TOML_SameValue(Parsed["fresh"]["section_40"]["enabled"], TOML_Bool(true)))
	Loop 40 {
		AssertTrue(InStr(Result["content"], "[fresh.section_" . A_Index . "]`nenabled = true`n") > 0,
			"admitted section " . A_Index . " is written under its own header")
	}
	AssertEqual(1, Result["header_admission_parses"],
		"40 legal new sections are admitted by one shared header parse")
}
Test("toml config document writer: new sections share one header admission (toml-batch-admission)",
	_TBUI_NewSectionsShareOneAdmission)

; A header the source has already closed (a dotted key owns the namespace)
; still falls back to its physical owner while its siblings get headers.
_TBUI_RefusedHeaderFallsBackPerSection() {
	Source := "[a]`nb.c = 1`n"
	Updates := [{ Section: "a.b", Key: "d", Value: 2 }, { Section: "z", Key: "k", Value: 3 }]
	Result := TOML_BuildConfigDocumentCandidate(Source, Updates, [])
	AssertEqual(Chr(0xFEFF) . "[a]`nb.c = 1`nb.d = 2`n[z]`nk = 3`n", Result["content"])
	AssertEqual(3, Result["header_admission_parses"],
		"the refused batch parse is followed by one parse per candidate header")
}
Test("toml config document writer: a closed namespace falls back to its owner (toml-batch-admission)",
	_TBUI_RefusedHeaderFallsBackPerSection)

; An end-anchored regex rescanned the whole growing buffer on every append,
; which spent about a second rendering a 900-line config.
_TBUI_EndsWithLineBreakReadsTheTail() {
	AssertFalse(TOML_EndsWithLineBreak(""))
	AssertFalse(TOML_EndsWithLineBreak("a = 1"))
	AssertFalse(TOML_EndsWithLineBreak("a`n "), "only the final character counts")
	AssertTrue(TOML_EndsWithLineBreak("a = 1`n"))
	AssertTrue(TOML_EndsWithLineBreak("a = 1`r"))
	AssertTrue(TOML_EndsWithLineBreak("a = 1`r`n"))
	AssertTrue(TOML_EndsWithLineBreak("`n"))
}
Test("toml config document writer: the line-break probe reads only the tail (toml-batch-admission)",
	_TBUI_EndsWithLineBreakReadsTheTail)

; Every source renderer appends record by record, so one remaining end-anchored
; probe brings the quadratic render back. The floor proves the scan sees the
; renderers (the helper serves six append sites in three files).
_TBUI_NoEndAnchoredLineBreakRegex() {
	Src := _DriverSourceNoComments()
	Probes := 0, Position := 1
	while Position := InStr(Src, "TOML_EndsWithLineBreak(", true, Position)
		Probes += 1, Position += 1
	AssertTrue(Probes >= 4,Format("the scan must see the line-break probes, found {1}", Probes))
	AssertEqual(0, InStr(Src, ', "[\r\n]$")', true),
		"a growing source buffer must not be probed with an end-anchored regex")
}
Test("toml config document writer: no renderer probes its buffer with an end-anchored regex (toml-batch-admission)",
	_TBUI_NoEndAnchoredLineBreakRegex)
