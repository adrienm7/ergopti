; static/ergopti_plus/windows/tests/test_prefix_watcher_index.ahk

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
