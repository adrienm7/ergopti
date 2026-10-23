; tests/unit/modules/keymap/test_number_row_symbols.ahk

; ==============================================================================
; MODULE: Number Row Symbols Mode
; DESCRIPTION:
; The number row's typed source policy refuses unsupported and stale
; owners, its symbols use the registered KLE levels and dead actions, its
; menu callbacks keep a strict native acknowledgement, and boot keeps
; native input until a source is published.
; ==============================================================================

#Requires AutoHotkey v2.0

; The keymap module holding the number-row hotkeys, found through one of its
; own functions rather than by its path, without its full-line comments.
_NRP_LayoutSource() {
	Source := _StripFullLineComments(FileRead(_DriverProductionFileForSymbol("RemapKey"), "UTF-8"))
	AssertTrue(InStr(Source, "RegisterBuiltinNumberRow()") > 0, "the number-row hotkeys module must be found")
	return Source
}





/** Replays the independent typed capability and real descriptor corpus. */
_NRP_SharedPolicyCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_policy.json"))
	AssertEqual(18, Corpus["capabilities"].Length, "all three drivers and source capabilities are represented")
	for Row in Corpus["capabilities"]
		AssertEqual(Row["expected"], NumberRowPolicyCapable(Row["platform"], Row["mode"], Row["symbols"]))
	for Row in Corpus["symbols"] {
		Actual := NumberRowPolicySymbolsShift(Row["digit"], Row["plain"], Row["shifted"])
		AssertEqual(Row["supported"], Actual["supported"], "only actual typed text/dead source descriptors are valid")
		if Row["supported"]
			AssertEqual(Row["shift"], Actual["shift"], "the non-digit level is independently specified")
	}
	; Native dead previews carry no emulation Action/State. Missing source fields
	; must refuse in either position, without throwing or inventing delivery.
	for Incomplete in [Map("Kind", "text"),
		Map("Kind", "dead", "State", "circumflex", "Text", "^"),
		Map("Kind", "dead", "Action", "circumflex", "Text", "^"),
		Map("Kind", "dead", "Action", "circumflex", "State", "circumflex")] {
		Digit := Map("Kind", "text", "Text", "1")
		AssertFalse(NumberRowPolicySymbolsShift("1", Incomplete, Digit)["supported"],
			"missing descriptor fields must refuse as the plain source")
		AssertFalse(NumberRowPolicySymbolsShift("1", Digit, Incomplete)["supported"],
			"missing descriptor fields must refuse as the shifted source")
	}
	for Value in Corpus["invalid_modes"]
		AssertEqual("", NumberRowPolicyMode(Value), "legacy booleans belong to migration, never runtime truthiness")
	Owner := Map(), Source := Map()
	Expected := Map("owner", Owner, "source", Source, "native_owner", Map(), "generation", 2, "lifecycle", 3,
		"hkl", -268435447, "platform", "ahk", "mode", "native", "symbols", true,
		"master", true, "paused", false, "blocked", false, "caps", false)
	for Mode in ["native", "digits", "symbols"]
		AssertTrue(NumberRowPolicyIntent(Expected, Expected.Clone(), Mode))
	for Field in ["owner", "source", "native_owner", "generation", "lifecycle", "hkl", "mode", "symbols", "caps"] {
		Current := Expected.Clone()
		Current[Field] := Field == "owner" || Field == "source" || Field == "native_owner" ? Map()
			: Field == "mode" ? "digits" : Field == "caps" ? true
			: Field == "symbols" ? false : Current[Field] + 1
		AssertFalse(NumberRowPolicyIntent(Expected, Current, "native"), "a retained callback cannot borrow changed " . Field)
	}
}
Test("number row: shared typed source policy refuses unsupported and stale owners", _NRP_SharedPolicyCorpus)

; Corpus spelling of one level: "" types nothing, "dead:x" a dead key, else text.
_NRP_CorpusDescriptor(Spelling) {
	if Spelling == ""
		return 0
	if SubStr(Spelling, 1, 5) == "dead:"
		return Map("Kind", "dead", "Text", SubStr(Spelling, 6), "State", "corpus", "Action", "corpus")
	return Map("Kind", "text", "Text", Spelling, "State", "", "Action", "")
}

_NRP_CorpusLevels(Vec) {
	Levels := []
	Loop 10
		Levels.Push(Map("plain", _NRP_CorpusDescriptor(Vec["plain"][A_Index]),
			"shift", _NRP_CorpusDescriptor(Vec["shift"][A_Index])))
	return Levels
}

/** Each ordering option is offered only where it makes base differ from Shift. */
_NRP_AvailabilityCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_policy.json"))
	AssertEqual(10, Corpus["availability"].Length, "every row shape of the rule is represented")
	ById := Map()
	for Vec in Corpus["availability"] {
		ById[Vec["id"]] := Vec
		Actual := NumberRowPolicyAvailability(_NRP_CorpusLevels(Vec))
		AssertEqual(Vec["digits"], Actual["digits"], Vec["id"] . ": digits first")
		AssertEqual(Vec["symbols"], Actual["symbols"], Vec["id"] . ": symbols first")
	}
	for Vec in Corpus["effective"] {
		Actual := NumberRowPolicyEffective(Vec["mode"], NumberRowPolicyAvailability(_NRP_CorpusLevels(ById[Vec["availability"]])))
		AssertEqual(Vec["effective"], Actual["mode"], Vec["mode"] . " on " . Vec["availability"])
		AssertEqual(Vec["reason"], Actual["reason"], Vec["mode"] . " on " . Vec["availability"] . ": reason")
	}
	AssertThrows(() => NumberRowPolicyAvailability([]), "the rule needs all ten keys")
}
Test("number row: options are offered only where they reorder all ten keys (number-row-availability)", _NRP_AvailabilityCorpus)

/** The edge keys join an ordering only where swapping each of them changes it. */
_NRP_EdgesCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_policy.json"))
	AssertEqual(6, Corpus["edges"].Length, "every edge-key case of the rule is represented")
	for Vec in Corpus["edges"] {
		Edges := []
		Loop 3
			Edges.Push(Map("plain", _NRP_CorpusDescriptor(Vec["plain"][A_Index]),
				"shift", _NRP_CorpusDescriptor(Vec["shift"][A_Index])))
		AssertEqual(Vec["expected"], NumberRowPolicyEdgesAvailability(Edges, Vec["ordering"]), Vec["id"])
	}
	AssertThrows(() => NumberRowPolicyEdgesAvailability([], "digits"), "the rule needs the three edge keys")
}
Test("number row: the edge keys join an ordering only where swapping them changes them (number-row-edge-keys)", _NRP_EdgesCorpus)

; Runs Fn with the logger writing only to its ring buffer; returns the lines.
_NRP_CaptureLog(Fn) {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	Saved := [LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL, _LOGGER_PENDING,
		_LOGGER_PENDING_ERRORS, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH]
	LOGGER_RING_BUFFER := [], LOGGER_RING_CURSOR := 0, LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := [], _LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := "", LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_DEDUP_KEY := "", _LOGGER_DEDUP_LEVEL := "", _LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
	try {
		Fn.Call()
		Out := ""
		for _, Line in LOGGER_RING_BUFFER
			Out .= Line . "`n"
		return Out
	} finally {
		LOGGER_RING_BUFFER := Saved[1], LOGGER_RING_CURSOR := Saved[2], LOGGER_MIN_LEVEL := Saved[3]
		_LOGGER_PENDING := Saved[4], _LOGGER_PENDING_ERRORS := Saved[5]
		LOGGER_LOG_PATH := Saved[6], LOGGER_ERRORS_LOG_PATH := Saved[7]
		_LoggerRefreshFastFlags()
	}
}

; Publishes Layout as the configured layout section, through the master gate.
_NRP_UseLayout(Layout) {
	global Features, CategoryEnabled, LayerEnabled
	Features := Map("layout", Layout)
	CategoryEnabled := Map("Layout", true)
	LayerEnabled := false
	State := MasterGateState()
	State["initialized"] := false
	MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
}

; « Digits first » stored on AZERTY, then the built-in Ergopti and the Ergo-L
; emulation over it, then AZERTY again: the stored choice is never rewritten,
; it is inert where it cannot reorder the row and applies again on AZERTY with
; no user action, and each switch is logged once (number-row-inert-choice).
_NRP_StoredChoiceSurvivesLayouts() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id, _DigitRowProfiles
	global _NumberRowAvailabilityCache, _NumberRowEffectiveLogged
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), _DigitRowProfiles, _NumberRowEffectiveLogged]
	Azerty := _LDRP_Layout("0000040C")
	if !Azerty
		Azerty := 0x040C040C
	Dir := _KLT_TempDir()
	Path := Dir . "number_row.toml"
	Image := '[layout]`ndirect_access_digits = "digits"`n'
	FileAppend(Image, Path, "UTF-8-RAW")
	Steps := []
	Native := Map("emulated_layout", "", "ergopti_base", false, "ergopti_alt_gr", false,
		"ergopti_variant", "none", "direct_access_digits", "digits")
	Builtin := Native.Clone(), Builtin["ergopti_base"] := true, Builtin["ergopti_variant"] := "ergopti"
	Registry := Native.Clone(), Registry["emulated_layout"] := "ergol", Registry["ergopti_base"] := true
	Observe(Name, Layout, Expected, Swapped) {
		_NRP_UseLayout(Layout)
		if Layout["emulated_layout"] != ""
			_KLT_Load(Layout["emulated_layout"])
		else {
			KLE_Model := 0
			KLE_Id := ""
		}
		AssertEqual(Expected, NumberRowEffectiveMode(Azerty, false), Name . ": the ordering in effect")
		AssertEqual(Swapped, DigitRowIsSwapped(Azerty, false), Name . ": the row is swapped exactly while it applies")
		AssertEqual("digits", MasterGateDesiredFeatures(Features)["layout"]["direct_access_digits"],
			Name . ": the stored choice is kept")
		AssertEqual(Image, FSReadUtf8Exact(Path), Name . ": the configuration bytes are untouched")
	}
	try {
		_NumberRowEffectiveLogged := ""
		_DigitRowProfiles := Map()
		Log := _NRP_CaptureLog(() => (
			Observe("AZERTY", Native, "digits", true),
			Observe("built-in Ergopti", Builtin, "native", false),
			Observe("Ergo-L", Registry, "native", false),
			Observe("AZERTY again", Native, "digits", true)))
		StrReplace(Log, "is not applied on this layout (digits_on_both)", , , &ErgoptiInert)
		StrReplace(Log, "is not applied on this layout (already_digits_first)", , , &ErgoLInert)
		StrReplace(Log, "'digits' applies again on this layout", , , &Again)
		AssertEqual(1, ErgoptiInert, "turning inert on the built-in Ergopti is logged once, with why")
		AssertEqual(1, ErgoLInert, "the change of reason on Ergo-L is logged once")
		AssertEqual(1, Again, "applying again on AZERTY is logged once")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		_DigitRowProfiles := Saved[5]
		_NumberRowEffectiveLogged := Saved[6]
		DirDelete(Dir, true)
	}
}
Test("number row: a stored choice is inert where it cannot apply and applies again with no rewrite (number-row-inert-choice)",
	_KLT_WithEmulation.Bind(_NRP_StoredChoiceSurvivesLayouts))

; Runs Fn with an AZERTY-shaped layout standing for the foreground one:
; symbols unshifted and digits on Shift on all ten keys.
_NRP_WithAzertyShapedForeground(Fn) {
	global _NumberRowForegroundLayout, _DigitRowProfiles, KS_DIGIT_ROW_KEYS
	Saved := [_NumberRowForegroundLayout, _DigitRowProfiles]
	Hkl := 0x7E57040C
	Plain := Map(), Shifted := Map()
	for Index, Key in KS_DIGIT_ROW_KEYS {
		Plain[Key[2]] := Chr(0x26)
		Shifted[Key[2]] := Mod(Index, 10) . ""
	}
	_DigitRowProfiles := Map(Hkl, Map("shifted", true, "symbols", Plain, "shift_symbols", Shifted))
	_NumberRowForegroundLayout := Hkl
	try Fn.Call(Hkl)
	finally {
		_NumberRowForegroundLayout := Saved[1]
		_DigitRowProfiles := Saved[2]
	}
}

; Runs Fn with a US-QWERTY-shaped layout standing for the foreground one:
; digits unshifted and « ! @ # $ % ^ & * ( ) » on Shift.
_NRP_WithQwertyShapedForeground(Fn) {
	global _NumberRowForegroundLayout, _DigitRowProfiles, KS_DIGIT_ROW_KEYS
	Saved := [_NumberRowForegroundLayout, _DigitRowProfiles]
	Hkl := 0x7E570409
	Symbols := ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"]
	Plain := Map(), Shifted := Map()
	for Index, Key in KS_DIGIT_ROW_KEYS {
		Plain[Key[2]] := Mod(Index, 10) . ""
		Shifted[Key[2]] := Symbols[Index]
	}
	_DigitRowProfiles := Map(Hkl, Map("shifted", false, "symbols", Plain, "shift_symbols", Shifted))
	_NumberRowForegroundLayout := Hkl
	try Fn.Call(Hkl)
	finally {
		_NumberRowForegroundLayout := Saved[1]
		_DigitRowProfiles := Saved[2]
	}
}

; « Symbols first » needed a registry layout. It now reorders any row whose
; keys have their digit unshifted and a symbol on Shift, the OS layout's
; included, and stays inert elsewhere (number-row-native-symbols-first).
_NRP_NativeSymbolsFirst() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id, ConfigurationFile
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), ConfigurationFile]
	Dir := _KLT_TempDir()
	try {
		Native := Map("emulated_layout", "", "ergopti_base", false, "ergopti_alt_gr", false,
			"ergopti_variant", "none", "direct_access_digits", "symbols")
		_NRP_UseLayout(Native)
		KLE_Model := 0
		KLE_Id := ""
		ConfigurationFile := Dir . "symbols.toml"
		Image := _CMJFixtureCurrentSource('[layout]`ndirect_access_digits = "symbols"`n`n[category_enabled]`nlayout = true`n')
		FileAppend(Image, ConfigurationFile, "UTF-8-RAW")
		AssertEqual("current", ConfigMigrateBoot(ConfigurationFile)["status"])
		_NRP_WithQwertyShapedForeground(_NRP_AssertQwertySymbolsFirst)
		_NRP_WithAzertyShapedForeground((Hkl) => (
			AssertEqual("native", NumberRowEffectiveMode(), "AZERTY already types its symbols unshifted"),
			AssertEqual("", NumberRowSymbolsFirstText(0x02, false, Hkl, false), "an inert choice types nothing")))
		Source := _NRP_LayoutSource()
		Start := InStr(Source, '#HotIf NumberRowEffectiveMode() == "symbols" && !NumberRowRegistryOwnsRow()')
		Finish := InStr(Source, "`n#HotIf`n", , Start)
		AssertTrue(Start > 0 && Finish > Start, "the native symbols-first block must be found")
		Block := SubStr(Source, Start, Finish - Start)
		Loop 10 {
			Name := Format("SC{:03X}", A_Index + 1)
			AssertTrue(InStr(Block, "`n" . Name . ":: _NumberRowSymbolsFirstSend(") > 0, Name . " is reordered unshifted")
			AssertTrue(InStr(Block, "`n+" . Name . ":: _NumberRowSymbolsFirstSend(") > 0, Name . " is reordered with Shift")
		}
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		ConfigurationFile := Saved[5]
		DirDelete(Dir, true)
	}
}

_NRP_AssertQwertySymbolsFirst(Hkl) {
	AssertTrue(NumberRowSymbolsCapable(false), "no registry layout is needed")
	AssertEqual("symbols", NumberRowEffectiveMode(), "symbols first applies on the QWERTY-shaped row")
	AssertEqual("!", NumberRowSymbolsFirstText(0x02, false, Hkl, false), "the 1 key types its Shift symbol")
	AssertEqual("1", NumberRowSymbolsFirstText(0x02, true, Hkl, false), "and its digit with Shift")
	AssertEqual(")", NumberRowSymbolsFirstText(0x0B, false, Hkl, false), "the 0 key types its Shift symbol")
	AssertEqual("0", NumberRowSymbolsFirstText(0x0B, true, Hkl, false))
	AssertEqual("!", LayerEditor_CurrentEmulation()["character"].Call("SC002"), "the layer editor shows the swapped level")
	Rows := _LAY_NumberRowRows((*) => false, (*) => 0, (*) => true)
	Items := Rows[1]["items"]
	AssertTrue(Items[3]["checked"], "the stored symbols-first choice is ticked")
	AssertFalse(Items[3].Get("disabled", false), "and offered on the OS layout's row")
	AssertEqual(t("menu.layout.number_row_symbols"), Items[3]["label"], "it applies: no suffix")
	AssertEqual("platform_reason.number_row_already_digits_first", Items[2].Get("disabled_reason_key", ""))
}
Test("number row: symbols first reorders the OS layout's row without a registry layout (number-row-native-symbols-first)",
	_KLT_WithEmulation.Bind(_NRP_NativeSymbolsFirst))

; Counts the occurrences of Needle in Text.
_NRP_Count(Text, Needle) {
	StrReplace(Text, Needle, , , &Count)
	return Count
}

; The system layout switches AZERTY -> QWERTY -> AZERTY while the driver runs:
; the layout poll re-evaluates the stored choice on each switch, logs each
; change between applied and inert once, and refreshes the menu each time
; what it shows changes; the stored choice is never rewritten
; (number-row-inert-choice).
_NRP_SystemLayoutSwitchReevaluates() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id, _DigitRowProfiles, KS_DIGIT_ROW_KEYS
	global _NumberRowEffectiveLogged, _NumberRowMenuSignature, _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL
	global _LAYOUT_REMAP_HKL, _LayoutPollRetry
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), _DigitRowProfiles, _NumberRowEffectiveLogged,
		_NumberRowMenuSignature, IsSet(_LAST_KEYBOARD_HKL) ? _LAST_KEYBOARD_HKL : 0,
		IsSet(_PENDING_KEYBOARD_HKL) ? _PENDING_KEYBOARD_HKL : 0, IsSet(_LAYOUT_REMAP_HKL) ? _LAYOUT_REMAP_HKL : 0,
		_LayoutPollRetry]
	Azerty := 0x7E57040C, Qwerty := 0x7E570409
	Symbols := ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"]
	AzPlain := Map(), AzShift := Map(), UsPlain := Map(), UsShift := Map()
	for Index, Key in KS_DIGIT_ROW_KEYS {
		AzPlain[Key[2]] := Chr(0x26), AzShift[Key[2]] := Mod(Index, 10) . ""
		UsPlain[Key[2]] := Mod(Index, 10) . "", UsShift[Key[2]] := Symbols[Index]
	}
	Dir := _KLT_TempDir()
	Path := Dir . "number_row.toml"
	Image := '[layout]`ndirect_access_digits = "digits"`n'
	FileAppend(Image, Path, "UTF-8-RAW")
	try {
		_NRP_UseLayout(Map("emulated_layout", "", "ergopti_base", false, "ergopti_alt_gr", false,
			"ergopti_variant", "none", "direct_access_digits", "digits"))
		KLE_Model := 0
		KLE_Id := ""
		_DigitRowProfiles := Map(
			Azerty, Map("shifted", true, "symbols", AzPlain, "shift_symbols", AzShift),
			Qwerty, Map("shifted", false, "symbols", UsPlain, "shift_symbols", UsShift))
		Refreshes := []
		Port := Map("needs_reload", (Hkl) => false, "reload", (RefusedFn) => false, "pending", () => false,
			"veto_honored", () => true, "now", () => A_TickCount, "notify", () => 0,
			"number_row", (Hkl) => NumberRowLayoutObserved(Hkl, (*) => Refreshes.Push(Hkl)))
		_LAYOUT_REMAP_HKL := Azerty
		_LAST_KEYBOARD_HKL := Azerty
		_PENDING_KEYBOARD_HKL := 0
		_LayoutPollRetry := _LayoutPollNewRetry(0)
		_NumberRowEffectiveLogged := ""
		Effective := []
		Log := _NRP_CaptureLog(() => (
			_NumberRowMenuSignature := NumberRowMenuSignature(Azerty, false),
			Effective.Push(NumberRowEffectiveMode(Azerty, false)),
			LayoutPollTick(Qwerty, false, false, 0, 0, 5000, false, Port),
			Effective.Push(NumberRowEffectiveMode(Qwerty, false)),
			LayoutPollTick(Azerty, false, false, 0, 0, 5000, false, Port),
			Effective.Push(NumberRowEffectiveMode(Azerty, false))))
		AssertEqual("digits native digits", Effective[1] . " " . Effective[2] . " " . Effective[3],
			"digits first applies on AZERTY, is inert on QWERTY, applies again on AZERTY")
		AssertEqual(2, Refreshes.Length, "the menu is refreshed on both switches")
		AssertEqual(Qwerty, Refreshes[1])
		AssertEqual(Azerty, Refreshes[2])
		AssertEqual(1, _NRP_Count(Log, "'digits' applies on this layout"), "the first state is logged once")
		AssertEqual(1, _NRP_Count(Log, "is not applied on this layout (already_digits_first)"), "turning inert is logged once")
		AssertEqual(1, _NRP_Count(Log, "'digits' applies again on this layout"), "applying again is logged once")
		AssertEqual(Image, FSReadUtf8Exact(Path), "the stored choice is byte-identical")
		AssertEqual("digits", MasterGateDesiredFeatures(Features)["layout"]["direct_access_digits"])
		; A switch between two layouts the menu shows alike refreshes nothing.
		Same := 0x7E57140C
		_DigitRowProfiles[Same] := _DigitRowProfiles[Azerty]
		LayoutPollTick(Same, false, false, 0, 0, 5000, false, Port)
		AssertEqual(2, Refreshes.Length, "an equivalent layout does not rebuild the menu")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		_DigitRowProfiles := Saved[5]
		_NumberRowEffectiveLogged := Saved[6]
		_NumberRowMenuSignature := Saved[7]
		_LAST_KEYBOARD_HKL := Saved[8]
		_PENDING_KEYBOARD_HKL := Saved[9]
		_LAYOUT_REMAP_HKL := Saved[10]
		_LayoutPollRetry := Saved[11]
		DirDelete(Dir, true)
	}
}
Test("number row: a system layout switch re-evaluates the stored choice and refreshes the menu (number-row-inert-choice)",
	_KLT_WithEmulation.Bind(_NRP_SystemLayoutSwitchReevaluates))

; The emulated layout changes A -> B, then the emulation is turned off and on:
; each change re-evaluates the stored choice, with one log line per change of
; state or reason (number-row-inert-choice).
_NRP_EmulationChangesReevaluate() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id, _NumberRowEffectiveLogged
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), _NumberRowEffectiveLogged]
	Dir := _KLT_TempDir()
	Path := Dir . "number_row.toml"
	Image := '[layout]`ndirect_access_digits = "digits"`n'
	FileAppend(Image, Path, "UTF-8-RAW")
	Base := Map("emulated_layout", "", "ergopti_base", true, "ergopti_alt_gr", false,
		"ergopti_variant", "none", "direct_access_digits", "digits")
	Use(Emulated, On) {
		Layout := Base.Clone()
		Layout["emulated_layout"] := Emulated
		Layout["ergopti_base"] := On
		_NRP_UseLayout(Layout)
		if Emulated != "" && On
			_KLT_Load(Emulated)
		else {
			KLE_Model := 0
			KLE_Id := ""
		}
		return NumberRowEffectiveMode()
	}
	try {
		_NumberRowEffectiveLogged := ""
		Modes := []
		Log := ""
		_NRP_WithAzertyShapedForeground((Hkl) => (
			Log := _NRP_CaptureLog(() => (
				Modes.Push(Use("ergol", true)),
				Modes.Push(Use("ergopti", true)),
				Modes.Push(Use("", false)),
				Modes.Push(Use("ergopti", true))))))
		AssertEqual("native native digits native", Modes[1] . " " . Modes[2] . " " . Modes[3] . " " . Modes[4],
			"Ergo-L and Ergopti cannot be reordered; the AZERTY row under no emulation can")
		AssertEqual(1, _NRP_Count(Log, "(already_digits_first)"), "Ergo-L: logged once")
		AssertEqual(2, _NRP_Count(Log, "(digits_on_both)"), "Ergopti, before and after the emulation pause")
		AssertEqual(1, _NRP_Count(Log, "'digits' applies again on this layout"), "the emulation turned off")
		AssertEqual(Image, FSReadUtf8Exact(Path), "the stored choice is byte-identical")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		_NumberRowEffectiveLogged := Saved[5]
		DirDelete(Dir, true)
	}
}
Test("number row: an emulated layout change and the emulation on and off re-evaluate the stored choice (number-row-inert-choice)",
	_KLT_WithEmulation.Bind(_NRP_EmulationChangesReevaluate))

; Edge-key levels of a fake native profile: [plain, shift] for SC029, SC00C, SC00D.
_NRP_EdgeProfile(Levels) {
	Edges := Map()
	for Index, Sc in [0x29, 0x0C, 0x0D]
		Edges[Sc] := Map("plain", Levels[Index][1], "shift", Levels[Index][2])
	return Edges
}

; « Also reorder the three edge keys »: off by default, the edge keys keep the
; effective layout's levels on every layout; on, they swap the effective
; layout's own levels where an ordering applies and each can be swapped, and
; are greyed with why elsewhere; the stored choice is never rewritten
; (number-row-edge-keys).
_NRP_EdgeKeysFollowTheChoice() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id, ConfigurationFile, _NumberRowEdgesLogged
	global _NumberRowForegroundLayout, _DigitRowProfiles, KS_DIGIT_ROW_KEYS
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), ConfigurationFile, _NumberRowEdgesLogged,
		_NumberRowForegroundLayout, _DigitRowProfiles]
	Dir := _KLT_TempDir()
	Native := Map("emulated_layout", "", "ergopti_base", false, "ergopti_alt_gr", false,
		"ergopti_variant", "none", "direct_access_digits", "symbols")
	Azerty := 0x7E57040C, Qwerty := 0x7E570409
	Symbols := ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"]
	AzPlain := Map(), AzShift := Map(), UsPlain := Map(), UsShift := Map()
	for Index, Key in KS_DIGIT_ROW_KEYS {
		AzPlain[Key[2]] := Chr(0x26), AzShift[Key[2]] := Mod(Index, 10) . ""
		UsPlain[Key[2]] := Mod(Index, 10) . "", UsShift[Key[2]] := Symbols[Index]
	}
	Profiles := Map(
		Azerty, Map("shifted", true, "symbols", AzPlain, "shift_symbols", AzShift,
			"edges", _NRP_EdgeProfile([[Chr(0xB2), ""], [")", Chr(0xB0)], ["=", "+"]])),
		Qwerty, Map("shifted", false, "symbols", UsPlain, "shift_symbols", UsShift,
			"edges", _NRP_EdgeProfile([[Chr(0x60), "~"], ["-", "_"], ["=", "+"]])))
	try {
		_DigitRowProfiles := Profiles
		_NumberRowEdgesLogged := ""
		for Stored in [false, true] {
			Layout := Native.Clone()
			Layout["number_row_reorder_edges"] := Stored
			; Off: the edge keys keep the layout's own levels on AZERTY, QWERTY and Ergopti.
			for Vec in [[Azerty, "digits", false], [Qwerty, "symbols", false], [Qwerty, "symbols", true]] {
				Layout["direct_access_digits"] := Vec[2]
				Layout["ergopti_base"] := Vec[3]
				_NRP_UseLayout(Layout)
				KLE_Model := 0
				KLE_Id := ""
				_NumberRowForegroundLayout := Vec[1]
				Where := Format("0x{:X} {} builtin={} stored={}", Vec[1], Vec[2], Vec[3], Stored)
				State := NumberRowEdgesState()
				AssertEqual(Stored, State["stored"], Where . ": the stored choice")
				Applies := Stored && Vec[1] == Qwerty && !Vec[3]
				AssertEqual(Applies, NumberRowEdgesEffective(), Where . ": applies only on the QWERTY row")
				AssertEqual(Applies ? "~" : "", NumberRowEdgeText(0x29, false, Vec[1], false), Where . ": SC029 unshifted")
				AssertEqual(Applies ? Chr(0x60) : "", NumberRowEdgeText(0x29, true, Vec[1], false), Where . ": SC029 with Shift")
				AssertEqual(Applies ? "+" : "", NumberRowEdgeText(0x0D, false, Vec[1], false), Where . ": SC00D unshifted")
				Expected := Vec[3] ? "no_ordering" : Vec[1] == Azerty ? "edges_incomplete" : ""
				AssertEqual(Expected, State["reason"], Where . ": why the edge keys cannot join")
				if !Applies
					AssertEqual(Vec[3] ? "$" : "", NumberRowEmulatedBase(Format("SC{:03X}", 0x29)),
						Where . ": an unswapped edge key keeps the effective layout's own character")
			}
		}
		; The menu row: ticked and greyed with why, and « not applied », on AZERTY.
		ConfigurationFile := Dir . "edges.toml"
		Image := _CMJFixtureCurrentSource('[layout]`ndirect_access_digits = "digits"`nnumber_row_reorder_edges = true`n`n[category_enabled]`nlayout = true`n')
		FileAppend(Image, ConfigurationFile, "UTF-8-RAW")
		AssertEqual("current", ConfigMigrateBoot(ConfigurationFile)["status"])
		Layout := Native.Clone()
		Layout["direct_access_digits"] := "digits"
		Layout["number_row_reorder_edges"] := true
		_NRP_UseLayout(Layout)
		_NumberRowForegroundLayout := Azerty
		Rows := _LAY_NumberRowRows((*) => false, (*) => 0, (*) => true)
		AssertEqual(2, Rows.Length, "the ordering choice and the edge-key checkbox")
		Edge := Rows[2]
		AssertTrue(Edge["checked"], "the stored choice keeps its tick")
		AssertTrue(Edge.Get("disabled", false), "and is greyed where it cannot apply")
		AssertEqual("platform_reason.number_row_edges_incomplete", Edge.Get("disabled_reason_key", ""))
		AssertEqual(t("menu.layout.number_row_edges") . t("menu.layout.number_row_not_applied"), Edge["label"])
		AssertEqual(Image, FSReadUtf8Exact(ConfigurationFile), "the stored choice is byte-identical")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State := MasterGateState()
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		ConfigurationFile := Saved[5]
		_NumberRowEdgesLogged := Saved[6]
		_NumberRowForegroundLayout := Saved[7]
		_DigitRowProfiles := Saved[8]
		DirDelete(Dir, true)
	}
}
Test("number row: the edge keys keep their levels unless the choice reorders them where it can (number-row-edge-keys)",
	_KLT_WithEmulation.Bind(_NRP_EdgeKeysFollowTheChoice))

; While the layout is off its master gate empties the live boolean choices, but the
; ordering choice keeps its tick (a parameter keeps its value) and says it is not
; applied. The edge-keys checkbox read the emptied live value, so the same stored
; choice showed ticked in one row and unticked in the next
; (number-row-edges-row-intent, seen by the live check number-row-inert-choice).
_NRP_EdgesRowReadsTheIntentView() {
	global Features, CategoryEnabled, LayerEnabled, ConfigurationFile, _NumberRowEdgesLogged
	global _NumberRowForegroundLayout, _DigitRowProfiles, KS_DIGIT_ROW_KEYS
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone(), _NumberRowEdgesLogged,
		_NumberRowForegroundLayout, _DigitRowProfiles]
	Azerty := 0x7E57040C
	AzPlain := Map(), AzShift := Map()
	for Index, Key in KS_DIGIT_ROW_KEYS {
		AzPlain[Key[2]] := Chr(0x26)
		AzShift[Key[2]] := Mod(Index, 10) . ""
	}
	try {
		_DigitRowProfiles := Map(Azerty, Map("shifted", true, "symbols", AzPlain, "shift_symbols", AzShift,
			"edges", _NRP_EdgeProfile([[Chr(0xB2), ""], [")", Chr(0xB0)], ["=", "+"]])))
		_NumberRowEdgesLogged := ""
		Layout := Map("emulated_layout", "", "ergopti_base", false, "ergopti_alt_gr", false,
			"ergopti_variant", "none", "direct_access_digits", "digits", "number_row_reorder_edges", true)
		Features := Map("layout", Layout)
		CategoryEnabled := Map("Layout", false)
		LayerEnabled := false
		State := MasterGateState()
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		AssertFalse(Features["layout"]["number_row_reorder_edges"] == true,
			"the closed master gate empties the live boolean, which is the premise")
		_NumberRowForegroundLayout := Azerty
		Rows := _LAY_NumberRowRows((*) => false, (*) => 0, (*) => true)
		AssertEqual(2, Rows.Length, "the ordering choice and the edge-key checkbox")
		AssertTrue(Rows[1]["items"][2]["checked"], "the ordering choice keeps its tick while the layout is off")
		Edge := Rows[2]
		AssertTrue(Edge["checked"], "the stored edge-keys choice keeps its tick while the layout is off")
		AssertEqual(t("menu.layout.number_row_edges") . t("menu.layout.number_row_not_applied"), Edge["label"],
			"and says it is not applied")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State := MasterGateState()
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
		_NumberRowEdgesLogged := Saved[5]
		_NumberRowForegroundLayout := Saved[6]
		_DigitRowProfiles := Saved[7]
	}
}
Test("number row: the edge-keys checkbox shows the stored choice while the layout is off (number-row-edges-row-intent)",
	_KLT_WithEmulation.Bind(_NRP_EdgesRowReadsTheIntentView))

; No driver source keeps a table of edge-key characters any more: every edge
; key is read from the effective layout (number-row-edge-keys).
_NRP_NoHardcodedEdgeTable() {
	Source := _DriverSourceNoComments()
	StrReplace(Source, "NumberRowEdgeText(", , , &Readers)
	AssertTrue(Readers >= 5, "the edge-key readers must be found (" . Readers . ")")
	for Pattern in ['0x29, "$"', '0x0C, "%"', '0x0D, "="', "ErgoptiNumberRowEdgeMapping"]
		AssertEqual(0, InStr(Source, Pattern), "no hardcoded edge table: " . Pattern)
	AssertEqual(0, RegExMatch(Source, '"\$"\s*,[^\n]*"%"\s*,[^\n]*"="'), "no « $ % = » literal list")
}
Test("number row: no hardcoded edge-key table remains (number-row-edge-keys)", _NRP_NoHardcodedEdgeTable)

; A Kana AltGr (SC138 on VK_OEM_8) is no modifier to AutoHotkey, so a
; number-row hotkey without a guard matched under it and typed its reordered
; level where the layout's AltGr level belonged. Every number-row hotkey stands
; down there: the static blocks' criteria and the digits-first Shift swap
; (number-row-kana-altgr).
_NRP_KanaAltGrStandsDown() {
	global _ALTGR_KANA_FIXUP, _TapHoldModifierIsHeld, Features, CategoryEnabled, LayerEnabled
	State := MasterGateState()
	Restore := [Features, CategoryEnabled, LayerEnabled, State.Clone()]
	Source := _NRP_LayoutSource()
	Criteria := 0
	for Line in StrSplit(Source, "`n") {
		if !RegExMatch(Line, "^#HotIf .*(NumberRowEffectiveMode|NumberRowEdgesEffective)\(")
			continue
		Criteria += 1
		AssertTrue(InStr(Line, "!TapHoldKanaAltGrHeld()") > 0, "a number-row block stands down under a Kana AltGr: " . Line)
	}
	AssertEqual(3, Criteria, "digits first, symbols first and the edge keys")
	Saved := [IsSet(_ALTGR_KANA_FIXUP) ? _ALTGR_KANA_FIXUP : 0, IsSet(_TapHoldModifierIsHeld) ? _TapHoldModifierIsHeld : 0]
	try {
		_NRP_UseLayout(Map("emulated_layout", "", "ergopti_base", false, "ergopti_alt_gr", false,
			"ergopti_variant", "none", "direct_access_digits", "digits"))
		_NRP_WithAzertyShapedForeground(_NRP_KanaHeldSwap)
	} finally {
		_ALTGR_KANA_FIXUP := Saved[1]
		_TapHoldModifierIsHeld := Saved[2]
		Features := Restore[1]
		CategoryEnabled := Restore[2]
		LayerEnabled := Restore[3]
		State.Clear()
		for Key, Value in Restore[4]
			State[Key] := Value
	}
}
_NRP_KanaHeldSwap(Hkl) {
	global _ALTGR_KANA_FIXUP, _TapHoldModifierIsHeld
	AssertTrue(_DigitRowSwapIsLive(0x02, NumberRowForegroundLayout), "Shift+1 is swapped on the AZERTY-shaped row")
	_ALTGR_KANA_FIXUP := true
	_TapHoldModifierIsHeld := (*) => true
	AssertFalse(_DigitRowSwapIsLive(0x02, NumberRowForegroundLayout), "and left to the layout under a held Kana AltGr")
}
Test("number row: every number-row hotkey stands down under a Kana AltGr (number-row-kana-altgr)",
	_KLT_WithEmulation.Bind(_NRP_KanaAltGrStandsDown))

; The four row switches (layout.emulate_<row>): a row switched off is left to
; the OS layout by the registry emulation (its criteria), by the built-in one
; (pass-through variants created before its layers) and by the AltGr layer,
; and the number-row ordering reads the OS layout's row then
; (layout-row-scopes).
_NRP_RowScopes() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id
	global LAYOUT_ROW_PASSTHROUGH_PREFIXES, ScriptInformation
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone()]
	try {
		Total := 0
		for Row, Keys in LayoutEmulationRows()
			Total += Keys.Length
		AssertEqual(48, Total, "13 number-row keys, 12 top-row, 12 home-row and 11 bottom-row keys")
		AssertEqual("top_row", LayoutRowOf("sc010"), "a scan code name is read case-insensitively")
		AssertEqual("", LayoutRowOf("SC039"), "the space bar belongs to no row")
		; The registry emulation: Ergo-L with the top row switched off.
		Layout := Map("emulated_layout", "ergol", "ergopti_base", true, "ergopti_alt_gr", true,
			"ergopti_variant", "none", "direct_access_digits", "native", "emulate_number_row", true,
			"emulate_top_row", false, "emulate_home_row", true, "emulate_bottom_row", true)
		_NRP_UseLayout(Layout)
		_KLT_Load("ergol")
		AssertFalse(LayoutRowIsEmulated("SC010"), "the top row is switched off")
		AssertTrue(LayoutRowIsEmulated("SC01E"), "the home row stays emulated")
		AssertTrue(LayoutRowIsEmulated("SC039"), "a key outside the rows stays emulated")
		AssertFalse(_KLE_BaseCriterion("SC010", false), "the registry emulation leaves a top-row key to the OS")
		AssertFalse(_KLE_BaseCriterion("SC010", true), "and its Shift level")
		AssertTrue(_KLE_BaseCriterion("SC01E", false), "while it keeps a home-row key")
		AssertFalse(_KLE_ShortcutCriterion("^SC010"), "the shortcut chords of the top row are the OS layout's")
		AssertTrue(_KLE_ShortcutCriterion("^SC01E"))
		AssertFalse(LayoutRowIsEmulatedHotkey("SC138 & SC010"), "the AltGr level of a top-row key is the OS layout's")
		AssertTrue(LayoutRowIsEmulatedHotkey("SC138 & SC01E"))
		; The built-in emulation: the pass-through variants, created first.
		Layout["emulated_layout"] := ""
		Layout["ergopti_base"] := true
		_NRP_UseLayout(Layout)
		KLE_Model := 0
		KLE_Id := ""
		Names := Map()
		Criteria := Map()
		Current := {Criterion: 0}
		Count := RegisterLayoutRowPassthrough((Name, Callback, Options) => (Names[Name] := Options, Criteria[Name] := Current.Criterion),
			(Args*) => Current.Criterion := Args.Length ? Args[1] : 0)
		AssertEqual(Total * LAYOUT_ROW_PASSTHROUGH_PREFIXES.Length, Count, "every level of every row key")
		AssertEqual("I3", Names["!SC010"], "the Alt level keeps the Alt input level")
		AssertTrue(Criteria["*SC010"].Call(), "a top-row key passes through to the OS layout")
		AssertTrue(Criteria["+SC010"].Call(), "on its Shift level too")
		AssertFalse(Criteria["*SC01E"].Call(), "a home-row key stays with the emulation")
		Magic := ScriptInformation["MagicKeySourceScan"]
		if LayoutRowOf(Magic) == "top_row" && Features["hotstrings"]["magic_key"]["replace"]["enabled"] {
			AssertFalse(Criteria[StrUpper(Magic)].Call(StrUpper(Magic)), "the magic key keeps its plain press")
			AssertEqual(ScriptInformation["MagicKeySourceChosen"], Criteria["*" . StrUpper(Magic)].Call("*" . StrUpper(Magic)),
				"only a chosen source's modified presses follow the native row")
		}
		Layout["ergopti_base"] := false
		_NRP_UseLayout(Layout)
		AssertFalse(Criteria["*SC010"].Call(), "without the built-in emulation nothing passes through")
		Source := _NRP_LayoutSource()
		Passthrough := InStr(Source, "RegisterLayoutRowPassthrough()")
		Remaps := InStr(Source, "for sc_int, entry in ErgoptiBaseMapping()")
		Shift := InStr(Source, "`nRegisterShiftLayer()")
		AssertTrue(Passthrough > 0 && Passthrough < Remaps && Remaps < Shift,
			"the pass-through variants are created before the base remaps and the built-in layers")
		AltGr := _StripFullLineComments(_DriverFuncBody("RegisterAltGrLayer"))
		StrReplace(AltGr, "LayoutRowIsEmulatedHotkey(Name)", , , &AltGrGates)
		AssertEqual(4, AltGrGates, "the three AltGr tables and Ctrl+Alt cohort stand down on a row switched off")
		; The ordering reads the OS layout's row when the number row is off.
		Layout["ergopti_base"] := true
		Layout["direct_access_digits"] := "digits"
		_NRP_UseLayout(Layout)
		_NRP_WithAzertyShapedForeground((Hkl) => (
			AssertEqual("native", NumberRowEffectiveMode(), "the built-in Ergopti row cannot be reordered"),
			Features["layout"]["emulate_number_row"] := false,
			AssertEqual("digits", NumberRowEffectiveMode(), "its number row switched off, the AZERTY row decides"),
			AssertEqual("", NumberRowEmulatedBase("SC029"), "and the edge keys are the OS layout's"),
			AssertEqual("native", _DigitRowSwapResolution(0x02, Hkl, false)["source"])))
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
	}
}
Test("layout rows: a row switched off is left to the OS layout by every emulation (layout-row-scopes)",
	_KLT_WithEmulation.Bind(_NRP_RowScopes))

; « Digits first » used to type Ergopti's « $ % = » on the edge keys on any
; layout. It reorders the ten digit keys only: the edges keep what the
; effective layout types there (number-row-effective-edges).
_NRP_DigitsFirstLeavesTheEdges() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone()]
	try {
		_NRP_UseLayout(Map("emulated_layout", "", "ergopti_base", false, "ergopti_alt_gr", false,
			"ergopti_variant", "none", "direct_access_digits", "digits"))
		KLE_Model := 0
		KLE_Id := ""
		_NRP_WithAzertyShapedForeground((Hkl) => (
			AssertEqual("digits", NumberRowEffectiveMode(), "digits first applies on the AZERTY-shaped row"),
			AssertTrue(_KLE_DigitsOwnKey("SC002", false), "the digit keys are reordered"),
			AssertFalse(_KLE_DigitsOwnKey("SC029", false), "the key left of 1 is not"),
			AssertFalse(_KLE_DigitsOwnKey("SC00C", false), "the first key right of 0 is not"),
			AssertFalse(_KLE_DigitsOwnKey("SC00D", false), "the second key right of 0 is not"),
			AssertEqual("", NumberRowEmulatedBase("SC029"), "no emulation: the OS layout types the edges")))
		Source := _NRP_LayoutSource()
		Start := InStr(Source, '#HotIf NumberRowEffectiveMode() == "digits"')
		Finish := InStr(Source, "`n#HotIf`n", , Start)
		AssertTrue(Start > 0 && Finish > Start, "the digits-first block must be found")
		Block := SubStr(Source, Start, Finish - Start)
		for Edge in ["SC029", "SC00C", "SC00D"]
			AssertEqual(0, InStr(Block, "`n" . Edge . "::"), Edge . " has no digits-first hotkey")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
	}
}
Test("number row: digits first reorders the ten digit keys and leaves the edges to the layout (number-row-effective-edges)",
	_KLT_WithEmulation.Bind(_NRP_DigitsFirstLeavesTheEdges))

; The built-in Ergopti row has its digits on both levels: neither ordering can
; make base differ from Shift, and leaving it as is types Ergopti's digits.
_NRP_BuiltinErgoptiOffersNoOrdering() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id, ERGOPTI_SPEC, _SHIFT_DIGIT_SCS
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone()]
	try {
		_NRP_UseLayout(Map("emulated_layout", "", "ergopti_base", true, "ergopti_alt_gr", false,
			"ergopti_variant", "ergopti_plus", "direct_access_digits", "native"))
		KLE_Model := 0
		KLE_Id := ""
		for Caps in [false, true] {
			Availability := NumberRowAvailability(GetForegroundKeyboardLayout(), Caps)
			AssertEqual("digits_on_both", Availability["digits"], "digits first has nothing to swap")
			AssertEqual("digits_on_both", Availability["symbols"], "symbols first has nothing to swap")
		}
		for SC in _SHIFT_DIGIT_SCS
			AssertEqual(Mod(Integer("0x" . SubStr(SC, 3)) - 1, 10) . "", ERGOPTI_SPEC["number_row_base"][SC]["text"],
				SC . ": the built-in row types Ergopti's digit unshifted")
		for SC, Text in Map("SC029", "$", "SC00C", "%", "SC00D", "=")
			AssertEqual(Text, ERGOPTI_SPEC["number_row_base"][SC]["text"], SC . ": the built-in row types the .keylayout's edge")
		Body := _StripFullLineComments(_DriverFuncBody("RegisterBuiltinNumberRow"))
		AssertTrue(Body != "", "the built-in number row registration must exist")
		AssertTrue(InStr(Body, 'ERGOPTI_SPEC["number_row_base"]') > 0, "it types the .keylayout's base level")
		Layout := _NRP_LayoutSource()
		Direct := InStr(Layout, '#HotIf NumberRowEffectiveMode() == "digits"')
		Own := InStr(Layout, "`nRegisterBuiltinNumberRow()")
		AssertTrue(Direct > 0 && Own > Direct, "the direct-access hotkeys are created first, so they win where they apply")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
	}
}
Test("number row: the built-in Ergopti offers no ordering and types its own row (number-row-availability)",
	_KLT_WithEmulation.Bind(_NRP_BuiltinErgoptiOffersNoOrdering))

/** Uses the real registry callback and existing Send capture, including repeats. */
_NRP_RegisteredSymbols() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered, _SendHook, _Stub_RecordedSends, _SharedDir
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone(), _SendHook]
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_levels.json"))
	try {
		Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "symbols"))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		_KLT_Load("ergol")
		AssertTrue(NumberRowSymbolsCapable(false))
		AssertTrue(NumberRowSymbolsCapable(true), "hardware CapsLock has an independently valid source pair")
		KLE_Registered := false
		Capture := { Criterion: 0, Rows: Map() }
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, Callback, Options) => Capture.Rows[Name] := { Criterion: Capture.Criterion, Callback: Callback },
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0)
		_SendHook := _HOOK_RecordSend
		CapsBefore := GetKeyState("CapsLock", "T")
		for Index, Sc in Corpus["scancodes"] {
			Legend := LayerEditor_CurrentEmulation()["character"].Call(Sc)
			AssertEqual(Corpus["emulated"]["shift"][Index], Legend,
				"the actual layer-editor legend follows the same unshifted symbols source")
			for Shift in [false, true] {
				Row := Capture.Rows[Shift ? "+" . Sc : Sc]
				AssertTrue(Row.Criterion.Call(), "the original KLE owner admits its actual key")
				Loop 2 {
					ResetHotstringRecorders()
					Row.Callback.Call()
					AssertEqual(1, _Stub_RecordedSends.Length, "each press and repeat emits once")
					AssertEqual(Corpus["emulated"][Shift ? "plain" : "shift"][Index], _Stub_RecordedSends[1].args[1],
						"symbols-first retains exact source levels, with Shift reversing them")
				}
			}
		}
		AssertEqual(CapsBefore, GetKeyState("CapsLock", "T"), "policy never changes hardware CapsLock")
		State["features"]["layout"]["emulated_layout"] := "foreign-source"
		AssertFalse(NumberRowSymbolsCapable(CapsBefore), "a loaded old source is not a current capability receipt")
		AssertEqual("native", NumberRowEffectiveMode(), "unsupported desired symbols cannot claim effective symbols")
		AssertEqual("symbols", State["features"]["layout"]["direct_access_digits"], "unsupported intent remains explicit, never default-flushed")
		State["features"]["layout"]["emulated_layout"] := "ergol"
		CategoryEnabled["Layout"] := false
		AssertEqual("native", NumberRowEffectiveMode(), "master-off retains native input despite the stored enum")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_SendHook := Saved[6]
	}
}
Test("number row: symbols use actual registered KLE levels and repeat owner", () => _KLT_WithEmulation(_NRP_RegisteredSymbols))


/** Records an exact native writer result; assertions remain outside callbacks. */
_NRP_MenuWriter(Mode, Seen, Path, Updates, Content, Presence) {
	Seen["calls"] += 1
	Seen["content"] := Content
	Seen["presence"] := Presence
	if Mode == "source-race" {
		Foreign := StrReplace(Content, '"kept"', '"foreign"')
		Seen["changed"] := StrCompare(Content, Foreign, true) != 0
		FileDelete(Path)
		FileAppend(Foreign, Path, "UTF-8-RAW")
		return TOML_ConfigBatchWrite(Path, Updates, [], 0, Content, Presence)
	}
	if Mode == "throw"
		throw Error("owned number-row writer refusal")
	if Mode == "nil"
		return
	if Mode == "false"
		return false
	if Mode == "two"
		return 2
	if Mode == "string"
		return "1"
	if Mode == "float"
		return 1.0
	return TOML_ConfigBatchWrite(Path, Updates, [], 0, Content, Presence)
}

_NRP_MenuFixture(Path, Mode := "native") {
	global Features, CategoryEnabled, LayerEnabled
	Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
		"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", Mode))
	CategoryEnabled := Map("Layout", true)
	LayerEnabled := false
	State := MasterGateState()
	State["initialized"] := false
	MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
	_KLT_Load("ergol")
	Image := '[layout]`nemulated_layout = "ergol"`nergopti_base = true`n'
		. 'future = "kept" # exact neighbour`n'
	if Mode != "native"
		Image .= 'direct_access_digits = "' . Mode . '"`n'
	Image .= '`n[category_enabled]`nlayout = true`n'
	Image := _CMJFixtureCurrentSource(Image)
	if FileExist(Path)
		FileDelete(Path)
	FileAppend(Image, Path, "UTF-8-RAW")
	; Each independently authored subject reaches the real owner before its callback.
	Boot := ConfigMigrateBoot(Path)
	AssertEqual("current", Boot["status"])
	AssertEqual(0, Boot["read_only"])
	AssertTrue(FSUtf8ExactMatches(Path, Image))
	AssertTrue(ConfigSchemaCanPrepareWrite(Path), "the number-row writer starts from genuine source admission")
	return Image
}

_NRP_MenuNativeOwners() {
	global Features, CategoryEnabled, LayerEnabled, ConfigurationFile, _TrayRootLifecycleEpoch, _LayoutPollRetry
	Saved := [Features, CategoryEnabled, LayerEnabled, ConfigurationFile,
		MasterGateState().Clone(), _TrayRootLifecycleEpoch, A_IsSuspended, MagicEditorState()["configuration_generation"], _LayoutPollRetry]
	Dir := _KLT_TempDir()
	ConfigurationFile := Dir . "config.toml"
	try {
		if A_IsSuspended
			Suspend(false)
		for Mode in ["ack", "false", "nil", "two", "string", "float", "throw", "source-race"] {
			; Independent native subjects keep their exact original startup owners.
			ConfigurationFile := Dir . "ack-" . Mode . ".toml"
			Before := _NRP_MenuFixture(ConfigurationFile)
			Seen := Map("calls", 0, "refresh", 0, "changed", false)
			Rows := _LAY_NumberRowRows(_NRP_MenuWriter.Bind(Mode, Seen), (*) => Seen["refresh"] += 1, (*) => true)
			AssertEqual(2, Rows.Length, "the actual choice renderer must produce its canonical head and the edge-key checkbox")
			AssertEqual(3, Rows[1]["items"].Length)
			AssertTrue(Rows[1]["items"][1]["checked"])
			; Ergo-L already types its digits unshifted (number-row-availability).
			AssertTrue(Rows[1]["items"][2].Get("disabled", false), "digits first cannot reorder Ergo-L")
			AssertEqual("platform_reason.number_row_already_digits_first", Rows[1]["items"][2].Get("disabled_reason_key", ""))
			AssertEqual(t("menu.layout.number_row_digits"), Rows[1]["items"][2]["label"], "an unselected greyed choice keeps its label")
			AssertFalse(Rows[1]["items"][3].Get("disabled", false), "only a real supported KLE source admits symbols")
			AssertFalse(Rows[1]["items"][1]["action"].Call(), "same-native status acquires no default write")
			AssertEqual(0, Seen["calls"])
			Result := Rows[1]["items"][3]["action"].Call()
			AssertEqual(Mode == "ack", Result, "only strict native publication may acknowledge the selection")
			AssertEqual(1, Seen["calls"])
			AssertEqual(Before, Seen["content"], "the terminal seam receives the admitted raw image")
			AssertEqual(1, Seen["presence"])
			AssertEqual(Mode == "ack" ? 1 : 0, Seen["refresh"])
			AssertEqual(Mode == "ack" ? "symbols" : "native", MasterGateDesiredFeatures(Features)["layout"]["direct_access_digits"])
			if Mode == "source-race" {
				AssertTrue(Seen["changed"], "foreign replacement must genuinely change bytes outside the caught writer")
				AssertEqual(StrReplace(Before, '"kept"', '"foreign"'), FSReadUtf8Exact(ConfigurationFile))
			} else if Mode != "ack"
				AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile))
			else {
				AssertContains(FSReadUtf8Exact(ConfigurationFile), 'direct_access_digits = "symbols"')
				AssertContains(FSReadUtf8Exact(ConfigurationFile), 'future = "kept" # exact neighbour')
			}
		}
		for Condition in ["source", "external-mode", "model", "pause", "master", "configuration", "lifecycle", "native-source"] {
			ConfigurationFile := Dir . "stale-" . Condition . ".toml"
			Before := _NRP_MenuFixture(ConfigurationFile)
			Seen := Map("calls", 0, "refresh", 0)
			Rows := _LAY_NumberRowRows(_NRP_MenuWriter.Bind("ack", Seen), (*) => Seen["refresh"] += 1, (*) => true)
			Callback := Rows[1]["items"][3]["action"]
			switch Condition {
				case "source": FileAppend("# foreign edit`n", ConfigurationFile, "UTF-8-RAW")
				case "external-mode":
					Image := StrReplace(Before, '[layout]', '[layout]`ndirect_access_digits = "digits"')
					FileDelete(ConfigurationFile)
					FileAppend(Image, ConfigurationFile, "UTF-8-RAW")
				case "model": _KLT_Load("ergol")
				case "pause": Suspend(true)
				case "master": CategoryEnabled["Layout"] := false
				case "configuration":
					MagicEditorConfigurationChanged()
				case "lifecycle": _TrayRootLifecycleEpoch += 1
				case "native-source":
					Hkl := GetForegroundKeyboardLayout()
					Other := 0
					for Native in _LDRP_RealLayouts() {
						if Native != Hkl {
							Other := Native
							break
						}
					}
					AssertTrue(Other != 0, "a second genuine HKL must qualify the observed source cycle")
					_LayoutPollObserve(Other)
					_LayoutPollObserve(Hkl)

			}
			Foreign := FSReadUtf8Exact(ConfigurationFile)
			AssertFalse(Callback.Call(), Condition . " must retire the captured source")
			AssertEqual(0, Seen["calls"])
			AssertEqual(0, Seen["refresh"])
			AssertEqual(Foreign, FSReadUtf8Exact(ConfigurationFile))
			if A_IsSuspended
				Suspend(false)
		}
	} finally {
		if A_IsSuspended != Saved[7]
			Suspend(Saved[7])
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		ConfigurationFile := Saved[4]
		State := MasterGateState()
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_TrayRootLifecycleEpoch := Saved[6]
		MagicEditorState()["configuration_generation"] := Saved[8]
		_LayoutPollRetry := Saved[9]
		DirDelete(Dir, true)
	}
}
Test("number row: real menu callbacks retain source and strict native ACK before publication", _KLT_WithEmulation.Bind(_NRP_MenuNativeOwners))

; A stored choice that does not apply on the effective layout keeps its tick,
; is greyed with why, and says it is not applied (number-row-inert-choice).
_NRP_MenuShowsInertChoice() {
	global Features, CategoryEnabled, LayerEnabled, ConfigurationFile
	Saved := [Features, CategoryEnabled, LayerEnabled, ConfigurationFile, MasterGateState().Clone()]
	Dir := _KLT_TempDir()
	try {
		ConfigurationFile := Dir . "inert.toml"
		_NRP_MenuFixture(ConfigurationFile, "digits")
		Rows := _LAY_NumberRowRows((*) => false, (*) => 0, (*) => true)
		AssertEqual(2, Rows.Length, "the ordering choice and the edge-key checkbox")
		Items := Rows[1]["items"]
		AssertTrue(Items[2]["checked"], "the stored choice keeps its tick")
		AssertTrue(Items[2].Get("disabled", false), "and is greyed where it does nothing")
		AssertEqual("platform_reason.number_row_already_digits_first", Items[2].Get("disabled_reason_key", ""))
		AssertEqual(t("menu.layout.number_row_digits") . t("menu.layout.number_row_not_applied"), Items[2]["label"],
			"its label says it is not applied")
		AssertFalse(Items[1].Get("disabled", false), "leaving the layout as it is stays valid")
		AssertFalse(Items[3].Get("disabled", false), "symbols first can reorder Ergo-L")
		AssertEqual(t("menu.layout.number_row_symbols"), Items[3]["label"])
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		ConfigurationFile := Saved[4]
		State := MasterGateState()
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		DirDelete(Dir, true)
	}
}
Test("number row: the menu greys an inert stored choice and says it is not applied (number-row-inert-choice)",
	_KLT_WithEmulation.Bind(_NRP_MenuShowsInertChoice))


/** A real dead action is routed through the unchanged KLE composition owner. */
_NRP_RegisteredSymbolsDeadAction() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered, _SendHook, KLE_State, _Stub_RecordedSends
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone(), _SendHook]
	try {
		Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "symbols"))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		Text := _KLT_LayoutText("ergol")
		Text := _KLT_Tamper(Text, '<key code="18"  action="ae01_' . Chr(0x20AC) . '" />',
			'<key code="18"  action="number_row_dead" />')
		Text := _KLT_Tamper(Text, '</actions>',
			'<action id="number_row_dead"><when state="none" next="number_row_pending"/></action></actions>')
		Text := _KLT_Tamper(Text, '</terminators>',
			'<when state="number_row_pending" output="^"/></terminators>')
		KeylayoutEmulation_Load("ergol", Text, "ansi", LayoutRegistry_Keycodes())
		AssertTrue(NumberRowSymbolsCapable(false), "all ten real levels include the typed dead source")
		AssertEqual("dead", KeylayoutEmulation_NumberRowLevels(0x02, false)["shift"]["Kind"])
		AssertEqual("number_row_pending", KeylayoutEmulation_NumberRowLevels(0x02, false)["shift"]["State"])
		KLE_Registered := false
		Capture := { Criterion: 0, Rows: Map() }
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, Callback, Options) => Capture.Rows[Name] := { Criterion: Capture.Criterion, Callback: Callback },
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0)
		_SendHook := _HOOK_RecordSend
		Row := Capture.Rows["SC002"]
		AssertTrue(Row.Criterion.Call())
		ResetHotstringRecorders()
		; CapsLock is read by the genuine callback. Both source Caps maps share
		; the digits level; only its Shift source was changed by the exact XML.
		Row.Callback.Call()
		AssertEqual("number_row_pending", KLE_State, "symbols-first must arm the real action state")
		AssertEqual(0, _Stub_RecordedSends.Length, "arming a dead source emits no invented Unicode glyph")
		AssertEqual("^q", KeylayoutEmulation_Press("SC010", false, false, false), "the unchanged source machine retires its own pending state")
		AssertEqual("none", KLE_State)
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_SendHook := Saved[6]
	}
}
Test("number row: symbols retain real dead-action composition without a new emitter", _KLT_WithEmulation.Bind(_NRP_RegisteredSymbolsDeadAction))


; These calls exercise the real criterion before its live sources are published.
_NRP_AssertBootMode(Expected, Caption, Hkl := unset) {
	Observed := ""
	Failure := ""
	try Observed := IsSet(Hkl) ? NumberRowEffectiveMode(Hkl, false) : NumberRowEffectiveMode()
	catch as Err
		Failure := Err.Message
	AssertEqual("", Failure, Caption . " must not escape an early-boot unset read")
	AssertEqual(Expected, Observed, Caption . " must retain truthful native admission")
}

_NRP_UnpublishedBootSources() {
	global Features, CategoryEnabled, KLE_Id, KLE_Model
	HadFeatures := IsSet(Features)
	HadCategory := IsSet(CategoryEnabled)
	HadId := IsSet(KLE_Id)
	HadModel := IsSet(KLE_Model)
	if HadFeatures
		SavedFeatures := Features
	if HadCategory
		SavedCategory := CategoryEnabled
	if HadId
		SavedId := KLE_Id
	if HadModel
		SavedModel := KLE_Model
	try {
		Features := Map("layout", Map("direct_access_digits", "digits"))
		CategoryEnabled := unset
		_NRP_AssertBootMode("native", "unpublished category map")
		for Source in ["unpublished", 0, Map(), Map("Layout", false), Map("Layout", "true"),
			Map("Layout", "1"), Map("Layout", 1.0), Map("Layout", 2)] {
			CategoryEnabled := Source
			_NRP_AssertBootMode("native", "unadmitted category source")
		}
		CategoryEnabled := Map("Layout", true)
		; Digits first applies where the row has symbols unshifted: AZERTY.
		Azerty := _LDRP_Layout("0000040C")
		_NRP_AssertBootMode("digits", "admitted Layout switch", Azerty ? Azerty : 0x040C040C)
		Features["layout"]["direct_access_digits"] := "native"
		_NRP_AssertBootMode("native", "explicit native intent")
		Features["layout"]["direct_access_digits"] := "symbols"
		KLE_Id := "boot-source"
		KLE_Model := unset
		Features["layout"]["emulated_layout"] := KLE_Id
		Features["layout"]["ergopti_base"] := true
		_NRP_AssertBootMode("native", "unpublished symbols model")
		KLE_Id := unset
		_NRP_AssertBootMode("native", "unpublished symbols identity")
		Features := unset
		_NRP_AssertBootMode("native", "unpublished feature map")
		for Source in ["unpublished", Map(), Map("layout", "invalid")] {
			Features := Source
			_NRP_AssertBootMode("native", "unadmitted feature source")
		}
	} finally {
		if HadFeatures
			Features := SavedFeatures
		else
			Features := unset
		if HadCategory
			CategoryEnabled := SavedCategory
		else
			CategoryEnabled := unset
		if HadId
			KLE_Id := SavedId
		else
			KLE_Id := unset
		if HadModel
			KLE_Model := SavedModel
		else
			KLE_Model := unset
	}
}
Test("number row: unpublished and malformed boot sources retain native input", _NRP_UnpublishedBootSources)


_NRP_AdmittedSymbolsBootMode() {
	global Features, CategoryEnabled, LayerEnabled
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, State.Clone()]
	try {
		Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "symbols"))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		_KLT_Load("ergol")
		_NRP_AssertBootMode("symbols", "admitted real symbols source")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		State.Clear()
		for Key, Value in Saved[4]
			State[Key] := Value
	}
}
Test("number row: contained admission retains a genuine symbols capability", _KLT_WithEmulation.Bind(_NRP_AdmittedSymbolsBootMode))
