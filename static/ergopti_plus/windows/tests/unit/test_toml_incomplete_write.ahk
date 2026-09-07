; tests/unit/test_toml_incomplete_write.ahk

; ==============================================================================
; MODULE: TOML Incomplete-Source Write Tests
; DESCRIPTION:
; Read recovery may retain valid neighbors, but a whole-file writer must never
; publish a partial parse. Refusal is local to the current source snapshot.
; ==============================================================================

#Requires AutoHotkey v2.0

_TIW_RefusePartial(BuildOnly, AtEof) {
	global _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED
	OldSink := _LOGGER_TEST_SINK
	OldErrorEnabled := _LOGGER_ERROR_ENABLED
	Lines := []
	Path := _CTU_NewPath()
	Prefix := '[sample]`nkept = "yes"`nitems = [`n"kept",`n'
	Tail := '[later]`nflag = true`n'
	Original := Prefix . (AtEof ? "" : Tail)
	Updates := [{ Section: "sample", Key: "other", Value: 2 }]
	try {
		_LOGGER_ERROR_ENABLED := true
		LoggerSetTestSink((Line) => Lines.Push(Line))
		AssertTrue(FSWrite(Path, Original))
		Read := TOML_ParseFreshFile(Path)
		AssertEqual("yes", Read["sample"]["kept"], "ordinary readers retain valid neighbors")
		AssertFalse(Read["sample"].Has("items"))
		if !AtEof
			AssertTrue(Read["later"]["flag"])
		Result := BuildOnly ? TOML_BuildUpdatedContent(Path, Updates) : TOML_BatchWrite(Path, Updates)
		AssertEqual(Original, FSRead(Path), "a partial parse must never replace the source file")
		if BuildOnly {
			AssertTrue(Result is Map)
			AssertEqual("error", Result["status"], "a partial candidate must not be reported as successful")
			AssertEqual("", Result["content"])
		} else {
			AssertFalse(Result, "the writer must report incomplete-source refusal")
		}
		Reported := false
		for Line in Lines {
			if InStr(Line, "[ERROR] [TomlWrite]") && InStr(Line, Path) {
				AssertContains(Line, "discarded 1 unterminated array(s)")
				AssertContains(Line, "Repair the source before saving")
				Reported := true
			}
		}
		AssertTrue(Reported, "source refusal must emit an actionable diagnostic")

		; Repair the same path: refusal must not become a stale path-wide latch.
		Valid := Prefix . "]`n" . Tail
		AssertTrue(FSWrite(Path, Valid))
		if BuildOnly {
			Result := TOML_BuildUpdatedContent(Path, Updates)
			AssertEqual("ok", Result["status"])
			AssertEqual(Valid, FSRead(Path), "building repaired content must remain detached")
			AssertTrue(FSWrite(Path, Result["content"]))
		} else {
			AssertTrue(TOML_BatchWrite(Path, Updates))
		}
		Read := TOML_ParseFreshFile(Path)
		AssertEqual(1, Read["sample"]["items"].Length)
		AssertEqual("kept", Read["sample"]["items"][1])
		AssertEqual("yes", Read["sample"]["kept"])
		AssertEqual(2, Read["sample"]["other"])
		AssertTrue(Read["later"]["flag"])
	} finally {
		LoggerSetTestSink(OldSink)
		_LOGGER_ERROR_ENABLED := OldErrorEnabled
		FSDelete(Path)
	}
}

_TIW_FreshDiagnostics() {
	Source := '[first]`na = [`n"private-value",`n[second]`nb = [`n"private-value",`n'
	Discarded := 99
	Parsed := _ParseTomlFileImpl("incomplete-diagnostic-fixture", false, false, Source, true, &Discarded)
	AssertEqual(2, Discarded, "header recovery and EOF each report one discarded array")
	AssertEqual(2, Parsed.Count)
	AssertFalse(Parsed["first"].Has("a"))
	AssertFalse(Parsed["second"].Has("b"))
	Parsed := _ParseTomlFileImpl("incomplete-diagnostic-fixture", false, false,
		'[first]`na = [1]`n', true, &Discarded)
	AssertEqual(0, Discarded, "fresh diagnostics must reset on every parse")
	AssertEqual(1, Parsed["first"]["a"][1])
}
Test("TOML: fresh parse counts every discarded array locally (toml-incomplete-write-diagnostics)",
	_TIW_FreshDiagnostics)
for BuildOnly in [false, true] {
	for AtEof in [false, true]
		Test("TOML: " . (BuildOnly ? "build" : "write") . " refuses incomplete array at "
			. (AtEof ? "EOF" : "next header") . " (toml-incomplete-write)",
			_TIW_RefusePartial.Bind(BuildOnly, AtEof))
}
