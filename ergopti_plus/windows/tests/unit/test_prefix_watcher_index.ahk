; static/ergopti_plus/windows/tests/unit/test_prefix_watcher_index.ahk

; ==============================================================================
; MODULE: Prefix Watcher Catalogue And Canonical Winner Tests
; DESCRIPTION:
; The file-derived index remains an auxiliary near-miss catalogue, built from
; each category TOML and filtered by the Features "enabled" flag of every
; section. It must stay faithful for analytics, but it must never participate in
; choosing a visible expansion. The live HSE registry now owns selection and the
; collector transports its complete decision directly.
;
; These tests preserve the catalogue's section-filter and metadata invariants,
; then prove collision precedence at the real collector boundary rather than
; pinning the deleted preview-local sort.
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
		"an enabled section's trigger is present in the auxiliary catalogue")
}
Test("prefix watcher: enabled section trigger is indexed",
	TestPrefixWatcher_EnabledSectionIsIndexed)

TestPrefixWatcher_DisabledSectionIsNotIndexed() {
	global Features, _PrefixIndex
	_PrefixWatcherTest_WriteToml()
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()
	; This was the exact tooltip-persistence bug when the index owned rendering.
	; It now protects the remaining consumer: a disabled trigger must not survive
	; as a known-trigger or near-miss analytics row.
	Features["hotstrings"]["personal"] := Map("testsec", Map("enabled", false))

	_PrefixWatcherTest_Reindex()
	AssertFalse(_PrefixIndex.Has("abc"),
		"a disabled section's trigger is absent from the analytics catalogue")
}
Test("prefix watcher: disabled section trigger is not indexed",
	TestPrefixWatcher_DisabledSectionIsNotIndexed)

TestPrefixWatcher_ReenabledSectionIsIndexedAgain() {
	global Features, _PrefixIndex
	_PrefixWatcherTest_WriteToml()
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()

	; off -> rebuild -> on -> rebuild: the freshly enabled section must reappear
	; so later manual typing and near misses are attributed again.
	Features["hotstrings"]["personal"] := Map("testsec", Map("enabled", false))
	_PrefixWatcherTest_Reindex()
	AssertFalse(_PrefixIndex.Has("abc"), "precondition: disabled section not indexed")

	Features["hotstrings"]["personal"]["testsec"]["enabled"] := true
	_PrefixWatcherTest_Reindex()
	AssertTrue(_PrefixIndex.Has("abc"),
		"a re-enabled section's trigger reappears in the analytics catalogue")
}
Test("prefix watcher: re-enabled section trigger is indexed again",
	TestPrefixWatcher_ReenabledSectionIsIndexedAgain)




; ====================================================
; ====================================================
; ======= 2/ Engine-ranked canonical preview ==========
; ====================================================
; ====================================================

; The live preview must surface the SAME winner the engine fires. These cases
; exercise the collector over the live registry, so deleting the old sort does
; not delete its guarantee — it makes the guarantee behavioural.
TestPrefixWatcher_PreviewWinnerByPriority() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		HSE_Register("*?", "ct" . MK, 0,
			Map("Replacement", "common", "Priority", 10,
				"Category", "autocorrection", "Section", "x"))
		WinnerSpec := HSE_Register("*?", "ct" . MK, 0,
			Map("Replacement", "personal", "Priority", 50,
				"Category", "personal", "Section", "x"))
		HSE_Buffer := "ct"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"one completion key must expose only the canonical collision winner")
		AssertEqual("personal", Rows[1].Output,
			"the higher-priority live Spec must be the visible winner regardless of registration order")
		Assert(ObjPtr(Rows[1].FireDecision.Spec) == ObjPtr(WinnerSpec),
			"the row must retain the engine winner's exact identity")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("prefix watcher: higher priority wins the preview (matches the engine fire winner)",
	TestPrefixWatcher_PreviewWinnerByPriority)

TestPrefixWatcher_PreviewWinnerByLength() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		HSE_Register("*?", "bc" . MK, 0,
			Map("Replacement", "short", "Priority", 99,
				"Category", "test", "Section", "short"))
		LongSpec := HSE_Register("*?", "abc" . MK, 0,
			Map("Replacement", "long", "Priority", 10,
				"Category", "test", "Section", "long"))
		HSE_Buffer := "abc"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"the collector must expose only the engine's longest suffix winner")
		AssertEqual("long", Rows[1].Output,
			"a longer trigger outranks a higher-priority shorter suffix")
		Assert(ObjPtr(Rows[1].FireDecision.Spec) == ObjPtr(LongSpec),
			"the visible row must carry the longest live Spec")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("prefix watcher: longer trigger wins the preview over a higher-priority shorter one",
	TestPrefixWatcher_PreviewWinnerByLength)

TestPrefixWatcher_PreviewStableOnTie() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		FirstSpec := HSE_Register("*?", "eq" . MK, 0,
			Map("Replacement", "first", "Priority", 10,
				"Category", "test", "Section", "tie"))
		HSE_Register("*?", "eq" . MK, 0,
			Map("Replacement", "second", "Priority", 10,
				"Category", "test", "Section", "tie"))
		HSE_Buffer := "eq"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"equal-rank duplicates must still collapse to the one engine winner")
		AssertEqual("first", Rows[1].Output,
			"equal length and priority must preserve the engine's registration-order tiebreak")
		Assert(ObjPtr(Rows[1].FireDecision.Spec) == ObjPtr(FirstSpec),
			"the first registered Spec must own the visible row on an exact tie")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
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
