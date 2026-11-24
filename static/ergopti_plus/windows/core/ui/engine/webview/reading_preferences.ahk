; core/ui/engine/webview/reading_preferences.ahk

; ==============================================================================
; MODULE: Reading Preferences of the Windows
; DESCRIPTION:
; The reader's font and text spacing for the app's own WebView windows,
; `script.reading_font` and `script.reading_spacing`, chosen in the
; Configuration menu and kept in config.toml. Every window's host seeds them
; before the page's scripts (ReadingPrefs_SeedScript, beside _i18n_locale) as
; window.__ergopti_reading, which _shared/ui/a11y_prefs.js applies before the
; first paint: the font through its stylesheet beside that script
; (_shared/ui/fonts/, shipped in the bundle and served by the virtual host),
; the WCAG 1.4.12 spacing through theme.css.
;
; FEATURES & RATIONALE:
; 1. One source of the values: the features manifest's enum, its first value
;    the default; a11y_prefs.js uses the same names and lists, and the
;    default is left out of the seed, which the script ignores anyway.
; 2. config.toml first, then the live value, then the menu, as the other
;    script settings (ErrorDialog_SetEnabled).
; 3. A window opened after a change reads it, and every open window takes it
;    at once: each host hands its WebView to ReadingPrefs_Track beside its
;    seed, and a saved choice is pushed into each one still open
;    (ReadingPrefs_PushToOpen, a11y_prefs.js receiveHost). A retained
;    (hidden) host carries the seed in its reuse key, so a change retires it
;    (MET-03).
; ==============================================================================

#Requires AutoHotkey v2.0
; WebView_RunScriptAsync pushes a choice into the open windows.
#Include %A_LineFile%\..\script.ahk

; The current values by config.toml key ([script]); 0 until ReadingPrefs_Init.
global _ReadingPrefsValues := 0
; The WebViews of the windows the hosts opened, by ObjPtr; a closed one is
; dropped at the next track or push.
global _ReadingPrefsViews := Map()





; =================================
; =================================
; ======= 1/ Initialisation =======
; =================================
; =================================

; Reads both choices from config.toml, else their manifest default.
; @param Cache {Map} The boot ini cache.
; @returns {Boolean} False when called twice.
ReadingPrefs_Init(Cache) {
	global _ReadingPrefsValues
	if (_ReadingPrefsValues is Map) {
		LoggerError("ReadingPrefs", "The reading preferences were initialised twice; the second call is refused.")
		return false
	}
	LoggerStart("ReadingPrefs", "Reading the windows' reading preferences…")
	Values := Map()
	for Key in ReadingPrefs_Names() {
		Values[Key] := ReadingPrefs_Default(Key)
		try Values[Key] := _ReadingPrefs_ReadSetting(Cache, Key)
		catch as Err
			LoggerError("ReadingPrefs", "{1}; the windows keep the default ({2}).", Err.Message, Values[Key])
	}
	_ReadingPrefsValues := Values
	LoggerSuccess("ReadingPrefs", "Reading preferences ready (font {1}, spacing {2}).",
		Values[ConfigLeaf.READING_FONT], Values[ConfigLeaf.READING_SPACING])
	return true
}

; Each preference's a11y_prefs.js name, by its config.toml key. A function, so
; the generated key classes are read only once a caller runs.
; @returns {Map}
ReadingPrefs_Names() {
	return Map(ConfigLeaf.READING_FONT, "font", ConfigLeaf.READING_SPACING, "spacing")
}

; The manifest's accepted values of one choice, its default first.
; @param Key {String} The config.toml key.
; @returns {Array}
; @throws {ValueError} When the manifest declares no such enum.
ReadingPrefs_Values(Key) {
	Entry := ManifestFindEntryByPath("script." . Key)
	if !(Entry is Map) || !Entry.Has("enum_values") || !Entry.Has("default")
			|| Entry["enum_values"].Length = 0 || Entry["enum_values"][1] != Entry["default"]
		throw ValueError("The features manifest declares no enum with its default first for script." . Key . ".")
	return Entry["enum_values"]
}

; The default of one choice.
; @param Key {String}
; @returns {String}
ReadingPrefs_Default(Key) {
	return ReadingPrefs_Values(Key)[1]
}

; Whether a value is one of the choice's.
; @param Key {String}
; @param Value {Any}
; @returns {Boolean}
ReadingPrefs_Accepts(Key, Value) {
	if !(Value is String)
		return false
	for _, Allowed in ReadingPrefs_Values(Key)
		if (Value == Allowed)
			return true
	return false
}

; The value config.toml holds, or the default when it holds none.
; @throws {ValueError} When config.toml holds a value outside the enum.
_ReadingPrefs_ReadSetting(Cache, Key) {
	if !ConfigTomlTryReadBootValue(Cache, "script", Key, &Raw)
		Raw := IniCacheGet(Cache, "script", Key)
	if (Raw == "_")
		return ReadingPrefs_Default(Key)
	if !ReadingPrefs_Accepts(Key, Raw)
		throw ValueError("config.toml script." . Key . " is not one of its values")
	return Raw
}





; =============================
; =============================
; ======= 2/ Live Value =======
; =============================
; =============================

; The current value of one choice, as the menu ticks it.
; @param Key {String}
; @returns {String}
ReadingPrefs_Get(Key) {
	global _ReadingPrefsValues
	if (_ReadingPrefsValues is Map) && _ReadingPrefsValues.Has(Key)
		return _ReadingPrefsValues[Key]
	return ReadingPrefs_Default(Key)
}

; Saves a menu choice: config.toml first, then the live value, then the menu.
; @param Key {String}
; @param Value {String}
; @returns {Boolean} False when the value is unknown or config.toml refused it.
ReadingPrefs_Set(Key, Value, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	global ConfigurationFile
	if !ReadingPrefs_Accepts(Key, Value) {
		LoggerError("ReadingPrefs", "script.{1} has no value '{2}'; it is unchanged.", Key, Value)
		return false
	}
	Updates := [{ Section: "script", Key: Key, Value: Value }]
	if !ConfigCommitUpdates(ConfigurationFile, Updates, "the windows' reading choice", WriterFn, NotifyFn,
			_ReadingPrefs_Publish.Bind(Key, Value)) {
		LoggerError("ReadingPrefs", "script.{1} could not be saved; it is unchanged.", Key)
		return false
	}
	LoggerInfo("ReadingPrefs", "script.{1} set to {2}.", Key, Value)
	ReadingPrefs_PushToOpen()
	if HasMethod(RebuildFn, "Call")
		RebuildFn.Call()
	else
		RebuildTrayMenu()
	return true
}

_ReadingPrefs_Publish(Key, Value) {
	global _ReadingPrefsValues
	if !(_ReadingPrefsValues is Map)
		_ReadingPrefsValues := Map()
	_ReadingPrefsValues[Key] := Value
}





; =============================
; =============================
; ======= 3/ Page Seed ========
; =============================
; =============================

; The boot-script statement every window's host adds beside _i18n_locale.
; @returns {String} `window.__ergopti_reading={...};`
ReadingPrefs_SeedScript() {
	return "window.__ergopti_reading=" . ReadingPrefs_SeedObject() . ";"
}

; The non-default choices as a JSON object, `{}` before the boot read them (a
; test host, a fatal startup report): a11y_prefs.js then keeps its defaults.
; The values are the manifest's closed lists (plain words), so no escaping.
; @returns {String} `{"font":"dyslexic"}`
ReadingPrefs_SeedObject() {
	global _ReadingPrefsValues
	if !(_ReadingPrefsValues is Map)
		return "{}"
	Parts := ""
	for Key, Name in ReadingPrefs_Names() {
		Value := ReadingPrefs_Get(Key)
		if (Value == ReadingPrefs_Default(Key))
			continue
		Parts .= (Parts = "" ? "" : ",") . '"' . Name . '":"' . Value . '"'
	}
	return "{" . Parts . "}"
}





; ================================
; ================================
; ======= 4/ Open Windows ========
; ================================
; ================================

; Keeps a window's WebView, so a later choice reaches it while it is open.
; Every host calls it beside the seed it adds. Never throws: a host's open
; must not fail on it.
; @param View {Object} The window's CoreWebView2.
ReadingPrefs_Track(View) {
	global _ReadingPrefsViews
	if !IsObject(View)
		return
	_ReadingPrefs_DropClosed()
	_ReadingPrefsViews[ObjPtr(View)] := View
}

; Pushes the current choices into every open window, so a change shows at
; once; a11y_prefs.js links the font beside the page.
; @returns {Integer} The number of windows the script was handed to.
ReadingPrefs_PushToOpen() {
	global _ReadingPrefsViews
	_ReadingPrefs_DropClosed()
	Script := "window.ErgoptiA11yPrefs&&window.ErgoptiA11yPrefs.receiveHost(" . ReadingPrefs_SeedObject() . ");"
	Reached := 0
	for _, View in _ReadingPrefsViews
		if WebView_RunScriptAsync(View, Script, "ReadingPrefs push")
			Reached += 1
	LoggerInfo("ReadingPrefs", "The reading choices reached {1} open window(s).", Reached)
	return Reached
}

; Drops the views whose window has closed: a closed WebView refuses every call.
_ReadingPrefs_DropClosed() {
	global _ReadingPrefsViews
	for Ptr, View in _ReadingPrefsViews.Clone()
		if !_ReadingPrefs_ViewOpen(View)
			_ReadingPrefsViews.Delete(Ptr)
}

; Whether a tracked WebView still answers: reading its address throws once
; its window has closed.
; @param View {Object}
; @returns {Boolean}
_ReadingPrefs_ViewOpen(View) {
	try {
		Address := View.Source
		return Address is String
	}
	return false
}
