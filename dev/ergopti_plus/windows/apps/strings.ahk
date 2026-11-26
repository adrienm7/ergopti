; apps/strings.ahk

; ==============================================================================
; MODULE: Bundled App Strings (Windows)
; DESCRIPTION:
; Loads the user-facing text of a bundled app (Encryptor, App Cloner) from the
; shared locale catalogue, as the macOS bundles do: the tray hands the app the
; active locale code and the locales folder; a key the locale lacks is read
; from English, and a key English lacks too raises.
; ==============================================================================

#Requires AutoHotkey v2.0+

class BundledAppStrings {
	static active := Map()
	static english := Map()
	static loaded := false
}

/**
 * Loads one locale.
 * @param {String} LocalesDir Folder holding <code>.json files.
 * @param {String} Locale Two-letter code; "" or unknown reads English.
 */
BundledAppStrings_Load(LocalesDir, Locale) {
	if BundledAppStrings.loaded
		throw Error("The bundled app strings are already loaded.")
	BundledAppStrings.english := JsonParse(FileRead(LocalesDir . "\en.json", "UTF-8"))
	BundledAppStrings.active := BundledAppStrings.english
	Path := LocalesDir . "\" . Locale . ".json"
	if RegExMatch(Locale, "^[a-z][a-z]$") && Locale != "en" && FileExist(Path)
		BundledAppStrings.active := JsonParse(FileRead(Path, "UTF-8"))
	BundledAppStrings.loaded := true
}

/**
 * Returns one string with {1}, {2}… replaced.
 * @param {String} Key
 * @returns {String}
 */
AppText(Key, Values*) {
	if !BundledAppStrings.loaded
		throw Error("The bundled app strings are not loaded.")
	Text := BundledAppStrings.active.Get(Key, "")
	if !(Text is String) || Text == ""
		Text := BundledAppStrings.english.Get(Key, "")
	if !(Text is String) || Text == ""
		throw ValueError("Missing locale key: " . Key)
	for Index, Value in Values
		Text := StrReplace(Text, "{" . Index . "}", String(Value))
	return Text
}
