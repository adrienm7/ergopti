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





; ===================================================
; ===================================================
; ======= 7/ Legacy plus output characterization ====
; ===================================================
; ===================================================

_EKT_PlusMatrix() => JsonParse(FileRead(_DriverDir . "\tests\fixtures\ergopti_plus_altgr_output_matrix.json", "UTF-8"))

_EKT_PlusPhysicalShift(Shift, Name, Mode) => Shift && Name == "Shift" && Mode == "P"

_EKT_PlusLegacyActionsCase() {
	global ALTGR_PLUS_OVERRIDES, ALTGR_BASE_ROWS, ALTGR_NUMBER_ROW, CTRL_ALT_NUMPAD, SpaceAroundSymbols
	global _TapHoldKeyIsDown, _TH_SyntheticHeldKeys, _Stub_SentText, _Stub_RecordedSends, _Stub_LastChars
	global LastSentCharacterKeyTime, _LSC_RING, _LSC_CURSOR, _LSC_LEN
	_TestEnsureErgoptiLayout()
	Saved := [ALTGR_PLUS_OVERRIDES, ALTGR_BASE_ROWS, ALTGR_NUMBER_ROW, SpaceAroundSymbols,
		_TapHoldKeyIsDown, _TH_SyntheticHeldKeys, _Stub_SentText, _Stub_RecordedSends, _Stub_LastChars,
		LastSentCharacterKeyTime, _LSC_RING, _LSC_CURSOR, _LSC_LEN, CTRL_ALT_NUMPAD]
	try {
		LastSentCharacterKeyTime := LastSentCharacterKeyTime.Clone()
		_LSC_RING := _LSC_RING.Clone()
		_BuildAltGrTables()
		AssertEqual(3, ALTGR_PLUS_OVERRIDES.Count, "the actual published legacy table contains all three keys")
		Matrix := _EKT_PlusMatrix()
		AssertEqual(6, Matrix["rows"].Length)
		Observed := 0
		for Row in Matrix["rows"] {
			AssertTrue(ALTGR_PLUS_OVERRIDES.Has(Row["scan"]), "the real table must publish the matrix key")
			_TapHoldKeyIsDown := _EKT_PlusPhysicalShift.Bind(Row["shift"])
			_TH_SyntheticHeldKeys := Map()
			for Spacing in ["", " "] {
				SpaceAroundSymbols := Spacing
				_Stub_SentText := []
				_Stub_RecordedSends := []
				_Stub_LastChars := []
				Cb := AltGrLayerEntryCallable(ALTGR_PLUS_OVERRIDES[Row["scan"]])
				Cb.Call()
				Descriptor := Row["descriptor"]
				if Descriptor.Has("wrap") {
					AssertEqual(1, _Stub_SentText.Length, "the real action requests wrapping once")
					AssertEqual("wrap", _Stub_SentText[1].kind)
					AssertEqual(Descriptor["wrap"], _Stub_SentText[1].symbol)
					AssertEqual(Descriptor["left"], _Stub_SentText[1].left)
					AssertEqual(Descriptor["right"], _Stub_SentText[1].right)
				} else {
					AssertEqual(0, _Stub_SentText.Length, "text and words do not request wrapping")
					Texts := []
					for Send in _Stub_RecordedSends
						if Send.fn == "SendNewResult"
							Texts.Push(Send.args[1])
					AssertEqual(1, Texts.Length, "the actual action emits its text exactly once")
					Expected := Descriptor.Has("word") ? Descriptor["word"] . Spacing : Descriptor["text"]
					AssertEqual(Expected, Texts[1], "word spacing and explicit Shift deviations remain owned by the legacy action")
				}
				Observed += 1
			}
		}
		AssertEqual(12, Observed, "all six actions execute under both spacing settings")
	} finally {
		ALTGR_PLUS_OVERRIDES := Saved[1]
		ALTGR_BASE_ROWS := Saved[2]
		ALTGR_NUMBER_ROW := Saved[3]
		SpaceAroundSymbols := Saved[4]
		_TapHoldKeyIsDown := Saved[5]
		_TH_SyntheticHeldKeys := Saved[6]
		_Stub_SentText := Saved[7]
		_Stub_RecordedSends := Saved[8]
		_Stub_LastChars := Saved[9]
		LastSentCharacterKeyTime := Saved[10]
		_LSC_RING := Saved[11]
		_LSC_CURSOR := Saved[12]
		_LSC_LEN := Saved[13]
		CTRL_ALT_NUMPAD := Saved[14]
	}
}
Test("Ergopti+ matrix: every actual legacy plus action preserves wrap, word spacing and Shift deviations (todo96-output-matrix)",
	_EKT_PlusLegacyActionsCase)

; layout.ahk registers top-level hotkeys and is outside the headless include
; graph. Execute its exact production definitions in an owned native child,
; following the isolated production-helper pattern used by atomic-temp-owner.
_EKT_PlusRollScript() {
	Code := "#Requires AutoHotkey v2.0`n"
	Code .= "#SingleInstance Off`n"
	Code .= '#Include ' . _DriverDir . '\infra\json.ahk' . "`n"
	Code .= '#Include ' . _DriverDir . '\adapters\file_system.ahk' . "`n"
	for Name in ["_RollChevronEqualEmit", "AddRollEqual", "_RollEmitCritical", "AltGrLayerShiftHeld"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the actual roll definition must exist before constructing the native fixture")
		Code .= Definition . "`n"
	}
	Code .= 'global Features := Map("layout", Map("ergopti_plus", false))' . "`n"
	Code .= 'global _TH_SyntheticHeldKeys := Map(), _PP_Mode := "none", _PP_Kind := "", _PP_Output := "", _PP_Calls := 0' . "`n"
	Code .= 'global _TapHoldKeyIsDown := _PP_ShiftQuery' . "`n"
	Code .= '_PP_ShiftQuery(Name, Mode) => _PP_Mode == "physical" && Name == "Shift" && Mode == "P"' . "`n"
	Code .= 'GetLastSentCharacterAt(*) => ""' . "`n"
	Code .= 'HotstringsResolve(*) {`nthrow Error("the neutral roll must not resolve a recent-chevron delay")`n}' . "`n"
	Code .= 'SendNewResult(Text) {`nglobal _PP_Kind, _PP_Output, _PP_Calls`n_PP_Calls += 1`n_PP_Kind := "text"`n_PP_Output := Text`n}' . "`n"
	Code .= 'WrapTextIfSelected(Symbol, Left, Right) {`nglobal _PP_Kind, _PP_Output, _PP_Calls`n_PP_Calls += 1`nif Symbol != Left || Symbol != Right`nthrow Error("the real percent wrap must preserve both boundaries")`n_PP_Kind := "wrap"`n_PP_Output := Symbol`n}' . "`n"
	Code .= 'Rows := JsonParse(FileRead(A_Args[1], "UTF-8"))["roll_rows"]' . "`n"
	Code .= 'Packet := "["' . "`n"
	Code .= 'for Row in Rows {`nFeatures["layout"]["ergopti_plus"] := Row["plus"]`n_PP_Mode := Row["shift"]`n_TH_SyntheticHeldKeys := Map()`nif _PP_Mode == "left_hold"`n_TH_SyntheticHeldKeys["LShift"] := 1`nif _PP_Mode == "right_hold"`n_TH_SyntheticHeldKeys["RShift"] := 1`n_PP_Kind := ""`n_PP_Output := ""`n_PP_Calls := 0`n_RollChevronEqualEmit()`nPacket .= (A_Index > 1 ? "," : "") . "[" . JsonStringLiteral(_PP_Kind) . "," . JsonStringLiteral(_PP_Output) . "," . _PP_Calls . "]"`n}' . "`n"
	Code .= 'Packet .= "]"' . "`n"
	Code .= 'if !FSWriteCreateDurable(A_Args[2], Packet)`nthrow Error("the owned roll receipt could not become durable")' . "`n"
	Code .= 'FileAppend("roll-matrix-written", "*")`nExitApp(0)`n'
	return Code
}

_EKT_PlusRollCompletion(State, Code, Output, ErrorText) {
	State.Code := Code
	State.Output := Output
	State.ErrorText := ErrorText
	State.Calls += 1
}

_EKT_PlusRollNativeCase() {
	Stem := A_Temp . "\ergopti_plus_roll_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Script := Stem . ".ahk"
	Receipt := Stem . ".json"
	AssertFalse(FileExist(Script) || FileExist(Receipt), "the native fixture owns fresh paths")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _EKT_PlusRollScript()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }
	Handle := 0
	Primary := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", Script, _DriverDir . "\tests\fixtures\ergopti_plus_altgr_output_matrix.json", Receipt],
			_EKT_PlusRollCompletion.Bind(State))
		AssertTrue(Handle.start(), "the actual source-helper native child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 5000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the actual owned native child must settle once")
		AssertTrue(State.Code is Integer, "the native completion must have a typed process status")
		AssertEqual(0, State.Code, "the exact production roll definitions must finish successfully")
		AssertEqual("roll-matrix-written", State.Output, "only the fixed native completion acknowledgement is emitted")
		AssertEqual("", State.ErrorText)
		Actual := JsonParse(FileRead(Receipt, "UTF-8"))
		Expected := _EKT_PlusMatrix()["roll_rows"]
		AssertEqual(8, Expected.Length, "plain, physical Shift and both held Shift sides require both option states")
		AssertEqual(Expected.Length, Actual.Length, "every actual roll result is admitted")
		for Row in Expected {
			AssertEqual(3, Actual[A_Index].Length)
			AssertEqual(1, Actual[A_Index][3], "the actual production roll emits exactly once")
			AssertEqual(Row["kind"], Actual[A_Index][1], "the actual roll retains wrap versus text ownership")
			AssertEqual(Row["output"], Actual[A_Index][2], "the actual SC012 roll retains the independent percent/ligature output")
		}
	} catch as Err {
		Primary := Err
	}
	Retired := false
	try Retired := !IsObject(Handle) || ((Result := Handle.terminate()) is Integer && Result == 1)
	catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	if Retired {
		try {
			FileDelete(Script)
			if FileExist(Receipt)
				FileDelete(Receipt)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "receipt paths remain retained unless the exact native tree retires")
}
Test("Ergopti+ matrix: the actual native SC012 roll preserves extra percent and ligature outputs (todo96-output-matrix)",
	_EKT_PlusRollNativeCase)
