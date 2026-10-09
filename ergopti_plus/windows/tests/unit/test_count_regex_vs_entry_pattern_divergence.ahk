; tests/unit/test_count_regex_vs_entry_pattern_divergence.ahk

; ==============================================================================
; MODULE: Count Regex vs Registration Pattern Divergence Test
; DESCRIPTION:
; Behavioral regression for finding count-regex-vs-entry-pattern-divergence.
;
; The displayed-count helper used a looser regex (^key =) than the patterns the
; loaders actually register with: the full inline-table _HOTSTRING_ENTRY_PATTERN
; and the simple key="value" form (_HOTSTRING_SIMPLE_ENTRY_PATTERN). A line like
; `foo = 123` (no quotes, not an inline table) registers nothing yet was counted,
; so displayed counts could exceed the registered/cached rows. The fix counts a
; line only when it matches one of the two registration shapes.
;
; This builds a section with one full entry + one simple key="value" entry + one
; non-conforming `foo = 123` line and asserts the count is 2 (was 3 before the
; fix). toml_loader.ahk is in the run_all include graph and CountTomlSection has
; no OS/COM/hotkey side effects, so this is a safe behavioral headless-unit test.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ Count matches registration shapes only =======
; =========================================================
; =========================================================

_CRVEPD_FullEntry(Trigger, Output) {
	return Chr(34) . Trigger . Chr(34)
		. " = { output = " . Chr(34) . Output . Chr(34)
		. ", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n"
}

_CRVEPD_CountMatchesRegistration() {
	TmpPath := A_ScriptDir . "\crvepd_count.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}

	; Section with three `key =` lines, but only two are actually registerable:
	;   1. a full inline-table entry          -> registered
	;   2. a simple key="value" entry         -> registered (LoadExtTomlFile path)
	;   3. a bare numeric assignment foo = 123 -> registered by NEITHER loader
	Content := "[[mix]]`r`n"
		. _CRVEPD_FullEntry("aaa", "alpha")
		. Chr(34) . "bbb" . Chr(34) . " = " . Chr(34) . "beta" . Chr(34) . "`r`n"
		. "foo = 123`r`n"
	FileAppend(Content, TmpPath, "UTF-8")

	AssertEqual(2, CountTomlSection("x", "mix", TmpPath),
		"only the full inline-table entry and the simple key=value entry are registered; the bare `foo = 123` line must not be counted")
	AssertEqual(2, CountTomlHotstrings("x", TmpPath),
		"the file total must equal the 2 registerable rows, never the looser 3 the old `key =` regex matched")

	FileDelete(TmpPath)
}
Test("toml_loader: count helpers only count registerable entry shapes (count-regex-vs-entry-pattern-divergence)",
	_CRVEPD_CountMatchesRegistration)
