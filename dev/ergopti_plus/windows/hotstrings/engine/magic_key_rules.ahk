; hotstrings/engine/magic_key_rules.ahk

; ==============================================================================
; MODULE: Magic Key Character Rules (Windows)
; DESCRIPTION:
; Binds the shared magic key rules (_shared/hotstrings/data/magic_key.ahk,
; read from _shared/hotstrings/data/magic_key.json) to the Windows layout
; probes. The magic key is a configured character (maintainer's decision of
; 2026-11-21): its default follows the OS layout that types (« ù » on AZERTY,
; « ; » on QWERTY, the manifest default elsewhere and under an emulated
; layout), and every user-facing text shows « ★ (configured character) ».
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\..\_shared\hotstrings\data\magic_key.ahk
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk





; ===================================
; ===================================
; ======= 1/ Shared rule data =======
; ===================================
; ===================================

/**
 * The validated shared rules, read once from the shared tree.
 * @returns {Map} Result of MagicKeyRules.
 */
MagicKeyRulesShared() {
	global _SharedDir
	static Rules := 0
	if !IsObject(Rules) {
		Path := _SharedDir . "\hotstrings\data\magic_key.json"
		Rules := MagicKeyRules(JsonParse(FSReadStrict(Path)))
	}
	return Rules
}

/** The real marker hotstring data writes for the magic key. */
MagicKeyMarker() {
	return MagicKeyRulesShared()["marker"]
}

/**
 * How the configured magic key is shown, « ★ (ù) » for another character.
 * @param {String} Char Configured magic key.
 * @returns {String}
 */
MagicKeyShown(Char) {
	return MagicKeyDisplay(MagicKeyRulesShared(), Char)
}

/**
 * A user-facing text with every marker shown as the magic key's display.
 * @param {String} Text Text written with the real marker.
 * @param {String} Char Configured magic key.
 * @param {String} Key Locale key of the text, "" for none.
 * @returns {String}
 */
MagicKeyShownText(Text, Char, Key := "") {
	return MagicKeyDisplayText(MagicKeyRulesShared(), Text, Char, Key)
}





; =================================
; =================================
; ======= 2/ Layout default =======
; =================================
; =================================

/**
 * The default magic key of the layout that types: the OS layout's family
 * default, or the manifest default while an emulated layout types.
 * @param {Boolean} Emulated Whether an emulated layout types.
 * @param {Integer} Hkl The OS keyboard layout, 0 when none could be read.
 * @param {Func|Integer} TextFn (Scan, Hkl) → base-level text; the native probe by default.
 * @returns {String}
 */
MagicKeyLayoutDefaultFor(Emulated, Hkl, TextFn := 0) {
	Fallback := ManifestDefaultFor(ConfigKey.HOTSTRINGS_TRIGGER_CHAR)
	if Emulated || !Hkl
		return Fallback
	Probe := HasMethod(TextFn, "Call") ? TextFn : _MagicKeyBaseText
	Keys := _MagicKeyPhysicalKeys()
	BaseTextOf(Code) {
		if !Keys.Has(Code)
			throw ValueError("The magic key's layout family names a key outside the physical registry: " . Code)
		return Probe.Call(Integer("0x" . SubStr(Keys[Code]["ahk"], 3)), Hkl)
	}
	Chosen := MagicKeyLayoutDefault(MagicKeyRulesShared(), BaseTextOf, Fallback)
	LoggerInfo("MagicKey", "Layout default of the magic key: '{1}' (family '{2}', HKL=0x{3:X}).",
		Chosen["char"], Chosen["family"], Hkl)
	return Chosen["char"]
}

/** The shared physical-key registry (KeyboardEvent.code → record), read once. */
_MagicKeyPhysicalKeys() {
	global _SharedDir
	static Keys := 0
	if !IsObject(Keys) {
		Path := _SharedDir . "\layouts\data\keycodes\physical_keys.json"
		Keys := JsonParse(FSReadStrict(Path))["keys"]
	}
	return Keys
}

/** What a key types with no modifier and no dead-key state, "" for nothing. */
_MagicKeyBaseText(Scan, Hkl) {
	Output := KS_KeyTextNoStateChange(KS_ScancodeToVk(Scan, Hkl), Scan, Hkl, false, false)
	return Output.Count > 0 ? Output.Text : ""
}
