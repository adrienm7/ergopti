; tests/unit/platform/remap/key_combinations/test_keyboard_slot_neutral_roles.ahk

; ==============================================================================
; MODULE: Neutral keyboard slots on Windows (PAR-41)
; DESCRIPTION:
; Replays the shared neutral_slots.json corpus through the Windows
; port of the slot grammar, as the macOS and Linux unit gates replay it through
; the shared Lua resolver, so a role cannot mean different keys on
; different drivers. Then holds every chord Windows registers to the two AltGr
; families the driver supports: AZERTY-style (LCtrl+RAlt) and Kana (SC138 on
; VK_OEM_8). A slot's hotkey must name exactly its own modifiers, because a
; wildcard or an AltGr prefix would make it swallow the AltGr layer's keys.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSNR_Corpus() {
	global _SharedDir
	static Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\shortcuts\neutral_slots.json", "UTF-8"))
	return Corpus
}

; Order matters in the corpus and in the role table, so compare element by element.
_KSNR_AssertList(Expected, Actual, Context) {
	AssertEqual(Expected.Length, Actual.Length, Context . ": length")
	for Index, Value in Expected
		AssertEqual(Value, Actual[Index], Context . ": element " . Index)
}

_KSNR_ValidSlotsResolve() {
	Corpus := _KSNR_Corpus()
	AssertTrue(Corpus["valid"].Length >= 12, "the corpus keeps its independent positive inventory")
	for Vector in Corpus["valid"] {
		Parsed := SlotRoleParse(Vector["slot"])
		AssertTrue(Parsed.Has("roles"), Vector["slot"] . " parses")
		_KSNR_AssertList(Vector["roles"], Parsed["roles"], Vector["slot"])
		AssertEqual(Vector["key"], Parsed["key"], Vector["slot"] . ": key")
		Native := SlotRoleNative(Vector["slot"])
		Expected := Vector["native"]["windows"]
		if Expected.Has("absent") {
			AssertFalse(Native.Has("modifiers"), Vector["slot"] . " has no Windows chord")
			AssertTrue(Native["reason"] != "", Vector["slot"] . " says why")
			continue
		}
		_KSNR_AssertList(Expected["modifiers"], Native["modifiers"], Vector["slot"])
		AssertEqual(Expected["key"], Native["key"], Vector["slot"] . ": native key")
	}
}
Test("neutral slots: the shared valid vectors resolve on Windows", _KSNR_ValidSlotsResolve)

_KSNR_InvalidSlotsAreRefused() {
	Corpus := _KSNR_Corpus()
	AssertTrue(Corpus["invalid"].Length >= 15, "the corpus keeps its independent refusal inventory")
	for Slot in Corpus["invalid"] {
		AssertTrue(SlotRoleParse(Slot).Has("reason"), "'" . Slot . "' is refused")
		AssertFalse(SlotRoleNative(Slot).Has("modifiers"), "'" . Slot . "' has no chord")
		AssertEqual("", _KeyboardSlotChord(Slot), "'" . Slot . "' binds nothing")
	}
}
Test("neutral slots: every retired or malformed id is refused, win_a included", _KSNR_InvalidSlotsAreRefused)

_KSNR_CrosswalkRoundTrips() {
	Rows := 0
	for Row in _KSNR_Corpus()["crosswalk"] {
		if Row["driver"] != "windows"
			continue
		Rows += 1
		AssertEqual(Row["slot"], SlotRoleFromNative(Row["modifiers"], Row["key"]), "the chord names " . Row["slot"])
		Native := SlotRoleNative(Row["slot"])
		AssertEqual(Row["key"], Native["key"], Row["slot"] . ": key")
		AssertEqual(Row["modifiers"].Length, Native["modifiers"].Length, Row["slot"] . ": modifiers")
	}
	AssertTrue(Rows >= 18, "the crosswalk keeps every Windows chord")
	AssertEqual("", SlotRoleFromNative(["hyper"], "g"), "a foreign modifier has no slot")
	AssertEqual("", SlotRoleFromNative(["ctrl", "ctrl"], "g"), "a repeated modifier has no slot")
}
Test("neutral slots: the Windows crosswalk round-trips", _KSNR_CrosswalkRoundTrips)

_KSNR_FamiliesAndKeysMatch() {
	Corpus := _KSNR_Corpus()
	_KSNR_AssertList(Corpus["families"]["windows"], SlotRoleFamilyPrefixes(), "families")
	_KSNR_AssertList(Corpus["families"]["windows"], KeyboardSlotDeclaration()["groups"], "the declared groups")
	; The menu lists its groups in the role table's order, the magic row first.
	Listed := []
	global KEYBOARD_SLOT_GROUPS
	for Group in KEYBOARD_SLOT_GROUPS {
		if Group["prefix"] != "magic_"
			Listed.Push(Group["prefix"])
	}
	_KSNR_AssertList(Corpus["families"]["windows"], Listed, "the menu groups")
	Keys := KeyboardSlotDeclaration()["keys"]
	for Extra in Corpus["extra_keys"]["windows"] {
		Found := false
		for Key in Keys
			Found := Found || Key == Extra
		AssertTrue(Found, "the slot domain offers " . Extra)
	}
}
Test("neutral slots: families, menu groups and extra keys follow the role table", _KSNR_FamiliesAndKeysMatch)

_KSNR_LabelsNameTheChord() {
	AssertEqual("Ctrl + Shift + V", _FormatSlotLabel("primary_shift_v"), "the longest family wins")
	AssertEqual("Ctrl + B", _FormatSlotLabel("primary_b"))
	AssertEqual("Win + A", _FormatSlotLabel("meta_a"))
	AssertEqual("Win + ²", _FormatSlotLabel("meta_sc029"))
	AssertEqual("Win + '", _FormatSlotLabel("meta_quote"))
	AssertEqual("Win + Caps Lock", _FormatSlotLabel("meta_capslock"))
	AssertEqual("Alt + .", _FormatSlotLabel("alt_period"))
}
Test("neutral slots: the tray label names the Windows chord", _KSNR_LabelsNameTheChord)

; The fake VkKeyScanExW of one layout: its moved keys, the plain letter otherwise.
_KSNR_VkScan(Scans, Key, *) {
	return Scans.Has(Key) ? Scans[Key] : Ord(StrUpper(Key))
}

; Each chord on each AltGr family: the same exact native spec, through the same
; key resolver seam the registrar uses, with no AltGr owner in it.
_KSNR_ChordsHoldOnBothAltGrFamilies() {
	; VkKeyScan answers of the two layouts for the keys that move: AZERTY reaches
	; "." and "," differently and types "'" on the 4 key; Kana types it shifted.
	Layouts := Map(
		"standard", Map("'", 0x34, ".", 0x1BE, ",", 0xBC),
		"kana", Map("'", 0x137, ".", 0xBE, ",", 0xBC))
	for Family, Scans in Layouts {
		Saved := _TestSetAltGrFamily(Family == "kana", Family == "standard")
		try {
			Seen := 0
			for Row in _KSNR_Corpus()["crosswalk"] {
				if Row["driver"] != "windows"
					continue
				Seen += 1
				Context := Row["slot"] . " on the " . Family . " AltGr"
				Parsed := ChordParse(_KeyboardSlotChord(Row["slot"]))
				AssertTrue(Parsed["ok"], Context . ": the chord parses")
				Spec := HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"])
				AssertTrue(Spec != "", Context . ": the chord has a native spec")
				AssertFalse(RegExMatch(Spec, "[*~<>]|SC138|vkDF"), Context . ": " . Spec . " must not admit or name AltGr")
				Prefix := ""
				for Modifier in Row["modifiers"]
					Prefix .= Map("ctrl", "^", "shift", "+", "alt", "!", "win", "#")[Modifier]
				AssertEqual(StrLen(Prefix), RegExMatch(Spec, "[^#!^+]") - 1, Context . ": exactly its own modifiers")
				Identity := HotkeyRegistrarResolveNativeKeyIdentity(HotkeyRegistrarNativeKey(Parsed["key"]), Map(
					"get_layout", (*) => 0x4000040C,
					"vk_scan", _KSNR_VkScan.Bind(Scans)))
				AssertTrue(Identity is Map, Context . ": the key " . Parsed["key"] . " resolves")
				AssertFalse(InStr(Identity["implicit_modifiers"], "^") && InStr(Identity["implicit_modifiers"], "!"),
					Context . ": never an AltGr-typed key")
			}
			AssertTrue(Seen >= 18, "every Windows chord is covered")
		} finally
			_TestRestoreAltGrFamily(Saved)
	}
}
Test("neutral slots: each chord keeps its exact spec on AZERTY AltGr and Kana", _KSNR_ChordsHoldOnBothAltGrFamilies)
