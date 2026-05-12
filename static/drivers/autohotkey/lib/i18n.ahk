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
; ============================================
; ======= 1/ Constants and module state =======
; ============================================
; ============================================

; Ordered list of supported locales: { Code, Flag, Name }
global I18N_LOCALES := [
	{ Code: "fr", Flag: "🇫🇷", Name: "Français"  },
	{ Code: "en", Flag: "🇬🇧", Name: "English"   },
	{ Code: "de", Flag: "🇩🇪", Name: "Deutsch"   },
	{ Code: "es", Flag: "🇪🇸", Name: "Español"   },
	{ Code: "zh", Flag: "🇨🇳", Name: "中文"       },
]

; Active locale code — read from config.toml at boot, then kept in memory.
global _I18nLocale := "fr"

; Flat map of key → translated string for the active locale. Populated lazily
; on first call to t() after each locale switch.
global _I18nCache := Map()

; Set to true once _I18nCache has been populated for _I18nLocale.
global _I18nCacheLoaded := false


; =============================================
; =============================================
; ======= 2/ Internal helpers =======
; =============================================
; =============================================

; Resolve the absolute path to a locale JSON file given a locale code.
; Walks up from A_ScriptDir (static/drivers/autohotkey) to static/, then
; descends into locales/.
_I18nLocalePath(Code) {
	; A_ScriptDir = .../static/drivers/autohotkey
	SplitPath(A_ScriptDir, , &DriversDir)   ; .../static/drivers
	SplitPath(DriversDir, , &StaticDir)     ; .../static
	return StaticDir . "\locales\" . Code . ".json"
}

; Parse the JSON file at FilePath and populate _I18nCache. Substitutes ★ with
; the user's configured MagicKey. Does nothing and logs a warning on file error.
_I18nLoadFile(FilePath) {
	global _I18nCache, _I18nCacheLoaded, ScriptInformation

	_I18nCache    := Map()
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

	; Minimal flat-JSON parser — mirrors the one in toml_loader.ahk.
	; Extracts every "key": "value" pair; keys use dot notation.
	MagicKey := IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")
		? ScriptInformation["MagicKey"]
		: "★"

	Pos := 1
	FileLen := StrLen(FileContent)
	while Pos <= FileLen {
		if !RegExMatch(FileContent, '`"([^`"]+)`"\s*:\s*`"((?:[^`"\\]|\\.)*)`"', &KVMatch, Pos)
			break
		RawKey := KVMatch[1]
		RawVal := KVMatch[2]
		; JSON unescape: \\, \", \n, \t, \r, \/
		Val := StrReplace(RawVal, "\\", Chr(1))
		Val := StrReplace(Val, '\"', "`"")
		Val := StrReplace(Val, "\n", "`n")
		Val := StrReplace(Val, "\t", "`t")
		Val := StrReplace(Val, "\r", "`r")
		Val := StrReplace(Val, "\/", "/")
		Val := StrReplace(Val, Chr(1), "\")
		Val := StrReplace(Val, "★", MagicKey)
		_I18nCache[RawKey] := Val
		Pos := KVMatch.Pos + KVMatch.Len
	}

	_I18nCacheLoaded := true
	try LoggerDone("i18n", "Locale '{1}' loaded (%d key(s)).", _I18nLocale, _I18nCache.Count)
}

; Ensure the cache is loaded for the active locale.
_I18nEnsureLoaded() {
	global _I18nCacheLoaded, _I18nLocale
	if !_I18nCacheLoaded
		_I18nLoadFile(_I18nLocalePath(_I18nLocale))
}


; =========================================
; =========================================
; ======= 3/ Public API =======
; =========================================
; =========================================

; Return the localised string for the given dot-notation key.
; Falls back to the raw key name if the locale file is missing or the key is absent.
t(Key) {
	global _I18nCache
	_I18nEnsureLoaded()
	return _I18nCache.Has(Key) ? _I18nCache[Key] : Key
}

; Initialise the i18n module from the script configuration cache.
; Must be called after ParseTomlFile and ReadScriptConfig so the Locale key
; is already available in Cache. Safe to call multiple times — subsequent calls
; are ignored if the locale has not changed.
I18nInit(Cache) {
	global _I18nLocale, _I18nCacheLoaded
	try LoggerTrace("i18n", "Initialising i18n…")
	Raw := IniCacheGet(Cache, "Script", "Locale")
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
			try LoggerWarn("i18n", "Unknown locale '{1}' in config — defaulting to 'fr'.", NewLocale)
			_I18nLocale := "fr"
		}
	}
	_I18nCacheLoaded := false
	try LoggerDone("i18n", "i18n initialised (locale: '{1}').", _I18nLocale)
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
	try TOML_BatchWrite(ConfigurationFile, [{ Section: "Script", Key: "Locale", Value: Code }])
	try LoggerSuccess("i18n", "Locale set to '{1}' — reloading script.", Code)
	Reload
}

; Return the locale code of the active locale.
I18nGetLocale() {
	global _I18nLocale
	return _I18nLocale
}

; Populate a Menu object with one language entry per supported locale.
; Each item calls I18nSetLocale when clicked. A check mark is placed on the
; currently active locale. The menu is cleared first so this function is safe
; to call on every menu rebuild.
;
; @param LangMenu  Menu   The AHK Menu object to populate.
I18nBuildLanguageMenu(LangMenu) {
	global _I18nLocale
	try LangMenu.Delete()
	for Loc in I18N_LOCALES {
		; Capture loop variable for the closure
		LocCode := Loc.Code
		Label   := Loc.Flag . " " . Loc.Name
		LangMenu.Add(Label, (_) => I18nSetLocale(LocCode))
		if Loc.Code == _I18nLocale
			LangMenu.Check(Label)
	}
}
