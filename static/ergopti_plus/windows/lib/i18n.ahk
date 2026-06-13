; drivers/autohotkey/lib/i18n.ahk

; ==============================================================================
; MODULE: i18n (Internationalisation)
; DESCRIPTION:
; Manages the active UI locale for the AHK driver. Exposes a single ``t(key)``
; accessor that returns the localised string for the given dot-notation key,
; substituting the configured MagicKey for any ``★`` placeholder.
;
; FEATURES & RATIONALE:
; 1. Lazy Load: The JSON locale file is read at most once per session; a
;    subsequent ``I18nSetLocale`` call clears the cache so the next ``t()``
;    call re-reads the new file.
; 2. Persistence: The active locale code is written to ``[Script] Locale`` in
;    ``ahk/config.toml`` via the shared TOML_BatchWrite helper, then the script
;    reloads so all menus are rebuilt in the new language.
; 3. Language selector: ``I18nBuildLanguageMenu`` populates any AHK ``Menu``
;    object with one item per supported locale, with a check mark on the active
;    one. Callers pass their ``Menu`` object and the submenu is ready to use.
; 4. Shared locale files: The JSON files live in ``static/locales/`` and are
;    the single source of truth shared with the Hammerspoon driver.
; ==============================================================================





; ============================================
; =============================================
; ======= 1/ Constants and module state =======
; =============================================
; ============================================

; Ordered list of supported locales: { Code, Flag, Name }
; Tag = short code shown in radio buttons (flag emojis don't render on Windows)
global I18N_LOCALES := [
	{ Code: "ar", Tag: "[AR]", Name: "العربية"    },
	{ Code: "cs", Tag: "[CS]", Name: "Čeština"    },
	{ Code: "da", Tag: "[DA]", Name: "Dansk"       },
	{ Code: "de", Tag: "[DE]", Name: "Deutsch"     },
	{ Code: "en", Tag: "[EN]", Name: "English"     },
	{ Code: "es", Tag: "[ES]", Name: "Español"     },
	{ Code: "fr", Tag: "[FR]", Name: "Français"    },
	{ Code: "he", Tag: "[HE]", Name: "עברית"       },
	{ Code: "hi", Tag: "[HI]", Name: "हिन्दी"      },
	{ Code: "it", Tag: "[IT]", Name: "Italiano"    },
	{ Code: "ja", Tag: "[JA]", Name: "日本語"       },
	{ Code: "ko", Tag: "[KO]", Name: "한국어"       },
	{ Code: "nl", Tag: "[NL]", Name: "Nederlands"  },
	{ Code: "no", Tag: "[NO]", Name: "Norsk"        },
	{ Code: "pl", Tag: "[PL]", Name: "Polski"       },
	{ Code: "pt", Tag: "[PT]", Name: "Português"   },
	{ Code: "ru", Tag: "[RU]", Name: "Русский"      },
	{ Code: "sv", Tag: "[SV]", Name: "Svenska"      },
	{ Code: "tr", Tag: "[TR]", Name: "Türkçe"       },
	{ Code: "uk", Tag: "[UK]", Name: "Українська"   },
	{ Code: "zh", Tag: "[ZH]", Name: "中文"          },
]

; Active locale code — read from config.toml at boot, then kept in memory.
global _I18nLocale := "fr"

; Debounce delay for locale-change reloads (ms).
; Rapid language switches cancel the pending reload so only the last
; selected locale triggers a script restart.
global _I18nReloadDebounceMs := 150

; Delay (ms) before warming the EN/FR fallback caches off the boot critical path.
; Only the active locale is parsed eagerly at boot (the tray menu needs it); the
; fallbacks — consulted solely when a key is missing from the active locale — are
; warmed shortly after "ready" so they never cost the user boot latency. A miss
; that arrives before this timer fires triggers a one-time lazy load inside t().
global I18N_FALLBACK_WARM_DELAY_MS := 200

; Flat map of key → translated string for the active locale. Populated lazily.
global _I18nCache := Map()
global _I18nCacheLoaded := false

; Cached sorted locale list for the menu
global _I18nSortedLocalesCache := false

; Fallback caches: English first, French second.
global _I18nCacheEn := Map()
global _I18nCacheEnLoaded := false
global _I18nCacheFr := Map()
global _I18nCacheFrLoaded := false

; True once the EN/FR fallback caches have been warmed — eagerly by the deferred
; I18nWarmFallbacks timer, or lazily on the first active-locale miss inside t().
; Keeps t() O(1) on misses (no re-entry into _I18nEnsureFallbacksLoaded).
global _I18nFallbacksWarmed := false

; Map of locale code → boolean indicating if flag.png exists.
global _I18nFlagExistsCache := Map()





; =============================================
; ===================================
; ======= 2/ Internal helpers =======
; ===================================
; =============================================

; Resolve the absolute path to a locale JSON file given a locale code.
; Uses _StaticDir (computed in ErgoptiPlus.ahk) to reach static/ergopti_plus/shared/locales/.
_I18nLocalePath(Code) {
	global _SharedDir
	return _SharedDir . "\locales\" . Code . ".json"
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
		Parsed := JsonParse(FileRead(JsonPath, "UTF-8"))
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

; Detect the Windows UI language via GetLocaleInfoEx(LOCALE_SISO639LANGNAME)
; and map it to a supported locale code. Falls back to "en" when the detected
; language is not in the supported list or the API call fails.
;
; CRITICAL: LOCALE_NAME_USER_DEFAULT is the NULL pointer, NOT L"". Passing an
; empty string here would silently switch to LOCALE_NAME_INVARIANT and return
; "iv" — historical source of "everyone gets English regardless of Windows
; language" bugs. Pass "Ptr", 0 explicitly.
;
; @returns string A supported two-letter locale code (e.g. "fr", "en", "de").
_I18nDetectSystemLocale() {
	; LOCALE_SISO639LANGNAME = 0x59 — returns the ISO 639-1 language code.
	BufSize := 16
	Buf := Buffer(BufSize * 2, 0)
	Len := DllCall("GetLocaleInfoEx",
		"Ptr", 0,           ; LOCALE_NAME_USER_DEFAULT (must be NULL, not L"")
		"UInt", 0x59,
		"Ptr", Buf,
		"Int", BufSize,
		"Int")
	if Len > 1 {
		Code := StrGet(Buf, "UTF-16")
		Code := StrLower(SubStr(Code, 1, 2))
		for _, _loc in I18N_LOCALES {
			if _loc.Code = Code {
				try LoggerDebug("i18n", "detect_system_locale: matched '{1}'.", Code)
				return Code
			}
		}
		try LoggerDebug("i18n", "detect_system_locale: '{1}' not supported — falling back to 'en'.", Code)
	} else {
		try LoggerDebug("i18n", "detect_system_locale: GetLocaleInfoEx returned 0 — falling back to 'en'.")
	}
	return "en"
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





; =========================================
; =============================
; ======= 3/ Public API =======
; =============================
; =========================================

; Returns the localised string for the given dot-notation key.
; Falls back to the raw key name if the locale file is missing or the key is absent.
t(Key) {
	global _I18nCache, _I18nCacheLoaded, _I18nFallbacksWarmed
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	if !_I18nCacheLoaded
		_I18nEnsureActiveLoaded()
	if _I18nCache.Has(Key)
		return _I18nCache[Key]
	; Miss in the active locale → consult the fallbacks. They are warmed off the
	; boot path (I18nWarmFallbacks); if a miss arrives first, load them once now.
	if !_I18nFallbacksWarmed
		_I18nEnsureFallbacksLoaded()
	if _I18nCacheEnLoaded and _I18nCacheEn.Has(Key)
		return _I18nCacheEn[Key]
	if _I18nCacheFrLoaded and _I18nCacheFr.Has(Key)
		return _I18nCacheFr[Key]
	return Key
}

; Initialise the i18n module from the script configuration cache.
; Must be called after ParseTomlFile and ReadScriptConfig so the Locale key
; is already available in Cache. Safe to call multiple times — subsequent calls
; are ignored if the locale has not changed.
I18nInit(Cache) {
	global _I18nLocale, _I18nCacheLoaded, _I18nFlagExistsCache
	
	if !IsSet(_I18nFlagExistsCache) || !(_I18nFlagExistsCache is Map)
		_I18nFlagExistsCache := Map()

	try LoggerTrace("i18n", "Initialising i18n…")
	Raw := IniCacheGet(Cache, "script", "locale")
	if Raw != "_" and Raw != "" {
		NewLocale := Raw
		; Validate against known locales
		IsKnown := false
		for Loc in I18N_LOCALES {
			if Loc.Code == NewLocale {
				IsKnown := true
				break
			}
		}
		if IsKnown {
			_I18nLocale := NewLocale
		} else {
			; Unknown code in config: pick the Windows UI language rather than
			; silently defaulting to French — the user clearly wanted something
			; else, and the system locale is the closest reasonable guess.
			Detected := _I18nDetectSystemLocale()
			try LoggerWarn("i18n", "Unknown locale '{1}' in config — falling back to system locale '{2}'.", NewLocale, Detected)
			_I18nLocale := Detected
		}
	} else {
		; No locale persisted yet: detect the Windows UI language so a freshly
		; installed (or freshly reset) driver starts in the user's actual
		; language rather than always French.
		_I18nLocale := _I18nDetectSystemLocale()
	}
	_I18nCacheLoaded := false
	try LoggerDone("i18n", "i18n initialised (locale: '{1}').", _I18nLocale)
}

; Pre-load the ACTIVE locale cache on the boot path so the first t() call during
; menu construction never blocks on disk I/O. The EN/FR fallback caches are NOT
; loaded here — they are consulted only on a missing key, so warming them at boot
; cost the user a second JSON parse for nothing on a complete locale. They are
; warmed instead by I18nWarmFallbacks() off the critical path (or lazily on the
; first miss inside t()). Must be called after I18nInit().
I18nPreload() {
	global _I18nCache
	try LoggerTrace("i18n", "Preloading active locale cache…")
	_I18nEnsureActiveLoaded()
	try LoggerDone("i18n", "Active locale warm ({1} key(s)); fallbacks deferred off the boot path.",
		_I18nCache.Count)
}

; Warm the EN/FR fallback caches off the boot critical path. Armed as a deferred
; SetTimer after "ready" so a later missing-key lookup is a cheap map hit rather
; than a synchronous JSON parse mid-interaction. Idempotent.
I18nWarmFallbacks() {
	global _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	try LoggerTrace("i18n", "Warming fallback locale caches…")
	_I18nEnsureFallbacksLoaded()
	try LoggerDone("i18n", "Fallback caches warm ({1} EN, {2} FR).",
		_I18nCacheEnLoaded ? _I18nCacheEn.Count : 0,
		_I18nCacheFrLoaded ? _I18nCacheFr.Count : 0)
}


; Change the active locale, persist it to config.toml, then reload the script
; so all menus are rebuilt in the new language.
; The reload is debounced: rapid successive calls cancel the pending reload
; so only the last selected locale triggers a script restart, preventing a
; stale intermediate language from landing when the user switches quickly.
I18nSetLocale(Code) {
	global _I18nLocale, _I18nCacheLoaded, ConfigurationFile, _I18nReloadDebounceMs
	if _I18nLocale == Code
		return
	try LoggerStart("i18n", "Switching locale to '{1}'…", Code)
	_I18nLocale      := Code
	_I18nCacheLoaded := false
	try TOML_BatchWrite(ConfigurationFile, [{ Section: "script", Key: "locale", Value: Code }])
	; Cancel any previously scheduled reload, then arm a new one.
	; Using a negative period makes SetTimer fire once after the delay.
	SetTimer(_I18nDoReload, -_I18nReloadDebounceMs)
}

; Called by the debounce timer — performs the actual script reload.
_I18nDoReload() {
	global _I18nLocale
	try LoggerSuccess("i18n", "Locale set to '{1}' — reloading script.", _I18nLocale)
	Reload
}

; Return the locale code of the active locale.
I18nGetLocale() {
	global _I18nLocale
	return _I18nLocale
}

; Returns a menu callback bound to a specific locale code. Calling this helper
; inside the loop captures Code by value, preventing all callbacks from sharing
; the same loop variable reference (AHK fat-arrow closures capture by reference).
_MakeLocaleSetter(Code) {
	return (*) => I18nSetLocale(Code)
}

; Returns a copy of I18N_LOCALES sorted alphabetically by Name (case-insensitive).
; Guarantees a stable display order regardless of the declaration order above.
_I18nSortedLocales() {
	global _I18nSortedLocalesCache
	if IsSet(_I18nSortedLocalesCache) and _I18nSortedLocalesCache
		return _I18nSortedLocalesCache

	Sorted := I18N_LOCALES.Clone()
	n := Sorted.Length
	Loop n - 1 {
		i := A_Index
		Loop n - i {
			j := A_Index
			if (StrCompare(Sorted[j].Name, Sorted[j + 1].Name, false) > 0) {
				Tmp         := Sorted[j]
				Sorted[j]   := Sorted[j + 1]
				Sorted[j + 1] := Tmp
			}
		}
	}
	_I18nSortedLocalesCache := Sorted
	return Sorted
}

; Populate a Menu object with one language entry per supported locale.
; Each item calls I18nSetLocale when clicked. A check mark is placed on the
; currently active locale. The menu is cleared first so this function is safe
; to call on every menu rebuild.
;
; @param LangMenu  Menu   The AHK Menu object to populate.
I18nBuildLanguageMenu(LangMenu) {
	global _I18nLocale, _StaticDir, _I18nFlagExistsCache
	
	; Safety initialization in case top-level auto-execute was bypassed
	try {
		if !IsSet(_I18nFlagExistsCache) || !(_I18nFlagExistsCache is Map)
			_I18nFlagExistsCache := Map()
	} catch {
		_I18nFlagExistsCache := Map()
	}
		
	try LangMenu.Delete()
	FlagsDir := _StaticDir . "\img\flags\"
	for Loc in _I18nSortedLocales() {
		; _MakeLocaleSetter wraps the code in a named function so AHK captures
		; the value at call time rather than sharing the loop variable reference.
		Label    := Loc.Name
		RegisterMenuItem(LangMenu, Label, _MakeLocaleSetter(Loc.Code))
		
		HasFlag := false
		try {
			if _I18nFlagExistsCache.Has(Loc.Code) {
				HasFlag := _I18nFlagExistsCache[Loc.Code]
			} else {
				FlagPath := FlagsDir . Loc.Code . ".png"
				HasFlag := FileExist(FlagPath)
				_I18nFlagExistsCache[Loc.Code] := HasFlag
			}
		} catch {
			FlagPath := FlagsDir . Loc.Code . ".png"
			HasFlag := FileExist(FlagPath)
		}
		
		if HasFlag
			try LangMenu.SetIcon(Label, FlagsDir . Loc.Code . ".png")
		if Loc.Code == _I18nLocale
			LangMenu.Check(Label)
	}
}
