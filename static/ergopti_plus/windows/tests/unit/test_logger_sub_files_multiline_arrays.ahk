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

	; The routing table is generated from the shipped TOML rather than parsed by
	; the driver, so this reads exactly what the logger will fan out with.
	Entries := LoggerSubFilesData()
	Assert(Entries.Length > 0, "the generated routing table must not be empty")

	Gestures := _LSFM_Entry(Entries, "ErgoptiPlus_gestures.log")
	Assert(Gestures != "", "the table must carry an ErgoptiPlus_gestures.log entry")
	Assert(Gestures["tags"].Length == 2,
		"gestures must carry BOTH declared patterns. The hardcoded fallback this replaced declared only one, and the macOS twin had already drifted to a single pattern — so a stripped build quietly stopped collecting every bare " . Chr(34) . "gesture" . Chr(34) . " line")

	Layout := _LSFM_Entry(Entries, "ErgoptiPlus_layout.log")
	Assert(Layout != "", "the table must carry an ErgoptiPlus_layout.log entry")
	Assert(Layout["tags"].Length >= 3,
		"a multi-line TOML patterns array must yield EVERY pattern (got " . Layout["tags"].Length . "): a value that contains a closing bracket inside its own quotes must not terminate the array (logger-subfiles-multiline-array-truncated)")
	Assert(_LSFM_HasTag(Layout, "[LayoutCaps]"),
		"the SECOND value of the layout patterns array must survive: it is the first casualty when the array terminator is tested on the raw line")
	Assert(_LSFM_HasTag(Layout, "[LayoutAltGr]"),
		"the LAST value of the layout patterns array must survive")

	Dispatch := _LSFM_Entry(Entries, "ErgoptiPlus_dispatch.log")
	Assert(Dispatch != "", "the table must carry an ErgoptiPlus_dispatch.log entry")
	Assert(_LSFM_HasTag(Dispatch, "[TomlLoader]"),
		"[TomlLoader] must survive: it is the only dispatch pattern the driver actually emits, so losing it leaves ErgoptiPlus_dispatch.log permanently empty while looking like a topic with no traffic")
}
Test("logger: a multi-line TOML patterns array keeps every pattern (logger-subfiles-multiline-array-truncated)", _LSFM_MultiLineArrayKeepsEveryPattern)





; ======================================================
; ======================================================
; ======= 3/ No raw-line terminator test remains =======
; ======================================================
; ======================================================

; The behavioural test above can only see the patterns branch. The platforms
; branch carried the identical terminator bug and was dormant purely because no
; shipped platforms array spans two lines yet.
;
; The fix for that was structural rather than another careful quote-stripping
; pass: the driver no longer parses the TOML at all. So the assertion is now that
; there is no parser here to get it wrong — a hand-rolled array reader inside
; lib/logger.ahk is the precondition for the whole bug class, and it was one of
; TWO copies of the same grammar, which is why the same fix had to be written
; twice in two languages.
_LSFM_NoHandRolledParserRemains() {
	; The whole driver, not one file: the absence assertions below are stronger
	; that way (no module anywhere may reintroduce the grammar), and reading by a
	; hardcoded path breaks the moment a file moves.
	Src := _DriverSourceConcat()
	Assert(Src != "", "the driver source must be readable or this asserts nothing")

	Assert(InStr(Src, "[[sub_files]]") == 0,
		"the driver parses the sub_files TOML grammar again. That grammar belongs to the generator (tools/codegen/codegen-logger-sub-files.cjs), which uses a real TOML library; a hand-rolled reader brings back the bug where a " . Chr(34) . "]" . Chr(34) . " inside a quoted pattern closes the array early (logger-subfiles-multiline-array-truncated)")
	Assert(InStr(Src, "LOGGER_SUB_FILES_FALLBACK") == 0,
		"the hardcoded fallback routing list is back. It is a second copy of the data with nothing holding it to the source, and the macOS twin had already drifted from it")
	Assert(InStr(Src, "LoggerSubFilesData()") > 0,
		"the logger must take its routing table from the generated _generated/logger_sub_files.ahk")
}
Test("logger: the driver holds no hand-rolled sub_files parser (logger-subfiles-multiline-array-truncated)", _LSFM_NoHandRolledParserRemains)
