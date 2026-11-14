; static/ergopti_plus/windows/tests/unit/core/i18n/test_i18n.ahk

; ==============================================================================
; MODULE: i18n Tests
; DESCRIPTION:
; Regression tests for the i18n module after the JsonParse-based refactor.
; Covers _I18nLoadFile parsing, the t() fallback chain, I18nInit locale
; validation, and _I18nSortedLocales ordering. Uses temporary JSON files
; written to A_Temp so no real locale files need to be present.
; ==============================================================================






; ========================================
; ========================================
; ======= 1/ _I18nLoadFile helpers =======
; ========================================
; ========================================

; Reset the i18n module state between tests so each case starts clean.
_I18nTestReset() {
	global _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded
	global _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed
	global _I18nActiveCacheIdentity
	_I18nCache        := Map()
	_I18nCacheLoaded  := false
	_I18nCacheEn      := Map()
	_I18nCacheEnLoaded := false
	_I18nCacheFr      := Map()
	_I18nCacheFrLoaded := false
	_I18nFallbacksWarmed := false
	_I18nActiveCacheIdentity := false
}

; Pause/suspend regression for i18n (locales must load even if script paused; t() fallback must work)
TestI18n_PauseSafe() {
	_I18nTestReset()
	; i18n init and t() must not depend on active keyboard state
	Path := _I18nTmpJson('{"test.key": "valeur"}')
	_I18nLoadFile(Path)
	AssertEqual("valeur", t("test.key"))
	_I18nTestReset()
}
Test("i18n: pause/suspend must not break locale loading or t() fallback", TestI18n_PauseSafe)

; I18W-001: a system language without a catalogue falls back to the shared
; locales.system_fallback of identifiers.json, as the Lua drivers read it.
TestI18n_SystemFallbackIsShared() {
	global _SharedDir
	Shared := JsonParse(FileRead(_SharedDir . "\core\text\data\identifiers.json", "UTF-8"))["locales"]["system_fallback"]
	AssertEqual(Shared, Identifiers.Locales.SYSTEM_FALLBACK, "the generated fallback is the shared one")
	AssertEqual(Shared, _I18nDetectSystemLocale({Ui: (*) => "xx-XX"}), "an unsupported language takes it")
	AssertEqual(Shared, _I18nDetectSystemLocale({Ui: (*) => ""}), "an unavailable language takes it")
	AssertEqual("fr", _I18nDetectSystemLocale({Ui: (*) => "fr-FR"}), "a supported language keeps its own")
}
Test("i18n: the system language fallback is the shared one (I18W-001)", TestI18n_SystemFallbackIsShared)

_I18nTmpJson(Content) {
	Path := A_Temp . "\i18n_test_locale.json"
	if FileExist(Path) {
		FileDelete(Path)
	}
	; Clear the sibling self-healing .tsv cache that _I18nLoadFile regenerates, so a
	; leftover from a previous case cannot be served as a "fresh" hit for this
	; case's freshly written JSON. FileGetTime has 1-second resolution and the
	; cases run within the same second, so a stale tsv would otherwise win.
	TsvPath := A_Temp . "\i18n_test_locale.tsv"
	if FileExist(TsvPath) {
		FileDelete(TsvPath)
	}
	FileAppend(Content, Path, "UTF-8")
	return Path
}


; --- _JsonParseString batched-run regression ---
; _JsonParseString copies plain spans in one slice rather than char-by-char.
; These drive it end-to-end through _I18nLoadFile + t() to pin that the batched
; copy is byte-identical to the old per-char path: long unescaped runs, runs
; that end exactly on the closing quote, and runs that resume after an escape.
TestI18n_JsonLongPlainRun() {
	_I18nTestReset()
	Long := "the quick brown fox jumps over the lazy dog several times over"
	_I18nLoadFile(_I18nTmpJson('{"k": "' . Long . '"}'))
	AssertEqual(Long, t("k"))
	_I18nTestReset()
}
Test("i18n/json: long no-escape run decodes verbatim (batched fast-path)",
	TestI18n_JsonLongPlainRun)

TestI18n_JsonRunEndsAtQuote() {
	_I18nTestReset()
	_I18nLoadFile(_I18nTmpJson('{"k": "abc"}'))
	AssertEqual("abc", t("k"))
	_I18nTestReset()
}
Test("i18n/json: plain run ending exactly at closing quote", TestI18n_JsonRunEndsAtQuote)

TestI18n_JsonNewlineEscape() {
	_I18nTestReset()
	_I18nLoadFile(_I18nTmpJson('{"k": "line1\nline2 with a longer tail"}'))
	AssertEqual("line1`nline2 with a longer tail", t("k"))
	_I18nTestReset()
}
Test("i18n/json: escape then plain run resumes correctly", TestI18n_JsonNewlineEscape)

TestI18n_JsonLeadingEscape() {
	_I18nTestReset()
	_I18nLoadFile(_I18nTmpJson('{"k": "\tindented run of plain text"}'))
	AssertEqual("`tindented run of plain text", t("k"))
	_I18nTestReset()
}
Test("i18n/json: leading escape before a plain run", TestI18n_JsonLeadingEscape)

TestI18n_JsonBackslashRuns() {
	_I18nTestReset()
	_I18nLoadFile(_I18nTmpJson('{"k": "path\\to\\some file"}'))
	AssertEqual("path\to\some file", t("k"))
	_I18nTestReset()
}
Test("i18n/json: backslash escapes between plain runs", TestI18n_JsonBackslashRuns)

TestI18n_JsonUnicodeEscape() {
	_I18nTestReset()
	; Build the backslash via Chr(0x5C) so the JSON source carries a real
	; é escape that _JsonParseString must decode to é before the batched
	; plain run " creme et plus" resumes
	Content := '{"k": "caf' . Chr(0x5C) . 'u00e9 creme et plus"}'
	_I18nLoadFile(_I18nTmpJson(Content))
	AssertEqual("café creme et plus", t("k"))
	_I18nTestReset()
}
Test("i18n/json: unicode escape then plain run decodes correctly", TestI18n_JsonUnicodeEscape)






; ===========================================
; ===========================================
; ======= 2/ _I18nLoadFile test cases =======
; ===========================================
; ===========================================

_I18nLoadFileMissingLeavesEmpty() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	_I18nLoadFile(A_Temp . "\does_not_exist_locale.json")
	AssertFalse(_I18nCacheLoaded)
	AssertEqual(0, _I18nCache.Count)
}
Test("i18n _I18nLoadFile: missing file leaves cache empty and unloaded", _I18nLoadFileMissingLeavesEmpty)

_I18nLoadFileParsesFlat() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	Path := _I18nTmpJson('{"hello": "Bonjour", "bye": "Au revoir"}')
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertTrue(_I18nCacheLoaded)
	AssertEqual("Bonjour",    _I18nCache["hello"])
	AssertEqual("Au revoir",  _I18nCache["bye"])
}
Test("i18n _I18nLoadFile: parses flat JSON object", _I18nLoadFileParsesFlat)

_I18nLoadFileSubstitutesMagicKey() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded, ScriptInformation
	ScriptInformation["MagicKey"] := Chr(0x2605)
	Path := _I18nTmpJson('{"magic_hint": "Press ' . Chr(0x2605) . ' to continue"}')
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertTrue(_I18nCacheLoaded)
	AssertEqual("Press " . Chr(0x2605) . " to continue", _I18nCache["magic_hint"])
}
Test("i18n _I18nLoadFile: substitutes magic key placeholder", _I18nLoadFileSubstitutesMagicKey)

_I18nLoadFileLeavesUnloadedOnInvalidJson() {
	_I18nTestReset()
	global _I18nCacheLoaded
	Path := _I18nTmpJson("this is not json at all {{")
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertFalse(_I18nCacheLoaded)
}
Test("i18n _I18nLoadFile: leaves cache unloaded on invalid JSON", _I18nLoadFileLeavesUnloadedOnInvalidJson)

_I18nLoadFileHandlesEmptyObject() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	Path := _I18nTmpJson("{}")
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertTrue(_I18nCacheLoaded)
	AssertEqual(0, _I18nCache.Count)
}
Test("i18n _I18nLoadFile: handles empty JSON object", _I18nLoadFileHandlesEmptyObject)


; --- Self-healing .tsv cache regressions ---
; The .json is the single tracked source; the .tsv is a gitignored fast cache the
; driver writes on a miss and reads when fresh. These pin: regeneration on a miss,
; the json<->tsv escape round-trip, that ★ is stored RAW (MagicKey-independent),
; staleness detection by mtime, and that a fresh cache is served without re-parsing.

_I18nLazyCacheRegeneratesAndRoundTrips() {
	_I18nTestReset()
	global _I18nCache
	TsvPath := A_Temp . "\i18n_test_locale.tsv"
	Path := _I18nTmpJson('{"a": "alpha", "b": "beta"}')   ; _I18nTmpJson clears any old tsv
	AssertFalse(FileExist(TsvPath), "precondition: no .tsv before the first load")
	_I18nLoadFile(Path)
	AssertTrue(FileExist(TsvPath), "a miss must regenerate the .tsv cache")
	AssertEqual("alpha", _I18nCache["a"])
	AssertEqual("beta",  _I18nCache["b"])
	; The regenerated cache must round-trip back to the same key/value set.
	M := _I18nParseTSV(FileRead(TsvPath, "UTF-8"), Chr(0x2605))
	AssertEqual("alpha", M["a"])
	AssertEqual("beta",  M["b"])
	FileDelete(Path)
	FileDelete(TsvPath)
	_I18nTestReset()
}
Test("i18n cache: regenerates .tsv on a miss and round-trips", _I18nLazyCacheRegeneratesAndRoundTrips)

_I18nLazyCacheRoundTripsEscapes() {
	_I18nTestReset()
	global _I18nCache
	TsvPath := A_Temp . "\i18n_test_locale.tsv"
	; JSON "a\\b\nc" decodes to: a + backslash + b + newline + c. Both the literal
	; backslash and the newline must survive json -> tsv (escaped) -> map (unescaped).
	BS := Chr(0x5C)
	Path := _I18nTmpJson('{"k": "a' . BS . BS . 'b' . BS . 'nc"}')
	_I18nLoadFile(Path)
	Expected := "a" . BS . "b`nc"
	AssertEqual(Expected, _I18nCache["k"], "backslash + newline must survive the load")
	M := _I18nParseTSV(FileRead(TsvPath, "UTF-8"), Chr(0x2605))
	AssertEqual(Expected, M["k"], "the regenerated .tsv must round-trip escapes exactly")
	FileDelete(Path)
	FileDelete(TsvPath)
	_I18nTestReset()
}
Test("i18n cache: backslash + newline round-trip through the .tsv", _I18nLazyCacheRoundTripsEscapes)

_I18nLazyCacheStoresRawStar() {
	_I18nTestReset()
	global _I18nCache, ScriptInformation
	Saved := ScriptInformation.Has("MagicKey") ? ScriptInformation["MagicKey"] : Chr(0x2605)
	ScriptInformation["MagicKey"] := "@@"   ; distinct key so we can tell them apart
	TsvPath := A_Temp . "\i18n_test_locale.tsv"
	Path := _I18nTmpJson('{"hint": "Press ' . Chr(0x2605) . ' now"}')
	_I18nLoadFile(Path)
	AssertEqual("Press @@ now", _I18nCache["hint"], "in-memory cache must carry the substituted MagicKey")
	Raw := FileRead(TsvPath, "UTF-8")
	AssertTrue(InStr(Raw, Chr(0x2605)) > 0, "the .tsv must store the RAW ★ placeholder")
	AssertFalse(InStr(Raw, "@@") > 0, "the .tsv must NOT bake in the MagicKey (stays cache-independent)")
	FileDelete(Path)
	FileDelete(TsvPath)
	ScriptInformation["MagicKey"] := Saved
	_I18nTestReset()
}
Test("i18n cache: .tsv stores the raw ★ placeholder, not the MagicKey", _I18nLazyCacheStoresRawStar)

_I18nLazyCacheStaleJsonRegenerates() {
	_I18nTestReset()
	global _I18nCache
	TsvPath := A_Temp . "\i18n_test_locale.tsv"
	Path := _I18nTmpJson('{"k": "v1"}')
	_I18nLoadFile(Path)
	AssertEqual("v1", _I18nCache["k"])
	; Force the cache to look OLD, then rewrite the JSON (newer) WITHOUT clearing the
	; tsv — the loader must detect the stale cache by mtime and rebuild from the JSON.
	FileSetTime("20000101000000", TsvPath, "M")
	_I18nTestReset()
	FileDelete(Path)
	FileAppend('{"k": "v2"}', Path, "UTF-8")
	_I18nLoadFile(Path)
	AssertEqual("v2", _I18nCache["k"], "a .tsv older than its .json must be regenerated")
	FileDelete(Path)
	FileDelete(TsvPath)
	_I18nTestReset()
}
Test("i18n cache: stale .tsv (older than .json) is regenerated", _I18nLazyCacheStaleJsonRegenerates)

_I18nLazyCacheEqualSecondRegenerates() {
	global _I18nCache, _I18nActiveCacheIdentity
	Directory := A_Temp . "\ergopti_locale_equal_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Path := Directory . "\locale.json", TsvPath := Directory . "\locale.tsv"
	_I18nTestReset()
	try {
		AssertTrue(FSWriteCreateDurable(Path, '{"k":"before"}'))
		_I18nWriteTsvCache(TsvPath, Map("k", "before"))
		AssertTrue(FileExist(TsvPath) != "", "The genuine cache writer must publish a complete old cache")
		FileDelete(Path)
		AssertTrue(FSWriteCreateDurable(Path, '{"k":"after"}'))
		FileSetTime("20200101000000", Path, "M")
		FileSetTime("20200101000000", TsvPath, "M")
		AssertEqual(FileGetTime(Path, "M"), FileGetTime(TsvPath, "M"),
			"The stale complete cache and edited JSON must genuinely share the same timestamp")
		AssertFalse(IsObject(_I18nActiveCacheIdentity), "This must be a cold first load without an earlier source hash")
		_I18nLoadFile(Path)
		AssertEqual("after", _I18nCache["k"], "A same-second edit must be read from the authoritative JSON")
		Status := {Complete: false}
		Regenerated := _I18nParseTSV(FileRead(TsvPath, "UTF-8"), "*", Status)
		AssertTrue(Status.Complete)
		AssertEqual("after", Regenerated["k"], "The genuine writer must replace the stale disk cache too")
		FileSetTime("20200101000001", TsvPath, "M")
		Result := _I18nLoadLocaleMap(Path, "*")
		AssertTrue(Result.Ok && Result.Fast, "A strictly newer complete cache must retain the fast path")
		AssertEqual("after", Result.Cache["k"])
	} finally {
		_I18nTestReset()
		DirDelete(Directory, true)
	}
}
Test("i18n cache: a cold same-second edit regenerates the complete cache (locale-equal-second)",
	_I18nLazyCacheEqualSecondRegenerates)


_I18nLazyCacheFreshTsvServedWithoutJson() {
	_I18nTestReset()
	global _I18nCache
	TsvPath := A_Temp . "\i18n_test_locale.tsv"
	Path := A_Temp . "\i18n_test_locale.json"
	if FileExist(Path)
		FileDelete(Path)
	if FileExist(TsvPath)
		FileDelete(TsvPath)
	; JSON says "fromjson"; a hand-written, NEWER tsv says "fromtsv". A fresh cache
	; must be served verbatim, proving the fast path skips the JSON parse entirely.
	FileAppend('{"k": "fromjson"}', Path, "UTF-8")
	FileSetTime("20000101000000", Path, "M")
	FileAppend("k`tfromtsv`n" . _I18N_TSV_SENTINEL . "1`n",
		TsvPath, "UTF-8-RAW")
	_I18nLoadFile(Path)
	AssertEqual("fromtsv", _I18nCache["k"], "a fresh .tsv must be served without re-parsing the .json")
	FileDelete(Path)
	FileDelete(TsvPath)
	_I18nTestReset()
}
Test("i18n cache: a fresh .tsv is served without re-parsing the .json", _I18nLazyCacheFreshTsvServedWithoutJson)

_I18nLazyCacheRejectsFreshPartialTsv() {
	_I18nTestReset()
	global _I18nCache
	TsvPath := A_Temp . "\i18n_test_locale.tsv"
	Path := A_Temp . "\i18n_test_locale.json"
	if FileExist(Path)
		FileDelete(Path)
	if FileExist(TsvPath)
		FileDelete(TsvPath)
	try {
		FileAppend('{"a": "json-a", "b": "json-b"}', Path, "UTF-8")
		FileSetTime("20000101000000", Path, "M")
		FileAppend("a`tcached-a`n", TsvPath, "UTF-8-RAW")
		_I18nLoadFile(Path)
		AssertEqual("json-a", _I18nCache["a"],
			"a fresh but incomplete cache must not override canonical JSON")
		AssertEqual("json-b", _I18nCache["b"],
			"keys beyond a truncated cache prefix must be recovered from JSON")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
		if FileExist(TsvPath)
			FileDelete(TsvPath)
		_I18nTestReset()
	}
}
Test("i18n cache: fresh partial .tsv rebuilds from canonical JSON",
	_I18nLazyCacheRejectsFreshPartialTsv)






; ===============================
; ===============================
; ======= 3/ t() fallback =======
; ===============================
; ===============================

_I18nFallbackWarmupRetriesAfterTransientFailure() {
	global _SharedDir, _I18nLocale, _I18nFallbacksWarmed
	global _I18nCacheEnLoaded, _I18nCacheFrLoaded
	SavedSharedDir := _SharedDir
	SavedLocale := _I18nLocale
	Root := A_Temp . "\ergopti-i18n-fallback-retry-" . A_ScriptHwnd
	try {
		if DirExist(Root)
			DirDelete(Root, true)
		DirCreate(Root . "\core\i18n\data\locales")
		_SharedDir := Root
		_I18nLocale := "de"
		_I18nTestReset()

		_I18nEnsureFallbacksLoaded()
		AssertFalse(_I18nFallbacksWarmed,
			"failed fallback loads must remain retryable")
		AssertFalse(_I18nCacheEnLoaded)
		AssertFalse(_I18nCacheFrLoaded)

		FileAppend('{"retry.key": "English"}',
			Root . "\core\i18n\data\locales\en.json", "UTF-8")
		FileAppend('{"retry.key": "Francais"}',
			Root . "\core\i18n\data\locales\fr.json", "UTF-8")
		_I18nEnsureFallbacksLoaded()
		AssertTrue(_I18nFallbacksWarmed,
			"a later successful load must complete fallback warmup")
		AssertTrue(_I18nCacheEnLoaded)
		AssertTrue(_I18nCacheFrLoaded)
	} finally {
		_SharedDir := SavedSharedDir
		_I18nLocale := SavedLocale
		_I18nTestReset()
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("i18n fallback: failed warmup retries when locale files become available",
	_I18nFallbackWarmupRetriesAfterTransientFailure)

_I18nTFallbackWhenEmpty() {
	_I18nTestReset()
	global _I18nLocale, _I18nCacheLoaded
	; Point locale at a non-existent file so _I18nEnsureLoaded silently fails
	_I18nLocale      := "xx"
	_I18nCacheLoaded := true   ; Prevent real file load from overwriting
	Result := t("some.missing.key")
	AssertEqual("some.missing.key", Result)
}
Test("i18n t(): returns key as fallback when cache is empty", _I18nTFallbackWhenEmpty)

_I18nTReturnsValueFromPrimary() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	_I18nCache["greeting"] := "Salut"
	_I18nCacheLoaded        := true
	AssertEqual("Salut", t("greeting"))
}
Test("i18n t(): returns value from primary cache", _I18nTReturnsValueFromPrimary)

_I18nTFallsBackToEnglish() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded
	_I18nCacheLoaded  := true
	_I18nCacheEnLoaded := true
	_I18nCacheEn["en_only"] := "English value"
	AssertEqual("English value", t("en_only"))
}
Test("i18n t(): falls back to English cache when key absent from primary", _I18nTFallsBackToEnglish)

_I18nTFallsBackToFrench() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded
	global _I18nCacheFr, _I18nCacheFrLoaded
	_I18nCacheLoaded  := true
	_I18nCacheEnLoaded := true
	_I18nCacheFrLoaded := true
	_I18nCacheFr["fr_only"] := "Valeur française"
	AssertEqual("Valeur française", t("fr_only"))
}
Test("i18n t(): falls back to French cache when key absent from primary and English", _I18nTFallsBackToFrench)

_I18nTPrimaryTakesPriority() {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded
	_I18nCacheLoaded   := true
	_I18nCacheEnLoaded := true
	_I18nCache["key"]   := "Primary"
	_I18nCacheEn["key"] := "English"
	AssertEqual("Primary", t("key"))
}
Test("i18n t(): primary cache takes priority over fallbacks", _I18nTPrimaryTakesPriority)






; =============================================
; =============================================
; ======= 4/ I18nInit locale validation =======
; =============================================
; =============================================

_I18nInitAcceptsKnownLocale() {
	_I18nTestReset()
	global _I18nLocale
	; Build a minimal TOML cache with locale = "de"
	Cache := Map("script", Map("locale", "de"))
	I18nInit(Cache)
	AssertEqual("de", _I18nLocale)
}
Test("i18n I18nInit: accepts known locale code from cache", _I18nInitAcceptsKnownLocale)

; AHK v2 forbids `break` inside a for-loop nested in a fat-arrow lambda.
; Extract both the locale lookup and the locale read into named helpers.
_I18nIsKnownLocale(Code) {
	for Loc in I18N_LOCALES {
		if Loc.Code == Code
			return true
	}
	return false
}
_I18nGetCurrentLocale() {
	global _I18nLocale
	return _I18nLocale
}
_I18nSetCurrentLocale(Code) {
	global _I18nLocale
	_I18nLocale := Code
}

_I18nInitIgnoresSentinel() {
	_I18nTestReset()
	_I18nSetCurrentLocale("fr")
	Cache := Map("script", Map("locale", "_"))
	I18nInit(Cache)
	AssertTrue(_I18nIsKnownLocale(_I18nGetCurrentLocale()), "I18nInit with sentinel _ should set a known locale code")
}
Test("i18n I18nInit: ignores sentinel value underscore", _I18nInitIgnoresSentinel)

_I18nInitResetsCacheLoadedFlag() {
	_I18nTestReset()
	global _I18nCacheLoaded
	_I18nCacheLoaded := true
	Cache := Map("script", Map("locale", "en"))
	I18nInit(Cache)
	AssertFalse(_I18nCacheLoaded)
}
Test("i18n I18nInit: resets cache loaded flag", _I18nInitResetsCacheLoadedFlag)

_I18nInitRetainsVerifiedCache() {
	global _SharedDir, _I18nLocale, _I18nCache, _I18nCacheLoaded, ScriptInformation
	SavedShared := _SharedDir
	SavedLocale := _I18nLocale
	SavedMagic := ScriptInformation.Get("MagicKey", "★")
	Directory := A_Temp . "\ergopti-locale-reuse-" . A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Directory . "\core\i18n\data\locales")
	Path := Directory . "\core\i18n\data\locales\fr.json"
	try {
		_I18nTestReset()
		_SharedDir := Directory
		_I18nLocale := "fr"
		ScriptInformation["MagicKey"] := "old"
		FileAppend('{"hint": "Press ★", "other": "old stays literal"}', Path, "UTF-8-RAW")
		_I18nLoadFile(Path)
		Cache := _I18nCache
		ScriptInformation["MagicKey"] := "new"
		I18nInit(Map("script", Map("locale", "fr")))
		AssertTrue(_I18nCacheLoaded)
		AssertTrue(_I18nCache == Cache, "unchanged source keeps the verified locale map")
		AssertEqual("Press new", t("hint"), "raw templates update only the configured glyph")
		AssertEqual("old stays literal", t("other"), "literal text never undergoes old-token replacement")
		Timestamp := FileGetTime(Path, "M")
		FileDelete(Path)
		FileAppend('{"hint": "Other ★", "other": "old stays literal"}', Path, "UTF-8-RAW")
		FileSetTime(Timestamp, Path, "M")
		I18nInit(Map("script", Map("locale", "fr")))
		AssertFalse(_I18nCacheLoaded, "same timestamp and size cannot conceal changed source bytes")
		AssertEqual("Other new", t("hint"), "a detected source edit must also bypass a stale timestamp-valid TSV")
	} finally {
		_SharedDir := SavedShared
		_I18nLocale := SavedLocale
		ScriptInformation["MagicKey"] := SavedMagic
		_I18nTestReset()
		DirDelete(Directory, true)
	}
}
Test("i18n I18nInit: verified cache survives glyph changes and rejects exact source changes", _I18nInitRetainsVerifiedCache)






; ==============================================
; ==============================================
; ======= 5/ _I18nSortedLocales ordering =======
; ==============================================
; ==============================================

_I18nSortedReturnsAll() {
	global I18N_LOCALES
	Sorted := _I18nSortedLocales()
	AssertEqual(I18N_LOCALES.Length, Sorted.Length)
}
Test("i18n _I18nSortedLocales: returns all locales", _I18nSortedReturnsAll)

_I18nSortedIsAlphabetical() {
	Sorted := _I18nSortedLocales()
	i := 1
	while i < Sorted.Length {
		AssertTrue(
			StrCompare(Sorted[i].Name, Sorted[i + 1].Name, false) <= 0,
			"Sort order violated between " . Sorted[i].Name . " and " . Sorted[i + 1].Name
		)
		i++
	}
}
Test("i18n _I18nSortedLocales: result is alphabetically ordered by Name", _I18nSortedIsAlphabetical)

_I18nSortedDoesNotMutateOriginal() {
	global I18N_LOCALES
	OrigFirst := I18N_LOCALES[1].Code
	_I18nSortedLocales()
	AssertEqual(OrigFirst, I18N_LOCALES[1].Code)
}
Test("i18n _I18nSortedLocales: does not mutate original I18N_LOCALES", _I18nSortedDoesNotMutateOriginal)





; =====================================================
; =====================================================
; ======= 6/ I18nSetLocale logger start pairing =======
; =====================================================
; =====================================================

; Regression guard for F51 (AUDIT_AHK_2026-07-01.md): I18nSetLocale used to
; log Logger.start synchronously on EVERY call, before the debounce timer
; that performs the real reload. Two rapid switches ('fr'->'de'->'es') within
; _I18nReloadDebounceMs each logged a START, but re-arming SetTimer with the
; same function reference coalesces the pending call - only the LAST one
; ever fires _I18nDoReload, so only one SUCCESS was ever logged. The fix
; moves the LoggerStart call into _I18nDoReload, beside the LoggerSuccess it
; already logs, so a START is only ever logged once per reload attempt that
; actually completes.

_I18nSLP_SetLocaleOmitsStart() {
	Body := _DriverFuncBody("I18nSetLocale")
	AssertTrue(Body != "", "I18nSetLocale must be defined in core/i18n/engine/i18n.ahk")
	AssertTrue(InStr(Body, "LoggerStart") == 0,
		"I18nSetLocale must not call LoggerStart directly - it used to fire once per call regardless of debounce coalescing, leaving intermediate switches with an unpaired START")
}
Test("i18n I18nSetLocale: no longer logs LoggerStart at the call site (F51)", _I18nSLP_SetLocaleOmitsStart)

_I18nSLP_DoReloadLogsPair() {
	Body := _DriverFuncBody("_I18nDoReload")
	Ready := _DriverFuncBody("_I18nReloadReady")
	AssertTrue(Body != "", "_I18nDoReload must be defined in core/i18n/engine/i18n.ahk")
	AssertTrue(Ready != "", "_I18nReloadReady must be defined in core/i18n/engine/i18n.ahk")
	AssertTrue(InStr(Body, "LoggerStart") > 0,
		"_I18nDoReload must log LoggerStart right before the real reload work happens (F51)")
	AssertTrue(InStr(Body, "_I18nReloadReady.Bind") > 0,
		"_I18nDoReload must hand its terminal log to ReloadPreservingSuspend so marker publication failure cannot be reported as SUCCESS")
	AssertTrue(InStr(Ready, "LoggerSuccess") > 0,
		"the successful reload callback must complete the Start/Success pair immediately before Reload")
}
Test("i18n _I18nDoReload: logs a matched Start/Success pair (F51)", _I18nSLP_DoReloadLogsPair)

; Two rapid I18nSetLocale calls must not emit any "[i18n]" log line
; synchronously - both the log AND the reload are now entirely deferred to
; the debounce timer. This test deliberately never lets that timer fire
; (calling _I18nDoReload for real would invoke the AHK Reload command and
; restart the whole test process mid-suite) - it cancels the pending timer
; before returning, then asserts the call-time capture is empty.
_I18nSLP_RapidSwitchLogsNothingSynchronously() {
	global _I18nLocale, _I18nCacheLoaded, _I18nFallbacksWarmed
	_I18nLocale := "fr"
	_I18nCacheLoaded := true
	_I18nFallbacksWarmed := true

	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	I18nSetLocale("de")
	I18nSetLocale("es")
	LoggerClearTestSink()
	SetTimer(_I18nDoReload, 0)   ; cancel the pending debounce - never let Reload fire in tests

	I18nLines := 0
	for Line in Captured {
		if InStr(Line, "[i18n]")
			I18nLines += 1
	}
	AssertEqual(0, I18nLines,
		"two rapid I18nSetLocale calls must not log any [i18n] line synchronously - logging is deferred to the debounce timer (F51)")
	_I18nTestReset()
}
Test("i18n I18nSetLocale: rapid switches log nothing synchronously (F51)", _I18nSLP_RapidSwitchLogsNothingSynchronously)

; Actual locale JSON, parser, lazy public accessor and fast-cache ownership.
; Invalid shape is source failure, not a partial catalogue or a thrown menu.
_I18nShape_Case(Mode) {
	global _SharedDir, _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed, _I18nMissWarned
	Saved := [_SharedDir, _I18nLocale, _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity,
		_I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded,
		_I18nFallbacksWarmed, _I18nMissWarned]
	Root := A_Temp . "\ergopti_i18n_shape_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	PreviousCritical := Critical("Off")
	Owned := false
	Sources := Map("root-boolean", "true", "root-array", '["not a catalogue"]',
		"nested-value", '{"fixture.key":{"nested":"invalid"}}',
		"numeric-value", '{"fixture.key":7}', "legacy-numeric-cache", '{"fixture.key":7}', "null-value", '{"fixture.key":null}',
		"flat-control", '{"fixture.key":"valid translation"}', "empty-control", '{}')
	try {
		Created := FSCreateDirectoryExclusiveStrict(Root)
		Owned := Created is Integer && Created == 1
		AssertTrue(Owned, "Acquire the private root before creating or deleting any locale artifact")
		DirCreate(Root . "\core\i18n\data\locales")
		Path := Root . "\core\i18n\data\locales\de.json"
		AssertTrue(FSWriteCreateDurable(Path, Sources[Mode]))
		if Mode == "legacy-numeric-cache" {
			; Historical v1 caches stringify invalid numeric JSON, losing its
			; original type before the next boot can validate the source.
			; The cache sits beside its source, as _I18nLoadLocaleMap places it.
			Tsv := RegExReplace(Path, "\.json$", ".tsv")
			AssertTrue(FSWriteCreateDurable(Tsv, "fixture.key`t7`n#!ergopti-i18n-cache-v1 count=1`n"))
			FileSetTime("20000101000000", Path, "M")
			FileSetTime("20000102000000", Tsv, "M")
			AssertTrue(_I18nTsvIsFresh(Tsv, Path), "The real fast-cache freshness gate must admit the historical artefact")
		}
		_SharedDir := Root
		_I18nLocale := "de"
		_I18nCache := Map(), _I18nCacheLoaded := false, _I18nActiveCacheIdentity := false
		_I18nCacheEn := Map(), _I18nCacheEnLoaded := false
		_I18nCacheFr := Map(), _I18nCacheFrLoaded := false
		_I18nFallbacksWarmed := false, _I18nMissWarned := Map()
		; No replacement reader/parser/loader/translator is installed. A UI's
		; ordinary t() call must remain safe even when its file decodes to bad data.
		_TestPrint("# i18n-shape-enter mode=" . Mode . " source_exists=" . FSExists(Path))
		Actual := t("fixture.key")
		_TestPrint("# i18n-shape mode=" . Mode . " loaded=" . _I18nCacheLoaded
			. " result_type=" . Type(Actual) . " keys=" . _I18nCache.Count)
		AssertTrue(Actual is String)
		Valid := Mode == "flat-control" || Mode == "empty-control"
		AssertEqual(Valid, _I18nCacheLoaded, "Only a complete flat String-to-String source is a loaded catalogue")
		AssertEqual(Mode == "flat-control" ? "valid translation" : "fixture.key", Actual)
		if !Valid {
			AssertEqual(0, _I18nCache.Count, "An invalid entry cannot publish a partial active catalogue")
			if Mode == "legacy-numeric-cache"
				AssertEqual("fixture.key`t7`n#!ergopti-i18n-cache-v1 count=1`n", FSReadUtf8Exact(Tsv),
					"Refusing invalid source must not regenerate or bless its legacy cache")
			else
				AssertFalse(FSExists(RegExReplace(Path, "\.json$", ".tsv")), "An invalid JSON shape cannot be promoted into the self-healing fast cache")
		}
	} finally {
		_SharedDir := Saved[1], _I18nLocale := Saved[2]
		_I18nCache := Saved[3], _I18nCacheLoaded := Saved[4], _I18nActiveCacheIdentity := Saved[5]
		_I18nCacheEn := Saved[6], _I18nCacheEnLoaded := Saved[7]
		_I18nCacheFr := Saved[8], _I18nCacheFrLoaded := Saved[9]
		_I18nFallbacksWarmed := Saved[10], _I18nMissWarned := Saved[11]
		try {
			if Owned
				DirDelete(Root, true)
		} finally Critical(PreviousCritical)
	}
}
for _I18nShape_Mode in ["root-boolean", "root-array", "nested-value", "numeric-value", "null-value", "flat-control", "empty-control"]
	Test("i18n public lookup: " . _I18nShape_Mode . " preserves safe source fallback (i18n-source-shape)", _I18nShape_Case.Bind(_I18nShape_Mode))

Test("i18n public lookup: historical numeric cache cannot bypass source validation (i18n-source-shape)",
	_I18nShape_Case.Bind("legacy-numeric-cache"))


; The physical cache is an alternate representation of the same JSON object.
; A delimiter in a legal String key must not silently rename a translation.
_I18nKeyCacheRoundTrip(Mode) {
	Root := A_Temp . "\ergopti_i18n_key_cache_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Owned := false
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Owned := (Creation is Integer) && Creation == 1
		AssertTrue(Owned, "the case exclusively owns its native fixture directory")
		Path := Root . "\fixture.json", Tsv := Root . "\fixture.tsv"
		Key := "fixture.key", Value := "translation"
		switch Mode {
			case "tab-key", "legacy-v2-key":
				Json := '{"before\tafter":"translation"}'
				Key := "before`tafter"
			case "newline-key":
				Json := '{"before\nafter":"translation"}'
				Key := "before`nafter"
			case "carriage-key":
				Json := '{"before\rafter":"translation"}'
				Key := "before`rafter"
			case "backslash-key-control":
				Json := '{"before\\nafter":"translation"}'
				Key := "before\nafter"
			case "value-control":
				Json := '{"fixture.key":"before\tline\nnext\r\\n"}'
				Value := "before`tline`nnext`r\n"
			default:
				throw ValueError("Unknown locale cache key mode")
		}
		FileAppend(Json, Path, "UTF-8-RAW")
		AssertEqual(Json, FSReadUtf8Exact(Path), "the genuine loader receives exactly the authored JSON")
		Source := JsonParse(Json)
		AssertEqual(1, Source.Count)
		AssertTrue(Source.Has(Key), "the canonical parser admits the full key before the cache exists")
		AssertEqual(Value, Source[Key])
		Cold := _I18nLoadLocaleMap(Path, "★")
		AssertTrue(Cold.Ok)
		AssertFalse(Cold.Fast)
		AssertTrue(Cold.Cache.Has(Key))
		AssertEqual(Value, Cold.Cache[Key])
		AssertTrue(FSExists(Tsv), "the actual cold-load writer must publish its cache")
		if Mode == "legacy-v2-key" {
			FileDelete(Tsv)
			FileAppend(Key . "`t" . Value . "`n#!ergopti-i18n-cache-v2 count=1`n", Tsv, "UTF-8-RAW")
			AssertEqual(Key . "`t" . Value . "`n#!ergopti-i18n-cache-v2 count=1`n", FSReadUtf8Exact(Tsv))
		}
		FileSetTime("20000101000000", Path, "M")
		FileSetTime("20000101000002", Tsv, "M")
		AssertTrue(_I18nTsvIsFresh(Tsv, Path), "the real filesystem timestamps must admit the generated cache")
		Warm := _I18nLoadLocaleMap(Path, "★")
		_TestPrint("# i18n-key-cache mode=" . Mode . " warm_ok=" . Warm.Ok . " warm_fast=" . Warm.Fast
			. " expected_key_units=" . StrLen(Key) . " exact_key=" . Warm.Cache.Has(Key) . " count=" . Warm.Cache.Count)
		AssertTrue(Warm.Ok)
		AssertEqual(Mode != "legacy-v2-key", Warm.Fast, "historical delimiter-bearing keys require regeneration from authoritative JSON")
		AssertEqual(1, Warm.Cache.Count)
		AssertTrue(Warm.Cache.Has(Key), "a generated fast cache must preserve the complete canonical translation key")
		AssertEqual(Value, Warm.Cache[Key], "the same translation must survive a real cold-to-warm native reload")
	} finally {
		if Owned
			DirDelete(Root, true)
	}
}
for _I18nKeyCache_Mode in ["tab-key", "newline-key", "carriage-key", "backslash-key-control", "value-control", "legacy-v2-key"]
	Test("i18n cache key fidelity: " . _I18nKeyCache_Mode . " (i18n-cache-key-fidelity)", _I18nKeyCacheRoundTrip.Bind(_I18nKeyCache_Mode))

; The port substitutes only the user's regional-language observation. The
; supplied strings come from the real Windows locale API for named locales;
; no system language or region setting is changed by these probes.
_IDN_NativeIso(LocaleName) {
	Buf := Buffer(32, 0)
	Len := DllCall("Kernel32\GetLocaleInfoEx", "Str", LocaleName, "UInt", 0x59,
		"Ptr", Buf, "Int", 16, "Int")
	if Len <= 1
		throw OSError(A_LastError, "native named regional locale unavailable")
	return StrLower(StrGet(Buf, "UTF-16"))
}
class _IDN_LocaleProbe {
	__New(Region, UiRegion := "") {
		this.Region := Region, this.UiRegion := UiRegion, this.RegionalCalls := 0, this.UiCalls := 0
	}
	Regional() {
		this.RegionalCalls += 1
		return _IDN_NativeIso(this.Region)
	}
	Ui() {
		this.UiCalls += 1
		return this.UiRegion != "" ? _IDN_NativeIso(this.UiRegion) : _IDN_ActualUiIso()
	}
}
_IDN_InitFromRegion(Region, UiRegion := "", UseNative := false) {
	global _I18nLocale, _I18nCacheLoaded, _I18nFlagExistsCache
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, _LOGGER_VOLUME
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	SavedLocale := _I18nLocale, SavedLoaded := _I18nCacheLoaded
	HadFlags := IsSet(_I18nFlagExistsCache)
	SavedIconFlags := HadFlags ? _I18nFlagExistsCache : 0
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED", "_LOGGER_VOLUME"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := { Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0 }
	try {
		AssertFalse(SavedLogger.FlushActive, "no foreign logger flush may be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_VOLUME := _LOGGER_VOLUME.Clone()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		_I18nCacheLoaded := false
		Fixture := _IDN_LocaleProbe(Region, UiRegion)
		Critical("Off")
		if UseNative
			I18nInit(Map("script", Map("locale", "_")))
		else
			I18nInit(Map("script", Map("locale", "_")), Fixture)
		Observed := _I18nLocale
		return { Locale: Observed, Calls: Fixture.RegionalCalls + Fixture.UiCalls,
			RegionalCalls: Fixture.RegionalCalls, UiCalls: Fixture.UiCalls }
	} finally {
		Critical("On")
		_I18nLocale := SavedLocale, _I18nCacheLoaded := SavedLoaded
		_I18nFlagExistsCache := HadFlags ? SavedIconFlags : unset
		_TLOG_RestoreLoggerState(SavedLogger)
		for Name, Value in SavedExtra
			%Name% := Value
		for Name, Saved in SavedOptional
			%Name% := Saved.Present ? Saved.Value : unset
		Critical(PreviousCritical)
	}
}
_IDN_NorwegianCase(Region, NativeExpected, Expected) {
	Native := _IDN_NativeIso(Region)
	Result := _IDN_InitFromRegion(Region, Region)
	_TestAppendProgress("# i18n named=" . Region . " native=" . Native . " init=" . Result.Locale
		. " regional_calls=" . Result.RegionalCalls . " ui_calls=" . Result.UiCalls)
	AssertEqual(NativeExpected, Native, "the native named-locale observation is established")
	AssertEqual(1, Result.Calls, "real I18nInit observed the isolated native locale port")
	AssertEqual(Expected, Result.Locale, "the declared language or current fallback is selected")
}
; Both written forms read the one shipped Norwegian catalogue, as on macOS.
for _IDN_Row in [["nb-NO", "nb", "no"], ["nn-NO", "nn", "no"],
		["fr-FR", "fr", "fr"], ["en-US", "en", "en"]]
	Test("i18n: native named region " . _IDN_Row[1] . " follows declared locale policy (i18n-native-norwegian)",
		_IDN_NorwegianCase.Bind(_IDN_Row*))

_IDN_ActualUiIso() {
	LanguageId := DllCall("Kernel32\GetUserDefaultUILanguage", "UShort")
	if !LanguageId
		throw Error("Windows user UI language is unavailable.")
	Buf := Buffer(32, 0)
	Len := DllCall("Kernel32\GetLocaleInfoW", "UInt", LanguageId, "UInt", 0x59,
		"Ptr", Buf, "Int", 16, "Int")
	if Len <= 1
		throw OSError(A_LastError, "native UI language locale unavailable")
	return StrLower(StrGet(Buf, "UTF-16"))
}
_IDN_UiLanguageNotRegion() {
	global I18N_LOCALES
	UiCode := _IDN_ActualUiIso(), UiPrefix := SubStr(UiCode, 1, 2), Expected := "en"
	if UiPrefix == "nb"
		Expected := "no"
	else {
		for Locale in I18N_LOCALES {
			if Locale.Code == UiPrefix {
				Expected := UiPrefix
				break
			}
		}
	}
	Region := Expected == "fr" ? "en-US" : "fr-FR"
	RegionalCode := _IDN_NativeIso(Region)
	AssertTrue(RegionalCode != Expected, "the simulated regional reading differs from the actual UI language")
	Result := _IDN_InitFromRegion(Region)
	_TestAppendProgress("# i18n ui=" . UiCode . " expected=" . Expected . " named_region=" . Region
		. " regional=" . RegionalCode . " init=" . Result.Locale . " regional_calls=" . Result.RegionalCalls
		. " ui_calls=" . Result.UiCalls)
	AssertEqual(1, Result.Calls, "one native locale port was reached")
	AssertEqual(Expected, Result.Locale, "initial UI language follows the Windows UI language")
}
Test("i18n: initial UI language is independent of regional formats (i18n-native-ui-region)", _IDN_UiLanguageNotRegion)


_IDN_RealUserUiControl() {
	global I18N_LOCALES
	UiCode := _IDN_ActualUiIso(), UiPrefix := SubStr(UiCode, 1, 2), Expected := "en"
	if UiPrefix == "nb"
		Expected := "no"
	else {
		for Locale in I18N_LOCALES {
			if Locale.Code == UiPrefix {
				Expected := UiPrefix
				break
			}
		}
	}
	Result := _IDN_InitFromRegion("", "", true)
	_TestAppendProgress("# i18n native-default ui=" . UiCode . " expected=" . Expected
		. " init=" . Result.Locale . " port_calls=" . Result.Calls)
	AssertEqual(0, Result.Calls, "the genuine default adapter is used")
	AssertEqual(Expected, Result.Locale, "real I18nInit follows the current user UI language")
}
Test("i18n: default native path follows current user UI language (i18n-native-ui-default)", _IDN_RealUserUiControl)

#Include test_cache_stage_custody.ahk
