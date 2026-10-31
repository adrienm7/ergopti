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

; The Win and Ctrl switches registered on the key that TYPES the letter under the
; Ergopti emulation, and a slot used to bind the host layout's key. Each switch
; became a slot in schema v19, so a slot must keep the switch's key.
_KSNR_EmulatedLetterKeepsItsKey() {
	global RemappedList
	Saved := RemappedList
	RemappedList := Map("a", "SC01E", "b", "sc30")
	try {
		AssertEqual("SC01E", KeyboardSlotLayoutScan("meta_a"), "a remapped letter is the key that types it")
		AssertEqual("SC030", KeyboardSlotLayoutScan("primary_b"), "whatever the scan's spelling")
		AssertEqual("", KeyboardSlotLayoutScan("meta_c"), "the host layout answers a letter the emulation leaves")
		AssertEqual("", KeyboardSlotLayoutScan("meta_space"), "a named key is no letter")
		AssertEqual("", KeyboardSlotLayoutScan("magic_editor"), "the contextual slot names no chord")
		Parsed := ChordParse(_KeyboardSlotBoundChord("primary_b", "SC030"))
		AssertEqual("^SC030", HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"]), "the Ctrl slot binds that key")
		Parsed := ChordParse(_KeyboardSlotBoundChord("primary_c", ""))
		AssertEqual("^c", HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"]), "without a scan the letter stays")
	} finally
		RemappedList := Saved
	AssertTrue(RegExMatch(KeyboardSlotLayoutScan("meta_quote"), "^SC[0-9A-F]{3}$") > 0, "the apostrophe is a key of its own")
}
Test("neutral slots: a slot keeps the key the emulation types its letter on", _KSNR_EmulatedLetterKeepsItsKey)

_KSNR_CapsLockIsThePhysicalKey() {
	Parsed := ChordParse(_KeyboardSlotChord("meta_capslock"))
	AssertEqual("#SC03A", HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"]),
		"a scan-code hotkey on the key hides a key-name one, so the chord names the scan")
}
Test("neutral slots: Win + Caps Lock keeps its scan-code hotkey", _KSNR_CapsLockIsThePhysicalKey)

; A Win chord Windows holds reaches AutoHotkey only through its hook, where the
; inert scan-code hotkeys of the layout tables hid a textual #s: Win+S opened
; Windows Search with the slot set. The live check win-s-open-target presses it.
_KSNR_WinSlotBindsItsPhysicalKey() {
	global RemappedList, KeyboardShortcutAssignments
	SavedList := RemappedList
	HadAssignments := IsSet(KeyboardShortcutAssignments)
	if HadAssignments
		SavedAssignments := KeyboardShortcutAssignments
	State := MagicEditorState()
	SavedPhysical := State["ordinary_physical"], SavedInitialized := State["initialized"]
	Expected := Format("SC{:03X}", GetKeySC("s"))
	RemappedList := Map()
	KeyboardShortcutAssignments := Map("meta_s", "copy_selected_path")
	State["ordinary_physical"] := Map(), State["initialized"] := false
	try {
		AssertEqual(Expected, KeyboardSlotWinScan("meta_s"), "a letter the emulation leaves still binds its key")
		AssertEqual("", KeyboardSlotWinScan("meta_sc029"), "a key spelled by its scan keeps that spelling")
		AssertEqual("", KeyboardSlotWinScan("meta_capslock"), "so does Caps Lock")
		AssertEqual("", KeyboardSlotWinScan("magic_editor"), "the contextual slot names no chord")
		KeyboardShortcutsBindAll()
		AssertTrue(State["ordinary_physical"].Has(Expected), "the Win slot joins the physical broker on its key")
		AssertEqual("meta_s", State["ordinary_physical"][Expected]["slot"], "the broker runs that slot")
		AssertFalse(HOTKEY_REGISTRAR_SPECS.Has("#s"), "no textual Win chord is registered for the slot")
	} finally {
		RemappedList := SavedList
		KeyboardShortcutAssignments := HadAssignments ? SavedAssignments : unset
		State["ordinary_physical"] := SavedPhysical, State["initialized"] := SavedInitialized
	}
}
Test("neutral slots: a Win slot binds its physical key, not a textual chord (win-s-open-target)", _KSNR_WinSlotBindsItsPhysicalKey)

; Boot order: the slots read RemappedList, and the Win broker acquires its keys once.
_KSNR_SlotsBindBetweenLayoutAndBroker() {
	Src := _DriverSourceNoComments()
	Layout := InStr(Src, "#Include modules/keymap/layout.ahk")
	Bind := InStr(Src, "KeyboardShortcutsBindAll()" . "`n")
	Broker := InStr(Src, "MagicEditorStart()" . "`n")
	AssertTrue(Layout > 0 && Bind > Layout, "the slots bind once the layout tables exist")
	AssertTrue(Broker > Bind, "the slots join the broker before it acquires its keys")
}
Test("neutral slots: the slots bind after the layout and before the Win broker", _KSNR_SlotsBindBetweenLayoutAndBroker)

; The switches owned these until v19: an action must work with no switch at all.
_KSNR_ActionsNeedNoSwitch() {
	Win := _DriverDirConcat("modules/shortcuts")
	AssertTrue(RegExMatch(Win, "m)^global AWAKE_TICK_MIN_MS") > 0, "keep-awake's constants exist whatever is bound")
	AssertFalse(RegExMatch(Win, 'if Features\["shortcuts"\]\["(move|search|open_downloads|get_hex_value|screen)"\]'),
		"no retired switch gates an action's owner")
	Body := _DriverFuncBody("GestureTakeNote")
	AssertTrue(InStr(Body, '"keyboard__"') > 0, "a keyboard binding starts its note on a fresh line, as Win+N did")
	AssertTrue(GESTURE_ACTIONS.Has("open_chatgpt"), "Win+G's recommended action exists on Windows")
	; A switch was off with the Shortcuts category off, whatever it stored.
	Bind := _DriverFuncBody("KeyboardShortcutsBindAll")
	AssertTrue(InStr(Bind, 'IsCategoryGated("Shortcuts")') > 0 && InStr(Bind, 'IsCategoryGated("Shortcuts")') < InStr(Bind, "HotkeyRegistrarBind("),
		"a native slot hotkey is not taken while the Shortcuts category is off")
}
Test("neutral slots: the actions of the retired switches stand alone", _KSNR_ActionsNeedNoSwitch)
