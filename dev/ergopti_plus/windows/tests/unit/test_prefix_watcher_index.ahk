; static/ergopti_plus/windows/tests/unit/test_prefix_watcher_index.ahk

; ==============================================================================
; MODULE: Prefix Watcher Index Tests
; DESCRIPTION:
; Regression tests for the preview-tooltip / expansion desync on a live
; (reload-free) section toggle. The prefix watcher keeps its OWN index, built
; from each category TOML and filtered by the Features "enabled" flag of every
; section (_RegisterCategoryTriggers). When a section is toggled live, the HSE
; registry is updated immediately, but the watcher index must be rebuilt too -
; otherwise a disabled section keeps previewing an expansion that no longer
; fires, and a freshly enabled section fires with no tooltip.
;
; These tests pin the section-filter invariant the rebuild relies on: a
; section's triggers appear in the index iff its Features "enabled" flag is set.
; ==============================================================================





; ============================================
; ============================================
; ======= 1/ Section-Enabled Filtering =======
; ============================================
; ============================================

; Build a one-section personal TOML on disk and point ScriptInformation at it,
; returning the path. The entry uses the full generator object form so it
; matches _RegisterCategoryTriggers' EntryPattern exactly.
_PrefixWatcherTest_WriteToml() {
	global ScriptInformation, _TomlFileCache
	Path := A_Temp . "\ergopti_test_prefix_watcher.toml"
	if FileExist(Path)
		FileDelete(Path)
	Toml := "[[testsec]]`r`n"
		. '"abc" = { output = "ABC", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = true }' . "`r`n"
	FileAppend(Toml, Path, "UTF-8")
	; Drop any cached content so ReadTomlFile re-reads our fresh temp file.
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
	ScriptInformation["PersonalTomlPath"] := Path
	if !ScriptInformation.Has("MagicKey")
		ScriptInformation["MagicKey"] := "*"
	return Path
}

; Rebuild the personal-category slice of the index from the current Features
; state (mirrors what HotstringPrefixWatcherRebuildIndex does per category).
_PrefixWatcherTest_Reindex() {
	global _PrefixIndex, _TriggerSet
	_PrefixIndex := Map()
	_TriggerSet := Map()
	_RegisterCategoryTriggers("personal")
}

TestPrefixWatcher_EnabledSectionIsIndexed() {
	global Features, _PrefixIndex
	_PrefixWatcherTest_WriteToml()
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()
	Features["hotstrings"]["personal"] := Map("testsec", Map("enabled", true))

	_PrefixWatcherTest_Reindex()
	AssertTrue(_PrefixIndex.Has("abc"),
		"an enabled section's trigger is present in the prefix index")
}
Test("prefix watcher: enabled section trigger is indexed",
	TestPrefixWatcher_EnabledSectionIsIndexed)

TestPrefixWatcher_DisabledSectionIsNotIndexed() {
	global Features, _PrefixIndex
	_PrefixWatcherTest_WriteToml()
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()
	; This is the exact tooltip-persistence bug: section disabled, but its
	; trigger must NOT remain in the index after a live-toggle rebuild.
	Features["hotstrings"]["personal"] := Map("testsec", Map("enabled", false))

	_PrefixWatcherTest_Reindex()
	AssertFalse(_PrefixIndex.Has("abc"),
		"a disabled section's trigger is absent from the index (no stale tooltip)")
}
Test("prefix watcher: disabled section trigger is not indexed",
	TestPrefixWatcher_DisabledSectionIsNotIndexed)

TestPrefixWatcher_ReenabledSectionIsIndexedAgain() {
	global Features, _PrefixIndex
	_PrefixWatcherTest_WriteToml()
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()

	; off -> rebuild -> on -> rebuild: the freshly enabled section must reappear
	; (this is the "fires but no tooltip" half of the bug).
	Features["hotstrings"]["personal"] := Map("testsec", Map("enabled", false))
	_PrefixWatcherTest_Reindex()
	AssertFalse(_PrefixIndex.Has("abc"), "precondition: disabled section not indexed")

	Features["hotstrings"]["personal"]["testsec"]["enabled"] := true
	_PrefixWatcherTest_Reindex()
	AssertTrue(_PrefixIndex.Has("abc"),
		"a re-enabled section's trigger reappears in the index (tooltip restored)")
}
Test("prefix watcher: re-enabled section trigger is indexed again",
	TestPrefixWatcher_ReenabledSectionIsIndexedAgain)




; ==============================================
; ==============================================
; ======= 2/ Priority-ranked preview ===========
; ==============================================
; ==============================================

; The live preview must surface the SAME winner the engine fires.
; _PrefixSortCandidates ranks colliding candidates by the engine tie-break
; (length > priority > registration order), so the first (non-dimmed) row is the
; real winner — not just the first-scanned category. Before this, a personal
; trigger the engine fires showed up DIMMED beneath the common trigger it beats,
; because the personal category is scanned last.
TestPrefixWatcher_PreviewWinnerByPriority() {
	; Same trigger, same length — registration order lists the common one first, but
	; the higher-priority personal one must sort to the front (the engine fires it).
	Common   := { Trigger: "ct", Output: "common",   Category: "autocorrection", Section: "x", Length: 2, Priority: 10 }
	Personal := { Trigger: "ct", Output: "personal", Category: "personal",       Section: "x", Length: 2, Priority: 50 }
	Sorted := _PrefixSortCandidates([Common, Personal])
	AssertEqual("personal", Sorted[1].Output,
		"the higher-priority candidate is the preview winner regardless of registration order")
	AssertEqual("common", Sorted[2].Output, "the lower-priority candidate is the dimmed loser")
}
Test("prefix watcher: higher priority wins the preview (matches the engine fire winner)",
	TestPrefixWatcher_PreviewWinnerByPriority)

TestPrefixWatcher_PreviewWinnerByLength() {
	; A longer trigger beats a higher-priority shorter one — the engine fires the longest.
	Shorter := { Output: "short", Length: 3, Priority: 50 }
	Longer  := { Output: "long",  Length: 5, Priority: 10 }
	Sorted := _PrefixSortCandidates([Shorter, Longer])
	AssertEqual("long", Sorted[1].Output,
		"a longer trigger outranks a higher-priority shorter one (engine fires the longest match)")
}
Test("prefix watcher: longer trigger wins the preview over a higher-priority shorter one",
	TestPrefixWatcher_PreviewWinnerByLength)

TestPrefixWatcher_PreviewStableOnTie() {
	; Equal length AND priority → the original registration order is preserved, mirroring
	; the engine's final Seq tiebreak. A non-stable sort here would flicker the winner.
	A := { Output: "first",  Length: 2, Priority: 10 }
	B := { Output: "second", Length: 2, Priority: 10 }
	Sorted := _PrefixSortCandidates([A, B])
	AssertEqual("first", Sorted[1].Output, "equal-rank candidates keep their registration order")
	AssertEqual("second", Sorted[2].Output, "the stable sort preserves Seq as the final tiebreak")
}
Test("prefix watcher: equal-rank candidates keep registration order (stable)",
	TestPrefixWatcher_PreviewStableOnTie)

; Integration: the index entry must carry the resolved priority so the ranking is fed
; real values — an individual `priority = N` on the TOML entry is captured and stored.
TestPrefixWatcher_IndexEntryCarriesIndividualPriority() {
	global ScriptInformation, Features, _PrefixIndex, _TriggerSet, _TomlFileCache
	Path := A_Temp . "\ergopti_test_pw_prio.toml"
	if FileExist(Path)
		FileDelete(Path)
	Toml := "[[testsec]]`r`n"
		. '"abc" = { output = "ABC", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = true, priority = 90 }' . "`r`n"
	FileAppend(Toml, Path, "UTF-8")
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
	ScriptInformation["PersonalTomlPath"] := Path
	if !ScriptInformation.Has("MagicKey")
		ScriptInformation["MagicKey"] := "*"
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()
	Features["hotstrings"]["personal"] := Map("testsec", Map("enabled", true))

	_PrefixIndex := Map()
	_TriggerSet := Map()
	_RegisterCategoryTriggers("personal")

	AssertTrue(_PrefixIndex.Has("abc"), "the trigger is indexed")
	AssertEqual(90, _PrefixIndex["abc"][1].Priority,
		"an individual `priority = N` key is captured and stored on the index entry")
}
Test("prefix watcher: individual priority key is threaded into the index entry",
	TestPrefixWatcher_IndexEntryCarriesIndividualPriority)
