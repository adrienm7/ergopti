; tests/unit/test_cache_builder_strips_header_comment.ahk

; ==============================================================================
; MODULE: Regression — a commented section header must not lose its entries
;         (cache-builder-header-comment-not-stripped)
; DESCRIPTION:
; TOML permits a trailing comment on a section header: « [[ct]] # main gauche ».
; The runtime loaders all strip it before matching the anchored header pattern,
; and the comment block above them states the failure mode verbatim: an
; unstripped header leaves CurrentSection on the PREVIOUS section.
;
; ROOT CAUSE ENCODED: _HotstringsCacheBuildRows — the PRIMARY hotstring
; registration path, whose own docstring claims it uses "the SAME line-based
; scan … so the cache reproduces that reference behaviour exactly" — matched the
; RAW line. A commented header therefore failed the header pattern, fell through
; to the entry pattern, failed that too, and continued: every entry under it was
; cached against the previous section, or dropped outright when the commented
; header was the first one. The .tsv then persisted that wrong attribution until
; the next TOML edit, so it survived restarts. Meanwhile the menu count, which
; WAS fixed for this, went on reporting the entries as present.
; ==============================================================================

#Requires AutoHotkey v2.0

; One valid bundled-entry line, in the exact inline-table shape
; _HOTSTRING_ENTRY_PATTERN accepts.
global _CBHC_ENTRY_LINE :=
	Chr(34) . "zzq" . Chr(34) . " = { output = " . Chr(34) . "AVANT" . Chr(34)
	. ", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }"






; ======================================================================
; ======================================================================
; ======= 1/ Entries under a commented header keep their section =======
; ======================================================================
; ======================================================================

_CBHC_CommentedHeaderKeepsItsEntries() {
	global _SharedDir, _CBHC_ENTRY_LINE
	; An isolated shared tree so the real bundled TOMLs are untouched. Only one
	; bundled category exists here; the builder skips the rest via FileExist.
	Base := A_Temp . "\ergopti_cache_header_comment_test"
	HsDir := Base . "\modules\hotstrings"
	PrevShared := IsSet(_SharedDir) ? _SharedDir : ""
	try DirCreate(HsDir)
	TomlPath := HsDir . "\distancesreduction.toml"
	_SharedDir := Base
	try {
		try FileDelete(TomlPath)
		; The commented header comes FIRST, which is the destructive variant: with
		; no previous section to inherit, the entry is dropped outright.
		LF := Chr(10)
		FileAppend("[[ct]] # enchaînements main gauche" . LF . _CBHC_ENTRY_LINE . LF
			. "[[cs]]" . LF . _CBHC_ENTRY_LINE . LF, TomlPath, "UTF-8")

		Rows := _HotstringsCacheBuildRows()

		Assert(Rows.Has("distancesreduction.cs"),
			"sanity: an ordinary section header must still be parsed — otherwise this test would pass for the wrong reason")
		Assert(Rows.Has("distancesreduction.ct"),
			"a section header carrying a trailing TOML comment must still open its section. The raw anchored match failed on it, so the line fell through to the entry parser and was skipped, leaving every entry beneath it attributed to the previous section — or dropped, as here, when the commented header is the first one")
		AssertEqual(1, Rows["distancesreduction.ct"].Length,
			"and its entries must land in it, not in a neighbour")
	} finally {
		_SharedDir := PrevShared
		try FileDelete(TomlPath)
		try DirDelete(HsDir)
		try DirDelete(Base . "\modules")
		try DirDelete(Base)
	}
}
Test("hotstrings cache: a commented section header keeps its entries (cache-builder-header-comment-not-stripped)",
	_CBHC_CommentedHeaderKeepsItsEntries)






; =======================================================
; =======================================================
; ======= 2/ The builder strips before it matches =======
; =======================================================
; =======================================================

_CBHC_BuilderStripsBeforeMatching() {
	Body := _DriverFuncBody("_HotstringsCacheBuildRows")
	Assert(Body != "", "_HotstringsCacheBuildRows() must exist in the driver source")
	Assert(InStr(Body, "TOML_StripInlineComment(") > 0,
		"the cache builder must strip the inline comment before the anchored header match, exactly as the runtime loaders it claims to reproduce already do")
}
Test("meta hotstrings cache: the row builder strips a header's inline comment",
	_CBHC_BuilderStripsBeforeMatching)
