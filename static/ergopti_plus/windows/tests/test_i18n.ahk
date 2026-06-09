; static/ergopti_plus/windows/tests/test_i18n.ahk

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
	_I18nCache        := Map()
	_I18nCacheLoaded  := false
	_I18nCacheEn      := Map()
	_I18nCacheEnLoaded := false
	_I18nCacheFr      := Map()
	_I18nCacheFrLoaded := false
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






; ==========================================
; ===========================================
; ======= 2/ _I18nLoadFile test cases =======
; ===========================================
; ==========================================

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






; ================================
; ===============================
; ======= 3/ t() fallback =======
; ===============================
; ================================

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






; ================================================
; =============================================
; ======= 4/ I18nInit locale validation =======
; =============================================
; ================================================

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






; ====================================================
; ==============================================
; ======= 5/ _I18nSortedLocales ordering =======
; ==============================================
; ====================================================

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
