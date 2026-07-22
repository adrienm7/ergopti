; lib/i18n.ahk

; ==============================================================================
; MODULE: i18n (Internationalisation — locale management)
; DESCRIPTION:
; Manages the active UI locale for the AHK driver: system-language detection,
; selection + persistence (with a debounced reload) and the language-picker menu.
; The string-LOADING + access layer (the self-healing locale cache and the
; ``t(key)`` accessor) lives in the sibling ``lib/locale.ahk`` — mirror of the
; ``macos/lib/{i18n,locale}.lua`` split. This file owns "which locale and how to
; switch it"; locale.ahk owns "load the strings and return one".
;
; FEATURES & RATIONALE:
; 1. System detection: a freshly installed (or reset) driver starts in the
;    Windows UI language rather than always French (_I18nDetectSystemLocale).
; 2. Persistence: the active locale code is written to ``[Script] Locale`` in
;    ``ahk/config.toml`` via the shared TOML_BatchWrite helper, then the script
;    reloads so all menus are rebuilt in the new language.
; 3. Language selector: ``I18nBuildLanguageMenu`` populates any AHK ``Menu``
;    object with one item per supported locale, with a check mark on the active
;    one. Callers pass their ``Menu`` object and the submenu is ready to use.
; 4. Shared locale files: the JSON files live in ``_shared/data/locales/`` and
;    are the single source of truth shared with the Hammerspoon driver.
; ==============================================================================





; ============================================
; =============================================
; ======= 1/ Constants and module state =======
; =============================================
; ============================================

; Ordered list of supported locales: { Code, Flag, Name }
; Tag = short code shown in radio buttons (flag emojis don't render on Windows)
global I18N_LOCALES := [
	{ Code: "da", Tag: "[DA]", Name: "Dansk"       },
	{ Code: "de", Tag: "[DE]", Name: "Deutsch"     },
	{ Code: "en", Tag: "[EN]", Name: "English"     },
	{ Code: "es", Tag: "[ES]", Name: "Español"     },
	{ Code: "fr", Tag: "[FR]", Name: "Français"    },
	{ Code: "it", Tag: "[IT]", Name: "Italiano"    },
	{ Code: "nl", Tag: "[NL]", Name: "Nederlands"  },
	{ Code: "no", Tag: "[NO]", Name: "Norsk"        },
	{ Code: "pl", Tag: "[PL]", Name: "Polski"       },
	{ Code: "pt", Tag: "[PT]", Name: "Português"   },
	{ Code: "sv", Tag: "[SV]", Name: "Svenska"      },
	{ Code: "tr", Tag: "[TR]", Name: "Türkçe"       },
	{ Code: "cs", Tag: "[CS]", Name: "Čeština"    },
	{ Code: "ru", Tag: "[RU]", Name: "Русский"      },
	{ Code: "uk", Tag: "[UK]", Name: "Українська"   },
	{ Code: "he", Tag: "[HE]", Name: "עברית"       },
	{ Code: "ar", Tag: "[AR]", Name: "العربية"    },
	{ Code: "hi", Tag: "[HI]", Name: "हिन्दी"      },
	{ Code: "zh", Tag: "[ZH]", Name: "中文"          },
	{ Code: "ja", Tag: "[JA]", Name: "日本語"       },
	{ Code: "ko", Tag: "[KO]", Name: "한국어"       },
]

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

; Cached sorted locale list for the menu
global _I18nSortedLocalesCache := false

; Map of locale code → boolean indicating if flag.png exists.
global _I18nFlagExistsCache := Map()





; =============================================
; ===================================
; ======= 2/ Internal helpers =======
; ===================================
; =============================================

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





; =========================================
; =============================
; ======= 3/ Public API =======
; =============================
; =========================================

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
	global _I18nLocale, _I18nCacheLoaded, _I18nFallbacksWarmed, ConfigurationFile, _I18nReloadDebounceMs
	if _I18nLocale == Code
		return
	_I18nLocale           := Code
	_I18nCacheLoaded      := false
	_I18nFallbacksWarmed  := false
	try TOML_BatchWrite(ConfigurationFile, [{ Section: "script", Key: "locale", Value: Code }])
	; Cancel any previously scheduled reload, then arm a new one.
	; Using a negative period makes SetTimer fire once after the delay.
	SetTimer(_I18nDoReload, -_I18nReloadDebounceMs)
}

; Called by the debounce timer — performs the actual script reload. LoggerStart
; is logged HERE, not in I18nSetLocale: re-arming SetTimer with the same
; function reference coalesces rapid successive calls into a single firing, so
; logging the start at the call site emitted one unpaired START per superseded
; intermediate switch (F51). Logging it right before the SUCCESS it always
; pairs with guarantees exactly one START per reload attempt that completes.
_I18nDoReload() {
	global _I18nLocale
	try LoggerStart("i18n", "Switching locale to '{1}'…", _I18nLocale)
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

; Returns a copy of I18N_LOCALES in canonical display order. The table above is
; already declared in that order — single-sourced from
; _shared/data/locale_order.json and pinned to it by the parity test — so this
; hands back a cached shallow copy without sorting. Every locale menu shares the
; one order and can never desync from the other drivers or the site.
_I18nSortedLocales() {
	global _I18nSortedLocalesCache
	if IsSet(_I18nSortedLocalesCache) and _I18nSortedLocalesCache
		return _I18nSortedLocalesCache

	_I18nSortedLocalesCache := I18N_LOCALES.Clone()
	return _I18nSortedLocalesCache
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
