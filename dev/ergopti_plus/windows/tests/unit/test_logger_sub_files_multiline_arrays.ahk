; tests/unit/test_logger_sub_files_multiline_arrays.ahk

; ==============================================================================
; MODULE: Logger Sub-file Router — Multi-line TOML Array Tests
; DESCRIPTION:
; Behavioural regression guard for logger-subfiles-multiline-array-truncated.
;
; _LoggerLoadSubFilesToml ended a multi-line TOML array as soon as the RAW line
; contained a "]". Every routing pattern in sub_files.toml is tag-shaped by that
; file's own authoring rules, which say to prefer tag-based patterns, so the very
; first value line of the layout array is the quoted string [LayoutShift] — and
; it carries a "]" inside its own quotes. The accumulator closed the array on
; that first element, and the remaining values fell through to the key-value
; branch, matched none of its three RegExes, and were discarded.
;
; The damage was total and silent: the entry was still created with a non-empty
; tag list, the sub-file was still created, and _LoggerFanOut still matched the
; ONE surviving pattern — so a dropped pattern is indistinguishable from a topic
; that had no traffic. Measured over 15 days of production logs, 1309 of 1867
; routable lines never reached a sub-file, and ErgoptiPlus_dispatch.log was
; structurally guaranteed to stay empty forever because its only surviving
; pattern, "[Dispatch]", matches no tag the driver emits.
;
; These tests run the REAL parser against the REAL shipped TOML (test_stubs.ahk
; resolves _SharedDir), so they fail on the truncating parser and pass on the
; fixed one. The structural assertion additionally covers the platforms branch,
; which carries the identical raw-line test and is dormant today only because
; every platforms array in the shipped file happens to fit on one line.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

; Returns the parsed sub-file entry with the given filename, or "" when absent.
_LSFM_Entry(Entries, Name) {
	for _, E in Entries {
		if (E is Map and E.Has("name") and E["name"] == Name)
			return E
	}
	return ""
}

; True when Tag appears in the entry's pattern list.
_LSFM_HasTag(Entry, Tag) {
	for _, T in Entry["tags"] {
		if (T == Tag)
			return true
	}
	return false
}





; ===================================================
; ===================================================
; ======= 2/ Every pattern survives the parse =======
; ===================================================
; ===================================================

_LSFM_MultiLineArrayKeepsEveryPattern() {
	global LOGGER_SUB_FILES, _SharedDir
	TomlPath := _SharedDir . "\modules\logger\sub_files.toml"
	Assert(FileExist(TomlPath) != "",
		"prerequisite: the shipped sub_files.toml must be readable, otherwise the parser silently uses LOGGER_SUB_FILES_FALLBACK and this test proves nothing")

	Save := LOGGER_SUB_FILES
	try {
		LOGGER_SUB_FILES := []
		_LoggerLoadSubFilesToml("")

		Gestures := _LSFM_Entry(LOGGER_SUB_FILES, "ErgoptiPlus_gestures.log")
		Assert(Gestures != "", "the parser must produce an ErgoptiPlus_gestures.log entry")
		Assert(Gestures["tags"].Length == 2,
			"prerequisite: the SHIPPED TOML was parsed, not the hardcoded fallback (the fallback declares a single gestures pattern, the TOML declares two)")

		Layout := _LSFM_Entry(LOGGER_SUB_FILES, "ErgoptiPlus_layout.log")
		Assert(Layout != "", "the parser must produce an ErgoptiPlus_layout.log entry")
		Assert(Layout["tags"].Length >= 3,
			"a multi-line TOML patterns array must yield EVERY pattern (got " . Layout["tags"].Length . "): a value that contains a closing bracket inside its own quotes must not terminate the array (logger-subfiles-multiline-array-truncated)")
		Assert(_LSFM_HasTag(Layout, "[LayoutCaps]"),
			"the SECOND value of the layout patterns array must survive the parse: it is the first casualty when the array terminator is tested on the raw line")
		Assert(_LSFM_HasTag(Layout, "[LayoutAltGr]"),
			"the LAST value of the layout patterns array must survive the parse")

		Dispatch := _LSFM_Entry(LOGGER_SUB_FILES, "ErgoptiPlus_dispatch.log")
		Assert(Dispatch != "", "the parser must produce an ErgoptiPlus_dispatch.log entry")
		Assert(_LSFM_HasTag(Dispatch, "[TomlLoader]"),
			"[TomlLoader] must survive the parse: it is the only dispatch pattern the driver actually emits, so losing it leaves ErgoptiPlus_dispatch.log permanently empty while looking like a topic with no traffic")
	} finally {
		LOGGER_SUB_FILES := Save
	}
}
Test("logger: a multi-line TOML patterns array keeps every pattern (logger-subfiles-multiline-array-truncated)", _LSFM_MultiLineArrayKeepsEveryPattern)





; ======================================================
; ======================================================
; ======= 3/ No raw-line terminator test remains =======
; ======================================================
; ======================================================

; The behavioural test above can only see the patterns branch. The platforms
; branch carries the identical terminator test and is dormant purely because no
; shipped platforms array spans two lines yet — so pin the root cause itself:
; neither branch may test the RAW fragment for a closing bracket.
_LSFM_NoRawBracketTerminatorTest() {
	Body := _DriverFuncBody("_LoggerLoadSubFilesToml")
	Assert(Body != "", "_LoggerLoadSubFilesToml() must exist in the driver source")

	Assert(RegExMatch(Body, 'InStr\(\s*(Line|Fragment)\s*,\s*"\]"\s*\)') == 0,
		"no array-terminator test may run against the raw line or fragment: every tag-shaped pattern carries a closing bracket inside its own quoted string, so the quoted values must be stripped before the terminator is looked for (logger-subfiles-multiline-array-truncated)")
	Assert(InStr(Body, "_ArrayIsClosed(") > 0,
		"both the patterns and the platforms branch must decide array termination through the shared quote-stripping helper, so the dormant platforms branch cannot become the next casualty")
}
Test("logger: array termination is decided outside quoted values, in both branches (logger-subfiles-multiline-array-truncated)", _LSFM_NoRawBracketTerminatorTest)
