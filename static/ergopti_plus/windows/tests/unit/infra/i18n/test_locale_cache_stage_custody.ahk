; tests/unit/infra/i18n/test_locale_cache_stage_custody.ahk

; ==============================================================================
; MODULE: Public locale cache stage custody
; DESCRIPTION:
; A genuine lazy translation lookup may regenerate its derived TSV without
; adopting another producer's stage. All readers and native filesystem ports
; remain unchanged; only the locale root is redirected to an exclusive fixture.
; ==============================================================================

#Requires AutoHotkey v2.0

_ILSC_Snapshot(Path) {
	File := FileOpen(Path, "r", "UTF-8-RAW")
	if !IsObject(File)
		throw Error("The independent locale stage has no readable native identity.")
	try return FSHandleSnapshot(File.Handle)
	finally File.Close()
}

_ILSC_Case(Collision, StaleCache) {
	global _SharedDir, _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed, _I18nMissWarned, _I18N_TSV_SENTINEL
	static Sequence := 0
	Sequence += 1
	Saved := [_SharedDir, _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity,
		_I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded,
		_I18nFallbacksWarmed, _I18nMissWarned]
	Root := A_Temp . "\ergopti_locale_stage_" . PLC_CurrentProcessId() . "_" . A_TickCount . "_" . Sequence
	Folders := []
	; The locale folder under the shared root; the fixture makes each level of it.
	LocalesRel := "\data\locales"
	Path := Root . LocalesRel . "\de.json"
	Tsv := Root . LocalesRel . "\de.tsv", Stage := Tsv . ".tmp"
	Foreign := "independent locale staging bytes é😀`n"
	Prior := "custody.key`tprevious translation`n" . _I18N_TSV_SENTINEL . "1`n"
	Expected := "native translation é😀"
	PreviousCritical := Critical("Off")
	try {
		Folder := Root
		FSCreateDirectoryExclusiveStrict(Folder)
		Folders.Push(Folder)
		for Part in StrSplit(Trim(LocalesRel, "\"), "\") {
			Folder .= "\" . Part
			FSCreateDirectoryExclusiveStrict(Folder)
			Folders.Push(Folder)
		}
		AssertTrue(FSWriteCreateDurable(Path, '{"custody.key":"' . Expected . '"}'))
		if StaleCache {
			AssertTrue(FSWriteCreateDurable(Tsv, Prior))
			FileSetTime("20000101000000", Tsv, "M")
			AssertFalse(_I18nTsvIsFresh(Tsv, Path), "the real loader must genuinely reject the old complete cache")
		}
		if Collision {
			AssertTrue(FSWriteCreateDurable(Stage, Foreign), "CREATE_NEW must acquire the exact independent stage before the lookup")
			Before := _ILSC_Snapshot(Stage)
			AssertTrue(Before["ok"])
		}
		_SharedDir := Root, _I18nLocale := "de"
		_I18nCache := Map(), _I18nCacheLoaded := false, _I18nActiveCacheIdentity := false
		_I18nCacheEn := Map(), _I18nCacheEnLoaded := false
		_I18nCacheFr := Map(), _I18nCacheFrLoaded := false
		_I18nFallbacksWarmed := false, _I18nMissWarned := Map()
		Actual := t("custody.key")
		_TestPrint("# locale-stage collision=" . Collision . " stale_cache=" . StaleCache
			. " loaded=" . _I18nCacheLoaded . " exact_translation=" . (Actual == Expected)
			. " stage_present=" . !!FileExist(Stage) . " target_present=" . !!FileExist(Tsv))
		AssertTrue(_I18nCacheLoaded, "the actual JSON reader must publish the usable translation catalogue")
		AssertEqual(Expected, Actual, "refusing an independent cache stage cannot discard the authoritative translation")
		if Collision {
			AssertTrue(FileExist(Stage) != "", "a public translation lookup cannot remove another producer's stage")
			AssertEqual(Foreign, FSReadUtf8Exact(Stage), "the independent stage's exact text must survive")
			After := _ILSC_Snapshot(Stage)
			AssertTrue(After["ok"])
			for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
				AssertEqual(Before[Key], After[Key], "the independent stage keeps its native " . Key)
			if StaleCache
				AssertEqual(Prior, FSReadUtf8Exact(Tsv), "the refused publication preserves the existing derived cache")
			else
				AssertFalse(FileExist(Tsv), "an unacquired stage cannot become the published cache")
		} else {
			AssertFalse(FileExist(Stage), "successful native publication consumes only its acquired stage")
			Status := {Complete: false}
			Published := _I18nParseTSV(FSReadUtf8Exact(Tsv), "★", Status)
			AssertTrue(Status.Complete, "the actual cache writer must publish its terminal completeness record")
			AssertEqual(Expected, Published["custody.key"])
			FileSetTime("20000101000000", Path, "M")
			FileSetTime("20000102000000", Tsv, "M")
			Warm := _I18nLoadLocaleMap(Path, "★")
			AssertTrue(Warm.Ok && Warm.Fast, "the genuine published cache must satisfy the next loader's real fast path")
			AssertEqual(Expected, Warm.Cache["custody.key"])
		}
	} finally {
		_SharedDir := Saved[1], _I18nLocale := Saved[2]
		_I18nCache := Saved[3], _I18nCacheLoaded := Saved[4], _I18nActiveCacheIdentity := Saved[5]
		_I18nCacheEn := Saved[6], _I18nCacheEnLoaded := Saved[7]
		_I18nCacheFr := Saved[8], _I18nCacheFrLoaded := Saved[9]
		_I18nFallbacksWarmed := Saved[10], _I18nMissWarned := Saved[11]
		try {
			if Folders.Length == 1 + StrSplit(Trim(LocalesRel, "\"), "\").Length {
				for Leaf in [Path, Tsv, Stage]
					if !FSDelete(Leaf)
						throw Error("The private locale fixture could not retire an owned leaf.")
			}
			while Folders.Length
				DirDelete(Folders.Pop(), false)
		} finally Critical(PreviousCritical)
	}
}

for _ILSC_Collision in [false, true] {
	for _ILSC_Stale in [false, true]
		Test("locale public lookup: collision=" . _ILSC_Collision . " stale_cache=" . _ILSC_Stale . " (locale-cache-stage-custody)",
			_ILSC_Case.Bind(_ILSC_Collision, _ILSC_Stale))
}
