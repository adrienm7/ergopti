; tests/meta/test_suite_unique_includes.ahk

; ==============================================================================
; MODULE: Test Runner Include Uniqueness
; DESCRIPTION: Keep one explicit registration site for each included source.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSUI_NoRepeatedIncludeDirectives() {
	Source := FileRead(A_ScriptDir . "\run_all.ahk", "UTF-8")
	Seen := Map()
	Seen.CaseSense := "On"
	Duplicates := []
	for Line in StrSplit(Source, "`n") {
		if !RegExMatch(Trim(Line), "^#Include\s+(.+)$", &Directive)
			continue
		Target := Directive[1]
		if Seen.Has(Target)
			Duplicates.Push(Target)
		Seen[Target] := true
	}
	Assert(Seen.Count > 0, "the runner scan must inspect real include directives")
	AssertEqual(0, Duplicates.Length, "the runner must not repeat exact include targets")
}
Test("AHK suite: include directives are unique (suite-unique-includes)", _TSUI_NoRepeatedIncludeDirectives)
