; tests/meta/test_runner_only_filter.ahk

; ==============================================================================
; MODULE: Test Runner --only Filter Meta Test
; DESCRIPTION:
; Behaviour guard for the test runner's ``--only <substr>`` selection helper
; (_FilterMatches in test_framework.ahk). The filter lets a developer replay a
; single failing test by a distinctive name slug instead of running the whole
; ~2300-case suite — essential on a slow machine where the full run otherwise
; exceeds the headless watchdog.
;
; These are real behaviour tests: they call _FilterMatches directly and assert
; its return value, rather than scanning the runner's source text.
; ==============================================================================

#Requires AutoHotkey v2.0


_TROF_EmptyFilterMatchesEverything() {
	Assert(_FilterMatches("anything at all", ""), "an empty --only filter must select every test")
}
Test("runner --only: empty filter selects every test", _TROF_EmptyFilterMatchesEverything)

_TROF_SubstringIsCaseInsensitive() {
	Assert(_FilterMatches("PrefixWatcher: feeds the LLM bridge", "prefixwatcher"),
		"--only must match a name substring case-insensitively")
	Assert(_FilterMatches("KL_Stop flushes before suspend", "Stop"),
		"--only must match an interior substring, not just a prefix")
}
Test("runner --only: matches a case-insensitive interior substring", _TROF_SubstringIsCaseInsensitive)

_TROF_NonMatchIsExcluded() {
	Assert(!_FilterMatches("string utils encode round-trip", "no-such-slug"),
		"--only must exclude a test whose name does not contain the filter")
}
Test("runner --only: a non-matching test is excluded", _TROF_NonMatchIsExcluded)
