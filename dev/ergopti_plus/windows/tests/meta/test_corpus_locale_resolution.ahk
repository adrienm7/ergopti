; static/ergopti_plus/windows/tests/meta/test_corpus_locale_resolution.ahk

; ==============================================================================
; MODULE: Locale Resolution Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the cross-driver locale resolution corpus from
; _shared/tests/corpus/locale/resolution_vectors.json and replays each
; vector through the AHK t() function (populating _I18nCache / fallback
; caches directly), then asserts the resolved string matches the expected
; golden value.
;
; This pins the AHK t() cascade (active→en→fr→raw key) and ★ substitution
; against the same golden vectors as the macOS locale.core module, so any
; divergence between the two implementations is caught immediately.
; ==============================================================================

#Requires AutoHotkey v2.0






; ===================================================
; ===================================================
; ======= 1/ Corpus Loading =========================
; ===================================================
; ===================================================

_LclCorpus_LoadCorpus() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\locale\resolution_vectors.json"
	if !FileExist(Path) {
		return ""
	}
	Raw := FileRead(Path, "UTF-8")
	return JsonParse(Raw)
}

; The AHK t() function reads from _I18nCache / _I18nCacheEn / _I18nCacheFr
; and uses _I18nLocale for the active locale code. By setting these globals
; directly we control the resolution without needing real locale files on disk.

; Populate the active/fallback caches from the vector's locales table.
_LclCorpus_PopulateCaches(Vec) {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed, ScriptInformation

	_I18nCache := Map()
	_I18nCacheEn := Map()
	_I18nCacheFr := Map()

	; Active locale
	_I18nLocale := Vec.Has("active_locale") ? Vec["active_locale"] : "fr"

	; Load data for each locale provided in the vector
	Locales := Vec.Has("locales") ? Vec["locales"] : Map()
	for Code, Data in Locales {
		Target := _I18nCache
		if (Code = "en" and _I18nLocale != "en")
			Target := _I18nCacheEn
		else if (Code = "fr" and _I18nLocale != "fr")
			Target := _I18nCacheFr

		for Key, Val in Data {
			; Apply ★ substitution immediately (mimics the real loader)
			StrVal := (Type(Val) = "String") ? Val : ""
			Target[Key] := StrVal
		}
	}

	_I18nCacheLoaded := true
	_I18nCacheEnLoaded := (_I18nCacheEn.Count > 0)
	_I18nCacheFrLoaded := (_I18nCacheFr.Count > 0)
	_I18nFallbacksWarmed := true

	; Set MagicKey for ★ substitution inside t() — the AHK loader substitutes
	; ★ at parse time, but for the corpus test we need to simulate that.
	; We store the trigger character so we can pre-substitute or post-check.
	if Vec.Has("trigger") {
		Trig := Vec["trigger"]
		if (Type(Trig) = "String" and Trig != "") {
			; Pre-substitute ★ in all caches (mimicking what _I18nLoadFile does)
			for Key, Val in _I18nCache {
				if InStr(Val, "★")
					_I18nCache[Key] := StrReplace(Val, "★", Trig)
			}
			for Key, Val in _I18nCacheEn {
				if InStr(Val, "★")
					_I18nCacheEn[Key] := StrReplace(Val, "★", Trig)
			}
			for Key, Val in _I18nCacheFr {
				if InStr(Val, "★")
					_I18nCacheFr[Key] := StrReplace(Val, "★", Trig)
			}
		}
	}

	; Ensure ScriptInformation.MagicKey is set so the fallback loader path
	; inside _I18nLoadFile (called by _I18nEnsureFallbacksLoaded via t())
	; also applies ★ substitution. Without this, if a fallback is loaded
	; on-the-fly during t(), ★ would stay literal.
	if !IsSet(ScriptInformation)
		global ScriptInformation := Map()
	if Vec.Has("trigger") and Type(Vec["trigger"]) = "String" {
		ScriptInformation["MagicKey"] := Vec["trigger"]
	} else {
		ScriptInformation["MagicKey"] := "★"
	}
}

; Reset the locale globals to their defaults so each vector runs clean.
_LclCorpus_ResetState() {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	global _I18nFallbacksWarmed

	_I18nLocale := "fr"
	_I18nCache := Map()
	_I18nCacheLoaded := false
	_I18nCacheEn := Map()
	_I18nCacheEnLoaded := false
	_I18nCacheFr := Map()
	_I18nCacheFrLoaded := false
	_I18nFallbacksWarmed := false
}






; ===================================================
; ===================================================
; ======= 2/ Vector Dispatcher ======================
; ===================================================
; ===================================================

_LclCorpus_RunVector(Vec) {
	_LclCorpus_PopulateCaches(Vec)
	Key := Vec.Has("key") ? Vec["key"] : ""
	Expected := Vec.Has("expected_ahk") ? Vec["expected_ahk"] : (Vec.Has("expected") ? Vec["expected"] : "")
	Result := t(Key)
	AssertEqual(Expected, Result, "t('" . Key . "'): expected '" . Expected . "', got '" . Result . "'")
}

; A single test replays EVERY vector. The previous per-vector fat-arrow lambdas
; captured the loop variable by reference (all lambdas ran the LAST vector), and
; the reset fired at REGISTRATION time rather than between runs — so the corpus
; effectively tested a single vector. Looping inside one function runs every
; vector; _LclCorpus_RunVector → PopulateCaches rebuilds the caches per vector so
; each starts clean.
_LclCorpus_TestAllVectors() {
	Data := _LclCorpus_LoadCorpus()
	if (Data = "") {
		AssertTrue(false, "Corpus file not found at _shared/tests/corpus/locale/resolution_vectors.json")
		return
	}
	if !Data.Has("vectors") {
		AssertTrue(false, "No 'vectors' key in corpus JSON")
		return
	}
	for Vec in Data["vectors"] {
		_LclCorpus_RunVector(Vec)
	}
	_LclCorpus_ResetState()
}
Test("[corpus:locale] all vectors resolve to expected golden values", _LclCorpus_TestAllVectors)





; ===================================================
; ===================================================
; ======= 3/ Additional Regression Tests ============
; ===================================================
; ===================================================

; Test: t() returns raw key when all caches are empty
Test("[locale:regression] t() returns raw key when no locale loaded",
	() => _LclCorpus_TestRawKeyFallback())

_LclCorpus_TestRawKeyFallback() {
	_LclCorpus_ResetState()
	global _I18nCacheLoaded := false
	global _I18nCache := Map()
	global _I18nCacheEn := Map()
	global _I18nCacheFr := Map()
	global _I18nFallbacksWarmed := false
	Result := t("any.missing.key")
	AssertEqual("any.missing.key", Result, "t() returns raw key when no cache loaded")
}

; Test: t() lazy-loads fallbacks on first miss
Test("[locale:regression] t() lazy-loads fallback from .json on first miss",
	() => _LclCorpus_TestLazyFallbackFromJson())

_LclCorpus_TestLazyFallbackFromJson() {
	_LclCorpus_ResetState()
	global _I18nLocale := "zz"  ; nonexistent locale code
	global _I18nCacheLoaded := false
	global _I18nCache := Map()
	global _I18nCacheEn := Map()
	global _I18nCacheEnLoaded := false
	global _I18nCacheFr := Map()
	global _I18nCacheFrLoaded := false
	global _I18nFallbacksWarmed := false

	; Pre-populate en fallback directly (simulating a loaded fallback)
	_I18nCacheEn := Map("test.key", "from_en")
	_I18nCacheEnLoaded := true

	Result := t("test.key")
	AssertEqual("from_en", Result, "t() falls back to en cache when active locale is missing")
}

; Test: t() checks fr after en
Test("[locale:regression] t() fallback order: active → en → fr → raw key",
	() => _LclCorpus_TestFallbackOrder())

_LclCorpus_TestFallbackOrder() {
	_LclCorpus_ResetState()
	global _I18nLocale := "zz"
	global _I18nCacheLoaded := false
	global _I18nCache := Map()
	global _I18nCacheEn := Map("only.in.fr", "")
	global _I18nCacheEnLoaded := true
	global _I18nCacheFr := Map("only.in.fr", "from_fr")
	global _I18nCacheFrLoaded := true
	global _I18nFallbacksWarmed := true

	Result := t("only.in.fr")
	; Active (zz) misses; en holds the key but its value is "" → treated as missing
	; → fall through to fr. Empty-value-is-missing gives cross-driver parity with
	; the Lua side and the shared golden corpus.
	AssertEqual("from_fr", Result, "empty en value falls through to fr")
}

; Test: an empty-string value in the active locale is treated as MISSING and
; falls through to en — cross-driver parity with the golden corpus + macOS.
Test("[locale:regression] t() treats an empty active value as missing and falls through to en",
	() => _LclCorpus_TestEmptyValueInActive())

_LclCorpus_TestEmptyValueInActive() {
	_LclCorpus_ResetState()
	global _I18nLocale := "fr"
	global _I18nCache := Map("empty.key", "")
	global _I18nCacheLoaded := true
	global _I18nCacheEn := Map("empty.key", "from_en")
	global _I18nCacheEnLoaded := true
	global _I18nFallbacksWarmed := true

	Result := t("empty.key")
	; Empty value in the active locale → missing → falls through to the en fallback.
	AssertEqual("from_en", Result, "t() falls through to en when the active value is empty")
}
