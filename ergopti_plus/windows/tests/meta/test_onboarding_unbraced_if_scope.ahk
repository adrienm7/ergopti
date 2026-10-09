; tests/meta/test_onboarding_unbraced_if_scope.ahk

; ==============================================================================
; MODULE: Regression — no brace-less if in the onboarding module owns two
;         statements (onboarding-unbraced-if-scope)
; DESCRIPTION:
; _OnbWeb_Finish read:
;
;     if (answers.Has("magic_key") && answers["magic_key"] != "")
;         _ob_magic_key := answers["magic_key"]
;         _ob_magic_key_explicit := true
;
; In AHK v2 a brace-less `if` takes exactly ONE statement, so the provenance flag
; executed unconditionally — the wizard marked the magic key as "explicitly
; chosen by the user" for a payload that carried none, while the indentation
; claimed the opposite.
;
; ROOT CAUSE ENCODED: indentation-implied block without braces. A substring
; check cannot see it, since the statement is present, only outside the branch.
; This file asserts the SCOPE instead, and does it for the whole onboarding
; module rather than for the one line that was wrong (that handler now takes
; manifest answers and no longer has the branch).
;
; SCOPE: source-level over ui/onboarding — the wizard registers a WebView2 window
; at open time and is outside the headless include graph.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Helpers ===============================================
; ==================================================================
; ==================================================================

; The leading whitespace of a line, compared verbatim (the module indents with
; tabs throughout, so string equality is the honest comparison).
_OUIS_Indent(Line) {
	RegExMatch(Line, "^([ \t]*)", &M)
	return M[1]
}

; Index of the next line that carries code, skipping blanks and full-line
; comments. 0 when the end of the source is reached.
_OUIS_NextCodeLine(Lines, Start) {
	Idx := Start
	while (Idx <= Lines.Length) {
		Line := Trim(Lines[Idx], " `t`r")
		if (Line != "" and SubStr(Line, 1, 1) != ";")
			return Idx
		Idx += 1
	}
	return 0
}





; ==================================================================
; ==================================================================
; ======= 2/ The class: no brace-less if owns two statements =======
; ==================================================================
; ==================================================================

; The defect is not "this line"; it is "an `if` whose indentation promises more
; than v2 delivers". Scanning the module makes the next one fail here instead of
; shipping, which is the only reason a one-line fix deserves a test at all.
_OUIS_NoUnbracedIfOwnsTwoStatements() {
	Src := _DriverDirConcat("ui/onboarding")
	Assert(Src != "", "ui/onboarding sources must be readable for the scope scan")

	Lines := StrSplit(Src, "`n", "`r")
	Scanned := 0
	Offenders := ""
	for I, Line in Lines {
		if !RegExMatch(Line, "^([ \t]*)if\s*\(.*\)[ \t]*$", &M)
			continue
		Scanned += 1
		Ind := M[1]

		J := _OUIS_NextCodeLine(Lines, I + 1)
		if (J == 0)
			continue
		Inner := _OUIS_Indent(Lines[J])
		if (StrLen(Inner) <= StrLen(Ind))
			continue

		K := _OUIS_NextCodeLine(Lines, J + 1)
		if (K == 0)
			continue
		if (_OUIS_Indent(Lines[K]) != Inner)
			continue
		if RegExMatch(Trim(Lines[K], " `t`r"), "^(else|\}|,|\.|&&|\|\||\))")
			continue

		Offenders .= "`n    " . Trim(Lines[I], " `t`r") . "  ->  " . Trim(Lines[K], " `t`r")
	}

	Assert(Scanned >= 5,
		"the scan must actually reach brace-less `if` lines (found " . Scanned . ") — a scan that matches nothing cannot fail")
	Assert(Offenders == "",
		"a brace-less `if` is followed by TWO statements at the same deeper indentation, so only the first one is conditional in AHK v2 while the indentation says both are. Brace the block:" . Offenders)
}
Test("meta onboarding-unbraced-if-scope: no brace-less if owns two indented statements",
	_OUIS_NoUnbracedIfOwnsTwoStatements)
