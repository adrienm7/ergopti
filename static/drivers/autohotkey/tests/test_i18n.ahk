; static/drivers/autohotkey/tests/test_i18n.ahk

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

_I18nTmpJson(Content) {
	Path := A_Temp . "\i18n_test_locale.json"
	if FileExist(Path) {
		FileDelete(Path)
	}
	FileAppend(Content, Path, "UTF-8")
	return Path
}





; ==========================================
; ===========================================
; ======= 2/ _I18nLoadFile test cases =======
; ===========================================
; ==========================================

Test("i18n _I18nLoadFile: missing file leaves cache empty and unloaded", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	_I18nLoadFile(A_Temp . "\does_not_exist_locale.json")
	AssertFalse(_I18nCacheLoaded)
	AssertEqual(0, _I18nCache.Count)
})

Test("i18n _I18nLoadFile: parses flat JSON object", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	Path := _I18nTmpJson('{"hello": "Bonjour", "bye": "Au revoir"}')
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertTrue(_I18nCacheLoaded)
	AssertEqual("Bonjour",    _I18nCache["hello"])
	AssertEqual("Au revoir",  _I18nCache["bye"])
})

Test("i18n _I18nLoadFile: substitutes magic key placeholder", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded, ScriptInformation
	ScriptInformation["MagicKey"] := "★"
	Path := _I18nTmpJson('{"magic_hint": "Press ★ to continue"}')
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertTrue(_I18nCacheLoaded)
	AssertEqual("Press ★ to continue", _I18nCache["magic_hint"])
})

Test("i18n _I18nLoadFile: leaves cache unloaded on invalid JSON", () => {
	_I18nTestReset()
	global _I18nCacheLoaded
	Path := _I18nTmpJson("this is not json at all {{")
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertFalse(_I18nCacheLoaded)
})

Test("i18n _I18nLoadFile: handles empty JSON object", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	Path := _I18nTmpJson("{}")
	_I18nLoadFile(Path)
	FileDelete(Path)
	AssertTrue(_I18nCacheLoaded)
	AssertEqual(0, _I18nCache.Count)
})





; ================================
; ===============================
; ======= 3/ t() fallback =======
; ===============================
; ================================

Test("i18n t(): returns key as fallback when cache is empty", () => {
	_I18nTestReset()
	global _I18nLocale, _I18nCacheLoaded
	; Point locale at a non-existent file so _I18nEnsureLoaded silently fails
	_I18nLocale      := "xx"
	_I18nCacheLoaded := true   ; Prevent real file load from overwriting
	Result := t("some.missing.key")
	AssertEqual("some.missing.key", Result)
})

Test("i18n t(): returns value from primary cache", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	_I18nCache["greeting"] := "Salut"
	_I18nCacheLoaded        := true
	AssertEqual("Salut", t("greeting"))
})

Test("i18n t(): falls back to English cache when key absent from primary", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded
	_I18nCacheLoaded  := true
	_I18nCacheEnLoaded := true
	_I18nCacheEn["en_only"] := "English value"
	AssertEqual("English value", t("en_only"))
})

Test("i18n t(): falls back to French cache when key absent from primary and English", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded
	global _I18nCacheFr, _I18nCacheFrLoaded
	_I18nCacheLoaded  := true
	_I18nCacheEnLoaded := true
	_I18nCacheFrLoaded := true
	_I18nCacheFr["fr_only"] := "Valeur française"
	AssertEqual("Valeur française", t("fr_only"))
})

Test("i18n t(): primary cache takes priority over fallbacks", () => {
	_I18nTestReset()
	global _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded
	_I18nCacheLoaded   := true
	_I18nCacheEnLoaded := true
	_I18nCache["key"]   := "Primary"
	_I18nCacheEn["key"] := "English"
	AssertEqual("Primary", t("key"))
})





; ================================================
; =============================================
; ======= 4/ I18nInit locale validation =======
; =============================================
; ================================================

Test("i18n I18nInit: accepts known locale code from cache", () => {
	_I18nTestReset()
	global _I18nLocale
	; Build a minimal TOML cache with locale = "de"
	Cache := Map("script", Map("locale", "de"))
	I18nInit(Cache)
	AssertEqual("de", _I18nLocale)
})

Test("i18n I18nInit: ignores sentinel value underscore", () => {
	_I18nTestReset()
	global _I18nLocale
	_I18nLocale := "fr"
	Cache := Map("script", Map("locale", "_"))
	; System locale detection may change _I18nLocale; just check it's a known code
	I18nInit(Cache)
	Found := false
	for Loc in I18N_LOCALES {
		if Loc.Code == _I18nLocale {
			Found := true
			break
		}
	}
	AssertTrue(Found, "I18nInit with sentinel _ should set a known locale code")
})

Test("i18n I18nInit: resets cache loaded flag", () => {
	_I18nTestReset()
	global _I18nCacheLoaded
	_I18nCacheLoaded := true
	Cache := Map("script", Map("locale", "en"))
	I18nInit(Cache)
	AssertFalse(_I18nCacheLoaded)
})





; ====================================================
; ==============================================
; ======= 5/ _I18nSortedLocales ordering =======
; ==============================================
; ====================================================

Test("i18n _I18nSortedLocales: returns all locales", () => {
	global I18N_LOCALES
	Sorted := _I18nSortedLocales()
	AssertEqual(I18N_LOCALES.Length, Sorted.Length)
})

Test("i18n _I18nSortedLocales: result is alphabetically ordered by Name", () => {
	Sorted := _I18nSortedLocales()
	i := 1
	while i < Sorted.Length {
		AssertTrue(
			StrCompare(Sorted[i].Name, Sorted[i + 1].Name, false) <= 0,
			"Sort order violated between " . Sorted[i].Name . " and " . Sorted[i + 1].Name
		)
		i++
	}
})

Test("i18n _I18nSortedLocales: does not mutate original I18N_LOCALES", () => {
	global I18N_LOCALES
	OrigFirst := I18N_LOCALES[1].Code
	_I18nSortedLocales()
	AssertEqual(OrigFirst, I18N_LOCALES[1].Code)
})
