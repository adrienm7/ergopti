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

; Flat map of key → translated string for the active locale. Populated lazily.
global _I18nCache := Map()
global _I18nCacheLoaded := false

; Fallback caches: English first, French second.
global _I18nCacheEn := Map()
global _I18nCacheEnLoaded := false
global _I18nCacheFr := Map()
global _I18nCacheFrLoaded := false





; =============================================
; ===================================
; ======= 2/ Internal helpers =======
; ===================================
; =============================================

; Resolve the absolute path to a locale JSON file given a locale code.
; Uses _StaticDir (computed in ErgoptiPlus.ahk) to reach static/ergopti_plus/shared/locales/.
_I18nLocalePath(Code) {
	global _StaticDir
	return _StaticDir . "\ergopti_plus\shared\locales\" . Code . ".json"
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
		for _loc in I18N_LOCALES {
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

; Parse the JSON file at FilePath and populate _I18nCache. Substitutes ★ with
; the user's configured MagicKey. Does nothing and logs a warning on file error.
_I18nLoadFile(FilePath) {
	global _I18nCache, _I18nCacheLoaded, ScriptInformation

	_I18nCache       := Map()
	_I18nCacheLoaded := false

	if !FileExist(FilePath) {
		try LoggerWarn("i18n", "Locale file not found: '{1}' — falling back to key names.", FilePath)
		return
	}

	try {
		FileContent := FileRead(FilePath, "UTF-8")
	} catch {
		try LoggerWarn("i18n", "Failed to read locale file '{1}'.", FilePath)
		return
	}

	MagicKey := IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")
		? ScriptInformation["MagicKey"]
		: "★"

	try {
		Parsed := JsonParse(FileContent)
	} catch as err {
		try LoggerWarn("i18n", "JSON parse error in '{1}': {2}", FilePath, err.Message)
		return
	}

	for Key, Val in Parsed {
		_I18nCache[Key] := StrReplace(Val, "★", MagicKey)
	}

	_I18nCacheLoaded := true
	try LoggerDone("i18n", "Locale '{1}' loaded (%d key(s)).", _I18nLocale, _I18nCache.Count)
}

; Load a locale into a provided Map reference. Returns true on success.
_I18nLoadInto(Code, &Cache, &Loaded) {
	if Loaded
		return
	FilePath := _I18nLocalePath(Code)
	global ScriptInformation
	if !FileExist(FilePath) {
		try LoggerWarn("i18n", "Fallback locale file not found: '{1}'.", FilePath)
		Loaded := false
		return
	}
	try {
		FileContent := FileRead(FilePath, "UTF-8")
	} catch {
		try LoggerWarn("i18n", "Failed to read fallback locale '{1}'.", Code)
		Loaded := false
		return
	}
	MagicKey := IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")
		? ScriptInformation["MagicKey"] : "★"
	try {
		Parsed := JsonParse(FileContent)
	} catch as err {
		try LoggerWarn("i18n", "JSON parse error in fallback locale '{1}': {2}", Code, err.Message)
		Loaded := false
		return
	}
	TempCache := Map()
	for Key, Val in Parsed {
		TempCache[Key] := StrReplace(Val, "★", MagicKey)
	}
	Cache  := TempCache
	Loaded := true
}

; Ensure the active locale and both fallback locales are loaded.
_I18nEnsureLoaded() {
	global _I18nCacheLoaded, _I18nLocale
	global _I18nCacheEn, _I18nCacheEnLoaded
	global _I18nCacheFr, _I18nCacheFrLoaded
	if !_I18nCacheLoaded
		_I18nLoadFile(_I18nLocalePath(_I18nLocale))
	if _I18nLocale != "en" and !_I18nCacheEnLoaded
		_I18nLoadInto("en", &_I18nCacheEn, &_I18nCacheEnLoaded)
	if _I18nLocale != "fr" and !_I18nCacheFrLoaded
		_I18nLoadInto("fr", &_I18nCacheFr, &_I18nCacheFrLoaded)
}





; =========================================
; =============================
; ======= 3/ Public API =======
; =============================
; =========================================

; Return the localised string for the given dot-notation key.
; Falls back to the raw key name if the locale file is missing or the key is absent.
t(Key) {
	global _I18nCache, _I18nCacheEn, _I18nCacheEnLoaded, _I18nCacheFr, _I18nCacheFrLoaded
	_I18nEnsureLoaded()
	if _I18nCache.Has(Key)
		return _I18nCache[Key]
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
	global _I18nLocale, _I18nCacheLoaded
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

; Pre-load all locale caches in a background timer so the first t() call during
; menu construction never blocks the main thread on disk I/O.
; Must be called after I18nInit() — schedule with SetTimer(..., -1).
I18nPreload() {
	try LoggerTrace("i18n", "Preloading locale caches…")
	_I18nEnsureLoaded()
	try LoggerDone("i18n", "Locale caches warm (%d keys active, %d EN, %d FR).",
		_I18nCache.Count,
		_I18nCacheEnLoaded ? _I18nCacheEn.Count : 0,
		_I18nCacheFrLoaded ? _I18nCacheFr.Count : 0)
}


; Change the active locale, persist it to config.toml, then reload the script
; so all menus are rebuilt in the new language.
I18nSetLocale(Code) {
	global _I18nLocale, _I18nCacheLoaded, ConfigurationFile
	if _I18nLocale == Code
		return
	try LoggerStart("i18n", "Switching locale to '{1}'…", Code)
	_I18nLocale      := Code
	_I18nCacheLoaded := false
	try TOML_BatchWrite(ConfigurationFile, [{ Section: "script", Key: "locale", Value: Code }])
	try LoggerSuccess("i18n", "Locale set to '{1}' — reloading script.", Code)
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
	return Sorted
}

; Populate a Menu object with one language entry per supported locale.
; Each item calls I18nSetLocale when clicked. A check mark is placed on the
; currently active locale. The menu is cleared first so this function is safe
; to call on every menu rebuild.
;
; @param LangMenu  Menu   The AHK Menu object to populate.
I18nBuildLanguageMenu(LangMenu) {
	global _I18nLocale
	global _StaticDir
	try LangMenu.Delete()
	FlagsDir := _StaticDir . "\img\flags\"
	for Loc in _I18nSortedLocales() {
		; _MakeLocaleSetter wraps the code in a named function so AHK captures
		; the value at call time rather than sharing the loop variable reference.
		Label    := Loc.Name
		RegisterMenuItem(LangMenu, Label, _MakeLocaleSetter(Loc.Code))
		FlagPath := FlagsDir . Loc.Code . ".png"
		if FileExist(FlagPath)
			try LangMenu.SetIcon(Label, FlagPath)
		if Loc.Code == _I18nLocale
			LangMenu.Check(Label)
	}
}
