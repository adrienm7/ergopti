; tests/support/native_cli_diagnostics.ahk

; ==============================================================================
; MODULE: Native CLI Test Diagnostics
; DESCRIPTION:
; Preserves actual Node assertion messages at the first-line annotation boundary
; and retains the original bounded child capture as canonical TAP comments.
; ==============================================================================

; Node prints its assertion header after bootstrap frames; surface its actual
; message in the single-line failure annotation and retain the bounded capture.
NativeCliFailureHeadline(Output) {
	static MAX_HEADLINE_CHARS := 768
	Lines := StrSplit(StrReplace(Output, "`r", ""), "`n")
	Headline := "", FoundAssertion := false
	for _, Line in Lines {
		if !FoundAssertion {
			if RegExMatch(Line, "^\s*AssertionError(?:\s+\[[^\]]+\])?:") {
				Headline := Trim(Line)
				FoundAssertion := true
			}
			continue
		}
		if RegExMatch(Line, "^\s+at\s")
			break
		if Trim(Line) != ""
			Headline .= " " . Trim(Line)
		if StrLen(Headline) >= MAX_HEADLINE_CHARS
			break
	}
	if !FoundAssertion {
		for _, Line in Lines {
			if Trim(Line) != "" {
				Headline := Trim(Line)
				break
			}
		}
	}
	return SubStr(Headline, 1, MAX_HEADLINE_CHARS)
}

/** Persists each captured child line without letting it become a TAP record. */
NativeCliPrintFailureOutput(Context, Output) {
	for _, Line in StrSplit(StrReplace(Output, "`r", ""), "`n")
		_TestPrint("# " . Context . " output: " . Line)
}
