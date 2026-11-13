; tests/meta/infra/logger/test_logger_private_label.ahk

; ==============================================================================
; MODULE: Private Label Twin (Windows)
; DESCRIPTION:
; LoggerMaskUserName is the AutoHotkey twin of _shared/diagnostics/engine/private_label.lua
; (item 139): its placeholder is the redaction policy's, it refuses a value that is
; no name, and no TOML loader log line prints a category or a file in clear text.
; ==============================================================================

#Requires AutoHotkey v2.0




_PL_RedactionPolicy() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\diagnostics\data\redaction.json", "UTF-8"))
}

TestPL_PlaceholderIsThePolicys() {
	Placeholder := _PL_RedactionPolicy()["config_name_placeholder"]
	AssertEqual(Placeholder, LoggerUserNamePlaceholder())
	AssertEqual(Placeholder, LoggerMaskUserName("my_personal_pack"))
	AssertEqual(Placeholder, LoggerMaskUserName(""))
}
Test("private label: the placeholder is the redaction policy's (private-label-twin)", TestPL_PlaceholderIsThePolicys)

TestPL_RefusesWhatIsNoName() {
	AssertThrows(() => LoggerMaskUserName(3), "a number is no name")
	AssertThrows(() => LoggerMaskUserName(Map()), "an object is no name")
}
Test("private label: a value that is no name is refused (private-label-twin)", TestPL_RefusesWhatIsNoName)

; Reads every TomlLoader line of the two loaders; the wrappers are removed first,
; so a bare variable left over is one that reaches the log in clear text.
_PL_CountCheckedLines(FunctionName) {
	Body := _DriverFuncBody(FunctionName)
	Assert(Body != "", "the loader must exist: " . FunctionName)
	Lines := 0, Position := 1
	Pattern := 's)Logger\w+\("TomlLoader",\s*"[^"\n]*"(.*?)\)\s*\n'
	while RegExMatch(Body, Pattern, &Found, Position) {
		Arguments := RegExReplace(Found[1], "(HotstringCategoryLogName|LoggerMaskUserName)\(\w+\)", "")
		AssertFalse(RegExMatch(Arguments, "\b(CategoryName|CategoryLabel|FilePath)\b"),
			"a TomlLoader line prints a user-chosen name in clear text: " . Found[0])
		Lines += 1
		Position := Found.Pos + Found.Len
	}
	return Lines
}

TestPL_LoaderLinesAreMasked() {
	Section := _PL_CountCheckedLines("LoadHotstringsSection")
	Assert(Section >= 5, "the section loader's lines must be read, found " . Section)
	Extension := _PL_CountCheckedLines("LoadExtTomlFile")
	Assert(Extension >= 3, "the extension loader's lines must be read, found " . Extension)
}
Test("private label: the TOML loaders print no name in clear text (private-label-twin)", TestPL_LoaderLinesAreMasked)
