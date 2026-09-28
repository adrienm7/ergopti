; tests/unit/test_ergopti_keylayout_tables.ahk

; ==============================================================================
; MODULE: Ergopti Tables Read From The .keylayout — Tests
; DESCRIPTION:
; The Windows Ergopti emulation builds every table from the registry's
; ergopti.keylayout and ergopti_plus.keylayout (ergopti-keylayout-tables):
; - golden: the tables built from the shipped files equal, key by key and
;   dead key by dead key, what the hand-written tables typed before
;   (tests/fixtures/ergopti_emulation_golden.json);
; - the tables come from the file: an edited .keylayout changes them;
; - every deviation from the file is still needed;
; - the generic table reader also reads Ergo-L (smoke test);
; - boot loading verifies the shipped files, publishes the tables once and
;   refuses a second initialisation;
; - the actions built from the data type what the data says.
; Non-ASCII expectations come from the fixture, the .keylayout or Chr() so the
; suite source stays ASCII-only.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_EKT_Golden() => JsonParse(FileRead(_DriverDir . "\tests\fixtures\ergopti_emulation_golden.json", "UTF-8"))

_EKT_Bundled(Id) => LayoutRegistry_ReadBundled(Id, LayoutRegistry_BundledDir())

_EKT_KeyCodes() => KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), "iso")

_EKT_WrapPairs() => ErgoptiLayout_ReadWrapPairs(_SharedDir . "\modules\wrap_symbols\wrap_symbols.json")

_EKT_Spec(ErgoptiText := "", PlusText := "") {
	if (ErgoptiText == "")
		ErgoptiText := _EKT_Bundled("ergopti")["Text"]
	if (PlusText == "")
		PlusText := _EKT_Bundled("ergopti_plus")["Text"]
	return ErgoptiLayout_BuildSpec(Keylayout_Parse(ErgoptiText), Keylayout_Parse(PlusText),
		_EKT_KeyCodes(), _EKT_WrapPairs())
}

; One canonical line per descriptor: Map keys enumerate in sorted order.
_EKT_Describe(Descriptor) {
	if !(Descriptor is Map)
		return "<not a Map>"
	Out := ""
	for Name, Value in Descriptor
		Out .= Name . "=" . Value . " "
	return RTrim(Out)
}

_EKT_Join(Items) {
	Out := ""
	for Item in Items
		Out .= (A_Index > 1 ? "; " : "") . Item
	return Out
}

; The error Fn throws, so a refusal test can pin WHY it was refused: a bare
; AssertThrows also passes on a call to a function that does not exist.
_EKT_Thrown(Fn) {
	try Fn()
	catch as Err
		return Err
	throw Error("expected an error, none was thrown")
}

; Replaces the only occurrence of Old by New, failing loudly otherwise.
_EKT_Tamper(Text, Old, New) {
	Pos := InStr(Text, Old, true)
	if !Pos
		throw Error("tamper target not found: " . Old)
	if InStr(Text, Old, true, Pos + 1)
		throw Error("tamper target is not unique: " . Old)
	return SubStr(Text, 1, Pos - 1) . New . SubStr(Text, Pos + StrLen(Old))
}





; =========================
; =========================
; ======= 2/ Golden =======
; =========================
; =========================

Test("ergopti tables: every key of every layer equals the hand-written tables (ergopti-keylayout-tables)",
	_EKT_GoldenLevelsCase)

_EKT_GoldenLevelsCase() {
	Golden := _EKT_Golden()["levels"]
	Spec := _EKT_Spec()["levels"]
	Mismatches := []
	Keys := 0
	for Level, Expected in Golden {
		if !Spec.Has(Level) {
			Mismatches.Push("level " . Level . " is not built")
			continue
		}
		Built := Spec[Level]
		for Sc, Descriptor in Expected {
			Keys += 1
			if !Built.Has(Sc)
				Mismatches.Push(Level . " " . Sc . " is missing (expected " . _EKT_Describe(Descriptor) . ")")
			else if (_EKT_Describe(Built[Sc]) !== _EKT_Describe(Descriptor))
				Mismatches.Push(Level . " " . Sc . ": " . _EKT_Describe(Built[Sc]) . " instead of " . _EKT_Describe(Descriptor))
		}
		for Sc, Descriptor in Built {
			if !Expected.Has(Sc)
				Mismatches.Push(Level . " " . Sc . " is extra: " . _EKT_Describe(Descriptor))
		}
	}
	AssertEqual(Golden.Count, Spec.Count, "the same layers must be built")
	Assert(Keys >= 230, "the golden file must describe at least 230 keys, got " . Keys)
	AssertEqual(0, Mismatches.Length, _EKT_Join(Mismatches))
}

Test("ergopti tables: every dead-key table equals the hand-written tables (ergopti-keylayout-tables)",
	_EKT_GoldenDeadKeysCase)

_EKT_GoldenDeadKeysCase() {
	Golden := _EKT_Golden()["dead_keys"]
	Built := _EKT_Spec()["dead_keys"]
	Mismatches := []
	Entries := 0
	for Name, Expected in Golden {
		if !Built.Has(Name) {
			Mismatches.Push("dead key " . Name . " is not built")
			continue
		}
		for Input, Output in Expected {
			Entries += 1
			if !Built[Name].Has(Input)
				Mismatches.Push(Name . " [" . Input . "] is missing")
			else if (Built[Name][Input] !== Output)
				Mismatches.Push(Name . " [" . Input . "] types [" . Built[Name][Input] . "] instead of [" . Output . "]")
		}
		for Input, Output in Built[Name] {
			if !Expected.Has(Input)
				Mismatches.Push(Name . " [" . Input . "] is extra")
		}
	}
	AssertEqual(7, Golden.Count, "the golden file must hold the seven Ergopti dead keys")
	AssertEqual(Golden.Count, Built.Count, "the same dead keys must be built")
	Assert(Entries >= 400, "the golden dead-key tables must hold at least 400 entries, got " . Entries)
	AssertEqual(0, Mismatches.Length, _EKT_Join(Mismatches))
}





; =====================================
; =====================================
; ======= 3/ Read from the file =======
; =====================================
; =====================================

; On current code these tables are hand-written, so an edited .keylayout
; changes nothing; read from the file, every edit must show.
Test("ergopti tables: an edited .keylayout changes the layers and the dead keys (ergopti-keylayout-tables)",
	_EKT_ReadFromFileCase)

_EKT_ReadFromFileCase() {
	Original := _EKT_Bundled("ergopti")["Text"]
	; Key code 13 (SC011) types 'y' through its action in keyMap 0, the base level.
	Edited := RegExReplace(Original, 's)(<keyMap index="0">.*?<key code="13" )action="y"', '$1output="k"', &Count, 1)
	AssertEqual(1, Count, "the base 'y' of ergopti.keylayout must be found once")
	; The circumflex composition of 'a' is written once, in the 'a' action.
	Edited := _EKT_Tamper(Edited, '<when state="s1_circumflex" output="' . Chr(0xE2) . '"/>',
		'<when state="s1_circumflex" output="' . Chr(0x3B1) . '"/>')
	Spec := _EKT_Spec(Edited)
	AssertEqual("k", Spec["levels"]["base"]["SC011"]["text"], "the base layer follows the file")
	AssertEqual(Chr(0x3B1), Spec["dead_keys"]["Circumflex"]["a"], "the dead-key table follows the file")
	AssertEqual("y", _EKT_Spec()["levels"]["base"]["SC011"]["text"], "the shipped file is untouched")
}

Test("ergopti tables: every deviation from the .keylayout is still needed (ergopti-keylayout-tables)",
	_EKT_DeviationsNeededCase)

_EKT_DeviationsNeededCase() {
	global ERGOPTI_KEY_DEVIATIONS, ERGOPTI_DEAD_KEY_DEVIATIONS
	FromFile := ErgoptiLayout_BuildSpec(Keylayout_Parse(_EKT_Bundled("ergopti")["Text"]),
		Keylayout_Parse(_EKT_Bundled("ergopti_plus")["Text"]), _EKT_KeyCodes(), _EKT_WrapPairs(),
		Map(), Map())
	Redundant := []
	Count := 0
	for Level, Keys in ERGOPTI_KEY_DEVIATIONS {
		for Sc, Descriptor in Keys {
			Count += 1
			if FromFile["levels"][Level].Has(Sc)
				&& (_EKT_Describe(FromFile["levels"][Level][Sc]) == _EKT_Describe(Descriptor))
				Redundant.Push(Level . " " . Sc)
		}
	}
	for Name, Entries in ERGOPTI_DEAD_KEY_DEVIATIONS {
		for Input, Output in Entries {
			Count += 1
			if FromFile["dead_keys"][Name].Has(Input) && (FromFile["dead_keys"][Name][Input] == Output)
				Redundant.Push(Name . " [" . Input . "]")
		}
	}
	Assert(Count >= 3, "the deviation tables must be enumerated")
	AssertEqual(0, Redundant.Length, "deviations the .keylayout already carries: " . _EKT_Join(Redundant))
}





; =======================================
; =======================================
; ======= 4/ Generic reader smoke =======
; =======================================
; =======================================

Test("keylayout tables: the generic reader builds Ergo-L's layers and dead keys (ergopti-keylayout-tables)",
	_EKT_ErgolSmokeCase)

_EKT_ErgolSmokeCase() {
	Entry := _EKT_Bundled("ergol")
	Tables := KeylayoutTables_Build(Keylayout_Parse(Entry["Text"]),
		KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), Entry["Entry"]["keycode_convention"]))
	Levels := Tables["Levels"]
	for Level in ["base", "shift", "caps", "altgr", "altgr_shift"]
		Assert(Levels[Level].Count >= 30, "Ergo-L must type on at least 30 keys of its " . Level . " level, got " . Levels[Level].Count)
	AssertEqual("q", Levels["base"]["SC010"]["Text"])
	AssertEqual("Q", Levels["shift"]["SC010"]["Text"])
	AssertEqual("Q", Levels["caps"]["SC010"]["Text"])
	AssertEqual("^", Levels["altgr"]["SC010"]["Text"])
	AssertEqual("dead", Levels["base"]["SC018"]["Kind"], "Ergo-L's one dead key sits on SC018")
	OneDeadKey := Levels["base"]["SC018"]["State"]
	Inputs := Tables["DeadKeys"][OneDeadKey]["Inputs"]
	AssertEqual(Chr(0xE8), Inputs["e"]["Output"], "one dead key then e")
	; Read by hand from ergol.keylayout, like the shared keystroke vectors.
	AssertEqual(Chr(0xE2), Inputs["q"]["Output"], "one dead key then q")
	Assert(Inputs[Tables["DeadKeys"][OneDeadKey]["Terminator"]]["Next"] != "",
		"pressing the one dead key twice chains to another dead key")
	Assert(Tables["DeadKeys"].Count >= 10, "Ergo-L has at least ten dead keys")
}

Test("keylayout tables: a character composing two ways in one dead key is refused (ergopti-keylayout-tables)",
	_EKT_AmbiguousDeadKeyCase)

_EKT_AmbiguousDeadKeyCase() {
	Build(SecondOutput) => KeylayoutTables_DeadKeys(Keylayout_Parse(
		'<keyboard group="0" id="1" name="T"><layouts><layout first="0" last="0" mapSet="S" modifiers="M"/></layouts>'
		. '<modifierMap id="M" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect></modifierMap>'
		. '<keyMapSet id="S"><keyMap index="0"><key code="0" action="d"/><key code="1" action="x1"/>'
		. '<key code="2" action="x2"/></keyMap></keyMapSet>'
		. '<actions><action id="d"><when state="none" next="s"/></action>'
		. '<action id="x1"><when state="none" output="x"/><when state="s" output="1"/></action>'
		. '<action id="x2"><when state="none" output="x"/><when state="s" output="' . SecondOutput . '"/></action></actions>'
		. '<terminators><when state="s" output="^"/></terminators></keyboard>'),
		Map("SC010", 0, "SC011", 1, "SC012", 2))
	; Control: two keys composing the same way are one unambiguous entry.
	AssertEqual("1", Build("1")["s"]["Inputs"]["x"]["Output"])
	Err := _EKT_Thrown(() => Build("2"))
	Assert(Err is ValueError, "an ambiguous dead key must raise a ValueError, got " . Type(Err) . ": " . Err.Message)
	AssertContains(Err.Message, "compose differently", "x cannot type both 1 and 2 after the dead key")
}





; ==================================
; ==================================
; ======= 5/ Loading at boot =======
; ==================================
; ==================================

Test("ergopti tables: boot loading publishes the tables every layer registers (ergopti-keylayout-tables)",
	_EKT_PublishedCase)

_EKT_PublishedCase() {
	global SHIFTED_LETTERS, SHIFT_SYMBOLS, CAPSLOCK_SYMBOLS, ALTGR_BASE_ROWS, ALTGR_NUMBER_ROW
	global ALTGR_PLUS_OVERRIDES, DeadkeyMappingCircumflex, DeadkeyMappingDiaresis
	_TestEnsureErgoptiLayout()
	AssertTrue(ErgoptiLayout_IsLoaded())
	_BuildShiftCapsTables()
	_BuildAltGrTables()
	AssertEqual(40, SHIFTED_LETTERS.Count)
	AssertEqual(9, SHIFT_SYMBOLS.Count)
	AssertEqual(8, CAPSLOCK_SYMBOLS.Count)
	AssertEqual(36, ALTGR_BASE_ROWS.Count)
	AssertEqual(13, ALTGR_NUMBER_ROW.Count)
	AssertEqual(3, ALTGR_PLUS_OVERRIDES.Count)
	AssertEqual(Chr(0xE2), DeadkeyMappingCircumflex["a"])
	AssertEqual(Chr(0xEB), DeadkeyMappingDiaresis["e"])
	Mapping := ErgoptiBaseMapping()
	AssertEqual(34, Mapping.Count, "the base layer remaps every key but the number row and the dead keys")
	AssertEqual("y", Mapping[0x11])
	AssertEqual(Chr(0xE8), Mapping[0x10].alt, "an accented key types its letter")
	Dead := ErgoptiBaseDeadKeys()
	AssertEqual(2, Dead.Count)
	AssertEqual("^", Dead["SC02B"]["chain"])
	AssertTrue(Dead["SC02B"]["table"] == DeadkeyMappingCircumflex, "the base dead key composes with the published table")
	Labels := ErgoptiBaseLabels()
	AssertEqual(36, Labels.Count, "the heatmap labels every remapped key and both dead keys")
	AssertEqual(Chr(0xA8), Labels[0x1B])
	AssertContains(_EKT_Thrown(() => ErgoptiLayout_Init(LayoutRegistry_BundledDir())).Message, "already loaded",
		"a second initialisation is refused")
}

Test("ergopti tables: a shipped layout that fails its checksum is refused (ergopti-keylayout-tables)",
	_EKT_ChecksumCase)

_EKT_ChecksumCase() {
	Dir := A_Temp . "\ergopti_bundled_registry_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Dir . "ergopti")
	try {
		FileCopy(LayoutRegistry_BundledDir() . "index.json", Dir . "index.json")
		; Control: an untouched copy of the shipped folder reads, so the refusals
		; below come from the edit and the missing file, not from the copy.
		FileCopy(LayoutRegistry_BundledDir() . "ergopti\ergopti.keylayout", Dir . "ergopti\ergopti.keylayout")
		AssertEqual("ergopti", LayoutRegistry_ReadBundled("ergopti", Dir)["Entry"]["id"])
		Text := _EKT_Bundled("ergopti")["Text"]
		Edited := _EKT_Tamper(Text, 'name="Ergopti_v2_2_2"', 'name="Ergopti_v2_2_3"')
		F := FileOpen(Dir . "ergopti\ergopti.keylayout", "w", "UTF-8-RAW")
		F.Write(Edited)
		F.Close()
		AssertContains(_EKT_Thrown(() => LayoutRegistry_ReadBundled("ergopti", Dir)).Message, "checksum",
			"an edited shipped layout must be refused")
		AssertContains(_EKT_Thrown(() => LayoutRegistry_ReadBundled("ergopti_plus", Dir)).Message, "Cannot read",
			"a missing shipped layout must be refused")
	} finally DirDelete(Dir, true)
}





; ====================================
; ====================================
; ======= 6/ Actions from data =======
; ====================================
; ====================================

Test("ergopti tables: each descriptor becomes the action it describes (ergopti-keylayout-tables)",
	_EKT_ActionsCase)

_EKT_ActionsCase() {
	global _Stub_SentText, _Stub_DeadKeyCalls, _Stub_RecordedSends, SpaceAroundSymbols, InDeadKeySequence
	Table := Map("a", "b")
	Tables := Map("Circumflex", Table)
	ResetStubRecorders()
	Cb := ErgoptiLayout_Action(Map("wrap", "(", "left", "(", "right", ")"), Tables)
	Cb()
	AssertEqual("wrap ( ( )", _Stub_SentText[1].kind . " " . _Stub_SentText[1].symbol . " "
		. _Stub_SentText[1].left . " " . _Stub_SentText[1].right)
	Cb := ErgoptiLayout_Action(Map("dead", "Circumflex"), Tables)
	Cb()
	AssertTrue(_Stub_DeadKeyCalls[1] == Table, "a dead key composes with its table")
	Cb := ErgoptiLayout_Action(Map("none", true), Tables)
	Cb()
	AssertEqual(1, _Stub_SentText.Length, "nothing is typed")
	AssertEqual(1, _Stub_DeadKeyCalls.Length)

	ResetHotstringRecorders()
	SavedSpace := SpaceAroundSymbols
	SpaceAroundSymbols := " "
	try {
		Cb := ErgoptiLayout_Action(Map("word", "ou"), Tables)
		Cb()
	} finally SpaceAroundSymbols := SavedSpace
	Sent := ""
	for Rec in _Stub_RecordedSends
		if (Rec.fn == "SendNewResult")
			Sent .= "[" . Rec.args[1] . "]"
	AssertContains(Sent, "[ou ]", "a word is followed by the space-around-symbols setting")

	ResetHotstringRecorders()
	InDeadKeySequence := true
	try {
		Cb := ErgoptiLayout_Action(Map("dead", "Circumflex", "chain", "^"), Tables)
		Cb()
	} finally InDeadKeySequence := false
	Sent := ""
	for Rec in _Stub_RecordedSends
		if (Rec.fn == "SendNewResult")
			Sent .= "[" . Rec.args[1] . "]"
	AssertContains(Sent, "[^]", "inside a dead-key sequence the dead key types its accent")
	AssertThrows(() => ErgoptiLayout_Action(Map("dead", "Unknown"), Tables), "an unknown dead key is refused")
	AssertThrows(() => ErgoptiLayout_Action(Map("strange", 1), Tables), "an unknown descriptor is refused")
}
