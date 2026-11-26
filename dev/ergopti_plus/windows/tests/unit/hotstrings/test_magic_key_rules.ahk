; tests/unit/hotstrings/test_magic_key_rules.ahk

; ==============================================================================
; MODULE: Magic Key Character Rules Tests (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/magic_key_vectors.json through the
; AutoHotkey twin (_shared/hotstrings/data/magic_key.ahk) and its Windows
; binding (hotstrings/engine/magic_key_rules.ahk): the layout default of the
; magic key and its « ★ (ù) » display, as the Lua drivers and the hotstring
; editor replay them. Before 2026-11-21 the default was ★ on every layout and
; every text showed the configured character alone.
; ==============================================================================

#Requires AutoHotkey v2.0

_MKR_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\magic_key_vectors.json", "UTF-8"))
}

Test("magic key rules: the layout default follows the shared vectors (magic-key-default)", () => (
	Corpus := _MKR_Corpus(),
	_MKR_LayoutDefaults(Corpus)))

_MKR_LayoutDefaults(Corpus) {
	Rules := MagicKeyRulesShared()
	Count := 0
	for Vector in Corpus["layout_default"] {
		Base := Vector["base"]
		Chosen := MagicKeyLayoutDefault(Rules, (Code) => Base.Has(Code) ? Base[Code] : "", Corpus["fallback"])
		AssertEqual(Vector["expected"], Chosen["char"], Vector["id"])
		Family := Vector["family"]
		AssertEqual(IsObject(Family) ? "" : Family, Chosen["family"], Vector["id"] . " family")
		Count += 1
	}
	AssertTrue(Count >= 9, "every layout vector is replayed")
}

Test("magic key rules: the display follows the shared vectors (magic-key-display)", () => (
	Corpus := _MKR_Corpus(),
	_MKR_Displays(Corpus)))

_MKR_Displays(Corpus) {
	for Vector in Corpus["display"]
		AssertEqual(Vector["expected"], MagicKeyShownText(Vector["text"], Vector["char"], Vector.Get("key", "")), Vector["id"])
	AssertEqual(Chr(0x2605) . " (" . Chr(0xF9) . ")", MagicKeyShown(Chr(0xF9)), "never the configured character alone")
	AssertEqual(Chr(0x2605), MagicKeyShown(Chr(0x2605)), "the marker shows itself")
}

; The Windows binding probes the OS layout's base level by physical key, and
; leaves an emulated layout to the manifest default.
Test("magic key rules: the OS layout's family gives the Windows default (magic-key-default)", () => (
	Azerty := Map(0x10, "a", 0x11, "z", 0x1E, "q", 0x15, "y"),
	Qwerty := Map(0x10, "q", 0x11, "w", 0x1E, "a", 0x15, "y"),
	Fallback := ManifestDefaultFor("hotstrings.trigger_char"),
	AssertEqual(Chr(0xF9), MagicKeyLayoutDefaultFor(false, 1, (Scan, Hkl) => Azerty.Get(Scan, ""))),
	AssertEqual(";", MagicKeyLayoutDefaultFor(false, 1, (Scan, Hkl) => Qwerty.Get(Scan, ""))),
	AssertEqual(Fallback, MagicKeyLayoutDefaultFor(true, 1, (Scan, Hkl) => Azerty.Get(Scan, "")),
		"an emulated layout types: the manifest default"),
	AssertEqual(Fallback, MagicKeyLayoutDefaultFor(false, 0, (Scan, Hkl) => Azerty.Get(Scan, "")),
		"no OS layout read: the manifest default")))

Test("magic key rules: the real French AZERTY gives u-grave (magic-key-default)", () => (
	Hkl := DllCall("LoadKeyboardLayoutW", "Str", "0000040C", "UInt", 0x80, "Ptr"),
	AssertTrue(Hkl != 0, "the native French layout must load"),
	AssertEqual(Chr(0xF9), MagicKeyLayoutDefaultFor(false, Hkl)),
	Us := DllCall("LoadKeyboardLayoutW", "Str", "00000409", "UInt", 0x80, "Ptr"),
	AssertEqual(";", MagicKeyLayoutDefaultFor(false, Us))))

; An untouched magic key stays out of config.toml: its default follows the
; layout, so a full save that wrote it would pin the layout it booted on.
Test("magic key rules: a full save keeps an untouched layout default sparse (magic-key-default)", _MKR_SparseTrigger)

; Whether the full save writes this magic key; the feature snapshot also names
; trigger_char, at its manifest default, which the sparse writer omits.
_MKR_HasTrigger(Updates, Char) {
	for Update in Updates {
		if Update.Section == "hotstrings" && Update.Key == "trigger_char" && Update.HasOwnProp("Value")
				&& Update.Value == Char
			return true
	}
	return false
}

_MKR_SparseTrigger() {
	global ScriptInformation, _IniCache
	Features := ManifestBuildFeaturesMap()
	SavedKey := ScriptInformation["MagicKey"], SavedDefault := ScriptInformation["MagicKeyDefault"]
	HadCache := IsSet(_IniCache), SavedCache := HadCache ? _IniCache : 0
	try {
		_IniCache := Map()
		ScriptInformation["MagicKey"] := Chr(0xF9), ScriptInformation["MagicKeyDefault"] := Chr(0xF9)
		AssertFalse(_MKR_HasTrigger(_ConfigCollectFullSaveUpdates(Features), Chr(0xF9)), "the layout default is not written")
		ScriptInformation["MagicKey"] := "§"
		AssertTrue(_MKR_HasTrigger(_ConfigCollectFullSaveUpdates(Features), "§"), "a chosen key is written")
		ScriptInformation["MagicKey"] := Chr(0xF9)
		_IniCache := Map("hotstrings", Map("trigger_char", Chr(0xF9)))
		AssertTrue(_MKR_HasTrigger(_ConfigCollectFullSaveUpdates(Features), Chr(0xF9)), "an explicit key stays written")
	} finally {
		ScriptInformation["MagicKey"] := SavedKey, ScriptInformation["MagicKeyDefault"] := SavedDefault
		if HadCache
			_IniCache := SavedCache
	}
}
