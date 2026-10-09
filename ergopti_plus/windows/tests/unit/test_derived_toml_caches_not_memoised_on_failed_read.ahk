; tests/unit/test_derived_toml_caches_not_memoised_on_failed_read.ahk

; ==============================================================================
; MODULE: Regression — nothing DERIVED from a failed read may be memoised either
; DESCRIPTION:
; ReadTomlFile deliberately does not cache a read that failed. Its own comment
; states why: caching it made one transient lock at boot hide a whole hotstring
; file for the entire session, and leaving the path uncached lets the next
; caller retry.
;
; ROOT CAUSE ENCODED:
; That guarantee is transitive, but it was applied at one site only. Both
; derived caches in the same module memoised the value COMPUTED FROM the failed
; read — _TomlFileSectionCounts (the per-file section counts behind the tray
; menu's hotstring numbers) and HotstringGroupConfig (the per-group [_meta]
; delay / colour / show_tooltip / priority). Each cache hit precedes the read,
; so the retry the uncached path enables could no longer reach those two
; consumers: the category showed 0 entries and the group resolved to the global
; fallback delay and colour for the rest of the session. Both degrade to
; plausible defaults, so nothing looks wrong at any level.
;
; A missing file is NOT flagged and must keep caching exactly as before — that
; path is the common one and re-statting it on every menu rebuild is what the
; cache exists to avoid.
; ==============================================================================

#Requires AutoHotkey v2.0

; Deny-all sharing: an existing file that cannot be opened is the exact
; condition a sync client, an AV on-access scan or a backup agent produces.
global _DTC_EXCLUSIVE_LOCK_FLAGS := "r-rwd"

_DTC_ClearFlag(Path) {
	global _TomlUnreadableFiles
	if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path))
		_TomlUnreadableFiles.Delete(Path)
}

; Build one full inline-table hotstring entry line — the exact shape both the
; loader and the counter recognise. Concatenated rather than Format()ed: the
; line is full of literal braces, which Format would read as placeholders.
_DTC_Entry(Trigger, Output) {
	return '"' . Trigger . '" = { output = "' . Output
		. '", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }'
}

_DTC_ClearFileCache(Path) {
	global _TomlFileCache, _TomlFileSectionCounts, HotstringGroupConfig
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
	if _TomlFileSectionCounts.Has(Path)
		_TomlFileSectionCounts.Delete(Path)
	if HotstringGroupConfig.Has(Path)
		HotstringGroupConfig.Delete(Path)
}





; ==============================================================
; ==============================================================
; ======= 1/ The section-count cache ===========================
; ==============================================================
; ==============================================================

_DTC_CountsAreNotMemoisedFromAFailedRead() {
	Path := A_Temp . "\ergopti_dtc_counts_" . A_TickCount . ".toml"
	Content := "[[sect]]`r`n"
		. _DTC_Entry("aa", "AA") . "`r`n"
		. _DTC_Entry("bb", "BB") . "`r`n"
	FileAppend(Content, Path, "UTF-8")
	_DTC_ClearFlag(Path)
	_DTC_ClearFileCache(Path)

	Lock := FileOpen(Path, _DTC_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock),
		"the exclusive lock must actually be taken — without it this case proves nothing")
	try {
		AssertEqual(0, CountTomlHotstrings("x", Path),
			"a locked file reads as empty, so the count is 0 while the lock is held (the non-throwing contract)")
	} finally {
		Lock.Close()
	}

	try {
		AssertEqual(2, CountTomlHotstrings("x", Path),
			"a count derived from a read that FAILED must not be memoised: ReadTomlFile leaves the path uncached so the next caller retries, and caching the derived zero reinstates the session-long invisible-file bug that rule was written to remove")
	} finally {
		_DTC_ClearFlag(Path)
		_DTC_ClearFileCache(Path)
		try FileDelete(Path)
	}
}


; Positive control for the same cache: a successful count MUST still be
; memoised, or the fix has simply disabled the cache instead of scoping it.
_DTC_SuccessfulCountsAreStillMemoised() {
	Path := A_Temp . "\ergopti_dtc_ok_" . A_TickCount . ".toml"
	FileAppend("[[sect]]`r`n" . _DTC_Entry("aa", "AA") . "`r`n", Path, "UTF-8")
	_DTC_ClearFlag(Path)
	_DTC_ClearFileCache(Path)
	try {
		AssertEqual(1, CountTomlHotstrings("x", Path), "the entry must be counted")
		FileDelete(Path)
		AssertEqual(1, CountTomlHotstrings("x", Path),
			"a successful count must stay memoised — deleting the file must not change what the cache returns, or every menu rebuild re-parses every category file")
	} finally {
		_DTC_ClearFlag(Path)
		_DTC_ClearFileCache(Path)
		try FileDelete(Path)
	}
}





; ==============================================================
; ==============================================================
; ======= 2/ The per-group [_meta] cache =======================
; ==============================================================
; ==============================================================

_DTC_GroupConfigIsNotMemoisedFromAFailedRead() {
	Path := A_Temp . "\ergopti_dtc_meta_" . A_TickCount . ".toml"
	FileAppend("[_meta]`r`ndelay = 0.5`r`n", Path, "UTF-8")
	_DTC_ClearFlag(Path)
	_DTC_ClearFileCache(Path)

	Lock := FileOpen(Path, _DTC_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the exclusive lock must actually be taken")
	try {
		Locked := ParseTomlGroupConfig("", Path)
		AssertEqual("", Locked.Delay,
			"a locked file yields an empty group config while the lock is held")
	} finally {
		Lock.Close()
	}

	try {
		AssertEqual(0.5, ParseTomlGroupConfig("", Path).Delay,
			"a group config derived from a read that FAILED must not be memoised: the cache hit precedes the read, so freezing the all-empty Config resolved that group's delay and tooltip colour to the global fallback for the whole session with nothing logged after the first ERROR")
	} finally {
		_DTC_ClearFlag(Path)
		_DTC_ClearFileCache(Path)
		try FileDelete(Path)
	}
}


; Positive control: a MISSING file is never flagged unreadable, so its empty
; result must still be cached — that is the hot path this cache exists for.
_DTC_MissingFileGroupConfigIsStillMemoised() {
	global HotstringGroupConfig
	Path := A_Temp . "\ergopti_dtc_absent_" . A_TickCount . ".toml"
	try FileDelete(Path)
	_DTC_ClearFlag(Path)
	_DTC_ClearFileCache(Path)
	try {
		ParseTomlGroupConfig("", Path)
		Assert(HotstringGroupConfig.Has(Path),
			"a missing file legitimately resolves to an empty config and must stay memoised — flagging it would re-stat every absent category file on every resolve")
	} finally {
		_DTC_ClearFlag(Path)
		_DTC_ClearFileCache(Path)
	}
}


Test("toml_loader: section counts are not memoised from a failed read",
	_DTC_CountsAreNotMemoisedFromAFailedRead)
Test("toml_loader: successful section counts are still memoised",
	_DTC_SuccessfulCountsAreStillMemoised)
Test("toml_loader: group [_meta] config is not memoised from a failed read",
	_DTC_GroupConfigIsNotMemoisedFromAFailedRead)
Test("toml_loader: a missing file's group config is still memoised",
	_DTC_MissingFileGroupConfigIsStillMemoised)
