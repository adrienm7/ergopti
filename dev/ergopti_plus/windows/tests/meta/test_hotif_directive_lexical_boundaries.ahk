; tests/meta/test_hotif_directive_lexical_boundaries.ahk

; ==============================================================================
; MODULE: HotIf Directive Lexical Boundary Tests
; DESCRIPTION:
; Disabled directives and literal parentheses cannot alter the live call graph.
; ==============================================================================

#Requires AutoHotkey v2.0

_HDLB_SourceCalls(Kind) {
	global _HGBS_HOTIF_PARENTS
	SavedParents := _HGBS_HOTIF_PARENTS
	try {
		switch Kind {
			case "closing literal":
				Source := '#HotIf (`n FixtureFirst(")")`n && FixtureSecond()`n)'
			case "opening literal":
				Source := '#HotIf FixtureFirst("(")`nFixtureOutside()'
			case "block directive":
				Source := "/*`n#HotIf FixtureDisabled()`n*/`n#HotIf FixtureFirst()"
			case "string directive":
				Source := 'Value := "`n(`n#HotIf FixtureDisabled()`n)"`n#HotIf FixtureFirst()'
			case "reset":
				Source := "#HotIf FixtureFirst()`n#HotIf`nFixtureOutside()"
		}
		Calls := _HGBS_HotIfFunctions(Source)
		AssertTrue(Calls.Has("FixtureFirst"), "the live directive must remain reachable")
		AssertEqual(Kind == "closing literal" ? 2 : 1, Calls.Count,
			"the graph must include exactly the calls inside executable directive boundaries")
		if Kind == "closing literal"
			AssertTrue(Calls.Has("FixtureSecond"), "a quoted parenthesis cannot hide the next multiline call")
		AssertFalse(Calls.Has("FixtureDisabled"))
		AssertFalse(Calls.Has("FixtureOutside"))
	} finally _HGBS_HOTIF_PARENTS := SavedParents
}

for Kind in ["closing literal", "opening literal", "block directive", "string directive", "reset"]
	Test("HotIf graph: " . Kind . " preserves lexical boundaries (hotif-directive-boundaries)",
		_HDLB_SourceCalls.Bind(Kind))
