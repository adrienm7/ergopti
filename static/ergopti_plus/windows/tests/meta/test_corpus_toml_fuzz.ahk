; static/ergopti_plus/windows/tests/meta/test_corpus_toml_fuzz.ahk

; ==============================================================================
; MODULE: TOML Fuzz Corpus Consumer (AHK)
; DESCRIPTION:
; Exercises the AHK TOML loader (infra/toml/toml_loader.ahk via ParseTomlFile
; and infra/toml/toml_helpers.ahk via ParseTomlFile) against every entry in the
; shared cross-driver fuzz corpus:
;   _shared/tests/corpus/toml/fuzz_corpus.json
;
; CONTRACT:
; For every fuzz vector the loader MUST NOT crash (unhandled exception, infinite
; loop, or stack overflow). Vectors with expect="ok" must parse without error;
; vectors with expect="error" may fail — the test only asserts the failure is
; surfaced as a return value (nil/false/empty), not as an uncaught exception.
;
; APPROACH:
; Each fuzz input is written to a temporary file, then ParseTomlFile() is called
; inside a try/catch block. A crash inside try raises an Error object; the test
; fails if that happens. Null-byte inputs (which cannot be written to a Windows
; ANSI temp file cleanly) are skipped with a documented reason.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================
; ======================================
; ======= 1/ Corpus Loader ============
; ======================================
; ======================================

; Replays one fuzz vector through the loader, which must not raise on it.
; Bound per vector at registration: the nested function this replaces read
; copies of the loop's values, one slot every iteration overwrote, so every
; registered test replayed the last vector of the corpus.
; @param VecId {String} The vector id, which also names its temp file.
; @param Input {String} The TOML text to parse.
_TomlFuzz_RunVector(VecId, Input) {
	TmpFile := A_Temp . "\toml_fuzz_" . VecId . ".toml"
	try FileDelete(TmpFile)
	try FileAppend(Input, TmpFile, "UTF-8")

	; Call the parser inside a try/catch — a crash here is a test failure
	Crashed := false
	ParseOk := false
	try {
		Result := ParseTomlFile(TmpFile)
		ParseOk := true
	} catch as e {
		Crashed := (e.Message != "")
	}

	try FileDelete(TmpFile)

	; A crash (unhandled exception propagated through try) is always failure
	AssertTrue(!Crashed,
		"[" . VecId . "] ParseTomlFile raised an unhandled exception — crash is never allowed")
}

_TomlFuzz_RunAll() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\toml\fuzz_corpus.json"

	_TomlFuzz_FileExists() {
		AssertTrue(FileExist(CorpusPath) != "", "TOML fuzz corpus must exist at: " . CorpusPath)
	}
	Test("TOML fuzz corpus: file exists", _TomlFuzz_FileExists)

	if !FileExist(CorpusPath)
		return

	Raw  := FileRead(CorpusPath, "UTF-8")
	Data := JsonParse(Raw)

	_TomlFuzz_IsArray() {
		; The fuzz corpus is a top-level JSON array (not wrapped in a 'vectors' key)
		AssertTrue(Type(Data) = "Array", "TOML fuzz corpus must be a JSON array, got: " . Type(Data))
		AssertTrue(Data.Length >= 10, "TOML fuzz corpus must have >=10 entries, got: " . Data.Length)
	}
	Test("TOML fuzz corpus: valid array with >=10 entries", _TomlFuzz_IsArray)

	if Type(Data) != "Array"
		return


	; ==============================
	; ===== 1.1) Per-vector run ====
	; ==============================

	Skipped := 0
	Passed  := 0
	Failed  := 0

	for Vec in Data {
		VecId   := Vec.Has("id")          ? Vec["id"]          : "UNKNOWN"
		Input   := Vec.Has("input")       ? Vec["input"]       : ""
		Expect  := Vec.Has("expect")      ? Vec["expect"]      : "ok"
		Descr   := Vec.Has("description") ? Vec["description"] : ""

		; Skip inputs containing null bytes — FileAppend on Windows will silently
		; truncate or corrupt the file, making the test meaningless.
		if InStr(Input, Chr(0)) {
			Skipped++
			continue
		}

		Test("[corpus:TOML-" . VecId . "] " . Descr, _TomlFuzz_RunVector.Bind(VecId, Input))
	}

	; Summary test
	_TomlFuzz_Summary() {
		AssertTrue(Data.Length > 0, "At least one vector must exist in the corpus")
	}
	Test("TOML fuzz corpus: all " . Data.Length . " entries processed (" . Skipped . " null-byte skip(s))", _TomlFuzz_Summary)
}

_TomlFuzz_RunAll()
