; static/ergopti_plus/windows/tests/unit/test_i18n.ahk

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
	_I18nCache        := Map()
	_I18nCacheLoaded  := false
	_I18nCacheEn      := Map()
	_I18nCacheEnLoaded := false
	_I18nCacheFr      := Map()
	_I18nCacheFrLoaded := false
	_I18nFallbacksWarmed := false
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
		DirCreate(Root . "\data\locales")
		_SharedDir := Root
		_I18nLocale := "de"
		_I18nTestReset()

		_I18nEnsureFallbacksLoaded()
		AssertFalse(_I18nFallbacksWarmed,
			"failed fallback loads must remain retryable")
		AssertFalse(_I18nCacheEnLoaded)
		AssertFalse(_I18nCacheFrLoaded)

		FileAppend('{"retry.key": "English"}',
			Root . "\data\locales\en.json", "UTF-8")
		FileAppend('{"retry.key": "Francais"}',
			Root . "\data\locales\fr.json", "UTF-8")
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
	AssertTrue(Body != "", "I18nSetLocale must be defined in infra/i18n.ahk")
	AssertTrue(InStr(Body, "LoggerStart") == 0,
		"I18nSetLocale must not call LoggerStart directly - it used to fire once per call regardless of debounce coalescing, leaving intermediate switches with an unpaired START")
}
Test("i18n I18nSetLocale: no longer logs LoggerStart at the call site (F51)", _I18nSLP_SetLocaleOmitsStart)

_I18nSLP_DoReloadLogsPair() {
	Body := _DriverFuncBody("_I18nDoReload")
	Ready := _DriverFuncBody("_I18nReloadReady")
	AssertTrue(Body != "", "_I18nDoReload must be defined in infra/i18n.ahk")
	AssertTrue(Ready != "", "_I18nReloadReady must be defined in infra/i18n.ahk")
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
