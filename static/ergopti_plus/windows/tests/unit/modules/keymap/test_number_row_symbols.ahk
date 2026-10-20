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

; The built-in Ergopti row has its digits on both levels: neither ordering can
; make base differ from Shift, and leaving it as is types Ergopti's digits.
_NRP_BuiltinErgoptiOffersNoOrdering() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Model, KLE_Id, ERGOPTI_SPEC, _SHIFT_DIGIT_SCS, _DriverDir
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
		for Code, Text in ErgoptiNumberRowEdgeMapping()
			AssertEqual(Text, ERGOPTI_SPEC["number_row_base"][Format("SC{:03X}", Code)]["text"],
				"the tap-key labels' edge table is the built-in row's base level")
		Body := _StripFullLineComments(_DriverFuncBody("RegisterBuiltinNumberRow"))
		AssertTrue(Body != "", "the built-in number row registration must exist")
		AssertTrue(InStr(Body, 'ERGOPTI_SPEC["number_row_base"]') > 0, "it types the .keylayout's base level")
		Layout := _StripFullLineComments(FileRead(_DriverDir . "\modules\keymap\layout.ahk", "UTF-8"))
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
			AssertEqual(1, Rows.Length, "the actual choice renderer must produce its canonical head")
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
		AssertEqual(1, Rows.Length)
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
