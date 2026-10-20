; tests/unit/modules/shortcuts/test_caps_word_auto_off_policy.ahk

; ==============================================================================
; MODULE: CapsWord Auto-Off Policy Corpus
; DESCRIPTION:
; Replays _shared/tests/corpus/caps_word/auto_off_vectors.json against the AHK
; port of the CapsWord auto-off policy, the same hand-written vectors the macOS
; and Linux suites replay against _shared/lua/caps_word/auto_off.lua.
; ==============================================================================

#Requires AutoHotkey v2.0




_CWAOP_Corpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\caps_word\auto_off_vectors.json"))
}

_CWAOP_Compile(Corpus, Idle, Terminators, PointerSet, &Reason := "") {
	return CapsWordAutoOffCompile(Map(
		"idle_timeout_seconds", Idle,
		"terminators", Terminators,
		"pointer", Corpus["pointer_sets"][PointerSet]), Corpus["pointer_kinds"], &Reason)
}

_CWAOP_Join(List) {
	Out := ""
	for Item in List
		Out .= (A_Index == 1 ? "" : ",") . Item
	return Out
}

_CWAOP_CompileVectors() {
	Corpus := _CWAOP_Corpus()
	AssertEqual(13, Corpus["compile"].Length, "complete compile vectors")
	for Row in Corpus["compile"] {
		Policy := _CWAOP_Compile(Corpus, Row["idle"], Row["terminators"], Row["pointer"], &Reason)
		if Row["valid"] {
			Assert(Policy is Map, Row["name"] . " must compile, refused: " . Reason)
			AssertEqual(Row["idle_ms"], CapsWordAutoOffIdleDelayMs(Policy), Row["name"] . " delay")
		} else {
			AssertEqual("", Policy, Row["name"] . " must be refused")
			AssertEqual(Row["reason"], Reason, Row["name"] . " reason")
		}
	}
	AssertEqual("", CapsWordAutoOffCompile(Map("idle_timeout_seconds", 0, "terminators", [],
		"pointer", Corpus["pointer_sets"]["all_true"]), [], &Reason), "no declared pointer kind")
	AssertEqual("invalid_pointer_kinds", Reason)
	AssertEqual("", CapsWordAutoOffCompile("", Corpus["pointer_kinds"], &Reason), "no settings")
	AssertEqual("invalid_settings", Reason)
}
Test("caps-word auto-off policy: compiles valid settings and names each refusal", _CWAOP_CompileVectors)

_CWAOP_TextVectors() {
	Corpus := _CWAOP_Corpus()
	AssertEqual(26, Corpus["text"].Length, "complete text vectors")
	for Row in Corpus["text"] {
		Policy := _CWAOP_Compile(Corpus, 0, Row["terminators"], "all_true")
		AssertEqual(Row["expected"], CapsWordAutoOffEndsOnText(Policy, Row["text"]),
			Format("U+{:04X}… with [{2}]", Row["text"] == "" ? 0 : Ord(Row["text"]), _CWAOP_Join(Row["terminators"])))
	}
}
Test("caps-word auto-off policy: a typed payload ends CapsWord only through a checked delimiter", _CWAOP_TextVectors)

_CWAOP_KeyVectors() {
	Corpus := _CWAOP_Corpus()
	for Row in Corpus["keys"] {
		Policy := _CWAOP_Compile(Corpus, 0, Row["terminators"], "all_true")
		AssertEqual(Row["expected"], CapsWordAutoOffEndsOnKey(Policy, Row["key"]), Row["key"])
	}
	Policy := _CWAOP_Compile(Corpus, 0, ["space"], "all_true")
	for Key in Corpus["unknown_keys"]
		AssertThrows(() => CapsWordAutoOffEndsOnKey(Policy, Key), "unknown key '" . Key . "' must throw")
}
Test("caps-word auto-off policy: native keys answer by delimiter key, unknown keys throw", _CWAOP_KeyVectors)

_CWAOP_PointerVectors() {
	Corpus := _CWAOP_Corpus()
	for Row in Corpus["pointer"] {
		Policy := _CWAOP_Compile(Corpus, 0, [], Row["pointer"])
		AssertEqual(Row["expected"], CapsWordAutoOffEndsOnPointer(Policy, Row["kind"]),
			Row["pointer"] . ":" . Row["kind"])
	}
	Policy := _CWAOP_Compile(Corpus, 0, [], "all_true")
	for Kind in Corpus["unknown_kinds"]
		AssertThrows(() => CapsWordAutoOffEndsOnPointer(Policy, Kind), "undeclared kind '" . Kind . "' must throw")
}
Test("caps-word auto-off policy: pointer kinds answer, undeclared kinds throw", _CWAOP_PointerVectors)

_CWAOP_IdleVectors() {
	Corpus := _CWAOP_Corpus()
	for Row in Corpus["idle"] {
		Policy := _CWAOP_Compile(Corpus, Row["idle"], [], "all_true")
		AssertEqual(Row["expected"], CapsWordAutoOffIdleExpired(Policy, Row["last"], Row["now"]),
			Format("{1} s from {2} to {3}", Row["idle"], Row["last"], Row["now"]))
	}
}
Test("caps-word auto-off policy: the delay expires only once whole, never at 0", _CWAOP_IdleVectors)

_CWAOP_WithTerminatorVectors() {
	Corpus := _CWAOP_Corpus()
	for Row in Corpus["with_terminator"] {
		Out := CapsWordAutoOffWithTerminator(Row["list"], Row["key"], Row["checked"], &Reason)
		Assert(Out is Array, Row["key"] . " refused: " . Reason)
		AssertEqual(_CWAOP_Join(Row["expected"]), _CWAOP_Join(Out), Row["key"])
	}
	for Row in Corpus["with_terminator_refusals"] {
		AssertEqual("", CapsWordAutoOffWithTerminator(Row["list"], Row["key"], Row["checked"], &Reason), Row["reason"])
		AssertEqual(Row["reason"], Reason, Row["reason"])
	}
}
Test("caps-word auto-off policy: a checkbox change is stored in catalogue order", _CWAOP_WithTerminatorVectors)

_CWAOP_TerminatorRows() {
	Corpus := _CWAOP_Corpus()
	Drawn := []
	for Row in CapsWordAutoOffTerminatorRows() {
		if Row.Has("separator") {
			Drawn.Push("-")
			continue
		}
		Drawn.Push(Row["key"])
		AssertEqual("terminators.label_" . Row["key"], Row["label_key"], Row["key"] . " label")
	}
	AssertEqual(_CWAOP_Join(Corpus["terminator_rows"]), _CWAOP_Join(Drawn), "catalogue order and separators")
}
Test("caps-word auto-off policy: the delimiter rows are the generated catalogue", _CWAOP_TerminatorRows)
