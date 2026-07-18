; lib/locale.ahk

; ==============================================================================
; MODULE: Locale (string loading)
; DESCRIPTION:
; Loads UI string translations from the shared JSON locale files in
; ``_shared/data/locales/<code>.json`` (through a self-healing .tsv fast-cache)
; and exposes a single ``t(key)`` accessor returning the localised string for a
; dot-notation key, with the ``★`` placeholder substituted by the configured
; MagicKey. Mirror of ``macos/lib/locale.lua``: this is the string-LOADING +
; access layer; locale MANAGEMENT (selection, system detection, persistence,
; language menu) lives in the sibling ``lib/i18n.ahk``.
;
; FEATURES & RATIONALE:
; 1. Shared source of truth: the same JSON files feed the Hammerspoon driver,
;    so ``_shared/data/locales/`` is the one place UI strings are defined.
; 2. Lazy load + self-healing cache: only the active locale is parsed at boot;
;    the EN/FR fallbacks are warmed off the critical path. Each locale is served
;    from a flat .tsv regenerated whenever the .json is newer (~23x faster than
;    re-parsing the JSON for the identical key/value set).
; 3. ★ substitution at parse time so the cache stays MagicKey-independent.
; ==============================================================================





; ===============================
; ===============================
; ======= 1/ Module state =======
; ===============================
; ===============================

; Active locale code — read from config.toml at boot (by I18nInit in i18n.ahk),
; then kept in memory and consulted here to know which locale file to load.
global _I18nLocale := "fr"

; Flat map of key → translated string for the active locale. Populated lazily.
global _I18nCache := Map()
global _I18nCacheLoaded := false

; Fallback caches: English first, French second.
global _I18nCacheEn := Map()
global _I18nCacheEnLoaded := false
global _I18nCacheFr := Map()
global _I18nCacheFrLoaded := false

; True once the EN/FR fallback caches have been warmed — eagerly by the deferred
; I18nWarmFallbacks timer, or lazily on the first active-locale miss inside t().
; Keeps t() O(1) on misses (no re-entry into _I18nEnsureFallbacksLoaded).
global _I18nFallbacksWarmed := false





; =================================
; =================================
; ======= 2/ Locale loading =======
; =================================
; =================================

; Resolve the absolute path to a locale JSON file given a locale code.
; Uses _SharedDir (computed in ErgoptiPlus.ahk) to reach _shared/data/locales/.
_I18nLocalePath(Code) {
	global _SharedDir
	return _SharedDir . "\data\locales\" . Code . ".json"
}

; Invert _I18nWriteTsvCache's value escaping in a single left-to-right scan so
; "\\" never collides with "\n"/"\r". Only called for values that contain a
; backslash, so the common case pays nothing.
_I18nUnescapeTSV(s) {
	out := ""
	i := 1
	len := StrLen(s)
	while (i <= len) {
		c := SubStr(s, i, 1)
		if (c == "\" and i < len) {
			n := SubStr(s, i + 1, 1)
			if (n == "n") {
				out .= "`n"
				i += 2
				continue
			}
			if (n == "r") {
				out .= "`r"
				i += 2
				continue
			}
			if (n == "\") {
				out .= "\"
				i += 2
				continue
			}
		}
		out .= c
		i += 1
	}
	return out
}

; Parse a flat locale .tsv (one "key<TAB>value" record per line) into a Map,
; unescaping values and substituting ★ with the configured MagicKey — the same
; post-processing the JSON path applies. A tight Loop Parse keeps this ~23x faster
; than the recursive-descent JsonParse for the identical key/value set.
_I18nParseTSV(Content, MagicKey) {
	m := Map()
	Loop Parse Content, "`n", "`r" {
		line := A_LoopField
		if (line == "")
			continue
		p := InStr(line, "`t")
		if (!p)
			continue
		k := SubStr(line, 1, p - 1)
		v := SubStr(line, p + 1)
		if InStr(v, "\")
			v := _I18nUnescapeTSV(v)
		if InStr(v, "★")
			v := StrReplace(v, "★", MagicKey)
		m[k] := v
	}
	return m
}

; True when the .tsv cache is at least as new as its .json source — i.e. it is
; not stale after a .json edit or pull. FileGetTime's "M" form is YYYYMMDDHH24MISS,
; which orders chronologically as a plain integer, so a direct >= comparison is
; correct. Any stat failure returns false so the caller regenerates defensively.
_I18nTsvIsFresh(TsvPath, JsonPath) {
	try {
		return FileGetTime(TsvPath, "M") >= FileGetTime(JsonPath, "M")
	} catch {
		return false
	}
}

; (Re)write the flat key<TAB>value .tsv cache from a parsed locale map. The .tsv
; is a gitignored, self-healing cache the driver owns end-to-end — the .json is
; the single tracked source of truth, never duplicated in git. Values are escaped
; \\ then \r then \n (backslash FIRST so it can never collide), ★ placeholders are
; PRESERVED (the reader substitutes the MagicKey at parse time, keeping the cache
; MagicKey-independent), LF line endings, UTF-8 without BOM. Best-effort: a
; read-only install directory simply means every boot keeps parsing the JSON.
_I18nWriteTsvCache(TsvPath, Parsed) {
	try {
		Content := ""
		for Key, Val in Parsed {
			Esc := Val
			if InStr(Esc, "\")
				Esc := StrReplace(Esc, "\", "\\")
			if InStr(Esc, "`r")
				Esc := StrReplace(Esc, "`r", "\r")
			if InStr(Esc, "`n")
				Esc := StrReplace(Esc, "`n", "\n")
			Content .= Key . "`t" . Esc . "`n"
		}
		if FileExist(TsvPath)
			FileDelete(TsvPath)
		FileAppend(Content, TsvPath, "UTF-8-RAW")
	} catch as err {
		try LoggerWarn("i18n", "Could not write fast-cache '{1}' ({2}); JSON path stays active.", TsvPath, err.Message)
	}
}

; Load one locale's flat key→value Map using the self-healing .tsv cache: parse
; the fast .tsv when it exists AND is at least as new as the .json; otherwise
; parse the .json (the single source of truth), build the Map, and regenerate the
; .tsv beside it so the NEXT boot is fast. ★ is substituted with MagicKey on both
; paths. This is the ONLY site that reads or writes a locale .tsv, so the cache
; format lives in exactly one place.
;
; Returns ``{ Cache, Ok, Fast }``: Cache is the (possibly empty) map; Ok is true
; whenever a source was parsed successfully — INCLUDING a valid but empty ``{}``,
; which is distinct from a missing/unparseable file (Ok false → caller shows raw
; key names); Fast records whether the .tsv cache was hit, for log clarity only.
_I18nLoadLocaleMap(JsonPath, MagicKey) {
	TsvPath := RegExReplace(JsonPath, "\.json$", ".tsv")

	; ── Fast path: a fresh .tsv cache ──
	if FileExist(TsvPath) and _I18nTsvIsFresh(TsvPath, JsonPath) {
		try {
			return { Cache: _I18nParseTSV(FileRead(TsvPath, "UTF-8"), MagicKey), Ok: true, Fast: true }
		} catch as err {
			try LoggerWarn("i18n", "Fast cache '{1}' unreadable ({2}); rebuilding from JSON.", TsvPath, err.Message)
		}
	}

	; ── Slow path: parse JSON, then regenerate the cache for next boot ──
	if !FileExist(JsonPath) {
		try LoggerWarn("i18n", "Locale file not found: '{1}' — falling back to key names.", JsonPath)
		return { Cache: Map(), Ok: false, Fast: false }
	}
	try {
		; FileRead keeps a UTF-8 BOM in some AHK builds.  Locale sources are
		; allowed to carry one, so remove it before handing the document to the
		; JSON parser.  Otherwise a cache miss after an update makes every key
		; disappear until a manually regenerated .tsv cache exists.
		RawJson := FileRead(JsonPath, "UTF-8")
		if (StrLen(RawJson) && Ord(SubStr(RawJson, 1, 1)) = 0xFEFF)
			RawJson := SubStr(RawJson, 2)
		Parsed := JsonParse(RawJson)
	} catch as err {
		try LoggerWarn("i18n", "JSON parse error in '{1}': {2}", JsonPath, err.Message)
		return { Cache: Map(), Ok: false, Fast: false }
	}
	Out := Map()
	for Key, Val in Parsed {
		if InStr(Val, "★")
			Out[Key] := StrReplace(Val, "★", MagicKey)
		else
			Out[Key] := Val
	}
	; Regenerate from the RAW parsed values (★ preserved) so the cache mirrors the
	; source exactly and stays MagicKey-independent.
	_I18nWriteTsvCache(TsvPath, Parsed)
	return { Cache: Out, Ok: true, Fast: false }
}

; Populate _I18nCache for the active locale from FilePath's .json, via the
; self-healing .tsv cache (see _I18nLoadLocaleMap). Substitutes ★ with the
; configured MagicKey. Leaves the cache empty (caller shows raw key names) on a
; missing/unparseable source.
_I18nLoadFile(FilePath) {
	global _I18nCache, _I18nCacheLoaded, _I18nLocale, ScriptInformation
	MagicKey := IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")
		? ScriptInformation["MagicKey"]
		: "★"
	R := _I18nLoadLocaleMap(FilePath, MagicKey)
	_I18nCache := R.Cache
	_I18nCacheLoaded := R.Ok
	if R.Ok
		try LoggerDone("i18n", "Locale '{1}' loaded ({2} key(s), {3}).", _I18nLocale, _I18nCache.Count,
			R.Fast ? "fast" : "regenerated")
}

; Load a fallback locale into a provided Map reference via the same self-healing
; .tsv cache as the active locale. Sets Loaded true once the map is populated.
_I18nLoadInto(Code, &Cache, &Loaded) {
	if Loaded
		return
	global ScriptInformation
	MagicKey := IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")
		? ScriptInformation["MagicKey"] : "★"
	R := _I18nLoadLocaleMap(_I18nLocalePath(Code), MagicKey)
	Cache := R.Cache
	Loaded := R.Ok
}

; Ensure ONLY the active locale is loaded — the minimum the tray menu needs at
; boot. Kept separate from the fallback load so boot pays one JSON parse, not two.
_I18nEnsureActiveLoaded() {
	global _I18nCacheLoaded, _I18nLocale
	if !_I18nCacheLoaded
		_I18nLoadFile(_I18nLocalePath(_I18nLocale))
}

; Ensure the EN (then FR) fallback caches are loaded. Consulted by t() only when
; a key is missing from the active locale. Idempotent: the per-cache Loaded flags
; make repeat calls cheap, and _I18nFallbacksWarmed short-circuits t() afterwards.
_I18nEnsureFallbacksLoaded() {
	global _I18nLocale, _I18nFallbacksWarmed
	global _I18nCacheEn, _I18nCacheEnLoaded
	global _I18nCacheFr, _I18nCacheFrLoaded
	if _I18nLocale != "en" and !_I18nCacheEnLoaded
		_I18nLoadInto("en", &_I18nCacheEn, &_I18nCacheEnLoaded)
	if _I18nLocale != "fr" and !_I18nCacheFrLoaded
		_I18nLoadInto("fr", &_I18nCacheFr, &_I18nCacheFrLoaded)
	_I18nFallbacksWarmed := true
}

; Ensure the active locale and both fallback locales are loaded.
_I18nEnsureLoaded() {
	_I18nEnsureActiveLoaded()
	_I18nEnsureFallbacksLoaded()
}




; =============================
; =============================
; ======= 3/ Accessor =========
; =============================
; =============================

; Returns the localised string for the given dot-notation key.
; Falls back to the raw key name if the locale file is missing or the key is absent.
t(Key) {
	global _I18nCache, _I18nCacheLoaded, _I18nFallbacksWarmed
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	if !_I18nCacheLoaded
		_I18nEnsureActiveLoaded()
	; An empty-string value is treated as MISSING at every cascade level, so it
	; falls through to the next locale instead of shadowing a real fallback. This
	; matches the shared golden corpus (locale/resolution_vectors.json) and the
	; macOS locale.core cascade — cross-driver parity (an untranslated "" entry
	; must resolve to the fallback, not to an empty string).
	if _I18nCache.Has(Key) and _I18nCache[Key] != ""
		return _I18nCache[Key]
	; Miss in the active locale → consult the fallbacks. They are warmed off the
	; boot path (I18nWarmFallbacks); if a miss arrives first, load them once now.
	if !_I18nFallbacksWarmed
		_I18nEnsureFallbacksLoaded()
	if _I18nCacheEnLoaded and _I18nCacheEn.Has(Key) and _I18nCacheEn[Key] != ""
		return _I18nCacheEn[Key]
	if _I18nCacheFrLoaded and _I18nCacheFr.Has(Key) and _I18nCacheFr[Key] != ""
		return _I18nCacheFr[Key]
	return Key
}
