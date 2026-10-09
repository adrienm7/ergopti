; modules/keymap/layout/layout_ergopti.ahk

; ==============================================================================
; MODULE: Ergopti Layout Tables
; DESCRIPTION:
; Builds every table of the Windows Ergopti emulation from the Ergopti
; .keylayout files of the layout registry (static/layouts/registry), the same
; files macOS installs and Linux converts: the base layer registered by
; modules/keymap/layout.ahk, the Shift and CapsLock layers
; (layout_shift_caps.ahk), the AltGr layers (layout_altgr.ahk) and the
; dead-key tables (DeadKey, and the circumflex hotstrings). No Windows copy of
; the layout exists; the keylogger heatmap labels its keys from the same data.
;
; FEATURES & RATIONALE:
; 1. Read once at boot (ErgoptiLayout_Init), never on the typing path, from
;    the registry folder shipped with the driver, verified against its
;    index.json first. ergopti.keylayout gives every layer and dead key;
;    ergopti_plus.keylayout gives the AltGr keys Ergopti+ changes.
; 2. The .keylayout decides what each key types. The Ergopti overlays below add
;    what a layout file cannot express: the French-typography keys commit the
;    pending hotstring first, symbols wrap the selection, a word typed by one
;    key (Ergopti+ « où ») is followed by the space-around-symbols setting, and
;    Ctrl/Alt/Win on an accented key sends its configurable shortcut letter.
;    They only apply to the Ergopti layout; a registry layout emulated instead
;    (keylayout_emulation.ahk) supersedes them through the master gates.
; 3. Deviations: where the emulation typed something else than the .keylayout
;    before it read the file, the deviation tables keep the emulation's answer,
;    so reading the file changed nothing (the golden file
;    tests/fixtures/ergopti_emulation_golden.json pins every key and dead key).
;    A test fails once an entry matches the file, so they shrink as the
;    .keylayout catches up.
; 4. Data first: ErgoptiLayout_BuildSpec is pure and returns descriptors the
;    golden test compares key by key; ErgoptiLayout_Action turns a descriptor
;    into the callable a layer registers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

global ERGOPTI_LAYOUT_ID := "ergopti"
global ERGOPTI_PLUS_LAYOUT_ID := "ergopti_plus"

; Dead-key states of the Ergopti .keylayout -> name of the published table
; (DeadkeyMapping<Name>) the layers, DeadKey and the hotstrings use.
global ERGOPTI_DEAD_KEY_NAMES := Map(
	"s1_circumflex", "Circumflex",
	"s2_currency", "Currency",
	"s3_diaeresis", "Diaresis",
	"s4_greek", "Greek",
	"s5_superscript", "Superscript",
	"s6_subscript", "Subscript",
	"s7_RR", "R"
)

; Number row. Its base level belongs to « Chiffres en accès direct »
; (direct_access_digits in layout.ahk), which also serves other layouts, and
; its AltGr level registers as a separate table before the other rows.
global ERGOPTI_NUMBER_ROW := Map(
	"SC029", true, "SC002", true, "SC003", true, "SC004", true, "SC005", true,
	"SC006", true, "SC007", true, "SC008", true, "SC009", true, "SC00A", true,
	"SC00B", true, "SC00C", true, "SC00D", true
)

; Keys without a CapsLock entry: CapsLock leaves the space bar as it is, so it
; stays on its base remap.
global ERGOPTI_CAPS_LAYER_EXCLUDED := Map("SC039", true)

; Overlay: a Shift output starting with one of these spaces is French
; typography (« : », « ! »...); the pending hotstring is committed first.
global ERGOPTI_NO_BREAK_SPACES := [Chr(0xA0), Chr(0x202F)]

; Overlay: outputs that wrap the selection (WrapTextIfSelected) on each level,
; spelled like the shared wrap catalogue
; (_shared/modules/wrap_symbols/wrap_symbols.json), which gives the pair of an
; asymmetric symbol and whose spelling the wrap-symbol settings are keyed by.
; A symbol the catalogue lacks wraps with itself on both sides.
global ERGOPTI_WRAP_CHARACTERS := Map(
	"shift", ["-"],
	"altgr", ["_", '``', "@", "« ", " »", "~", "#", "*", "%", "<", ">", "{", "}", ":", "|",
		"(", ")", "[", "]", "!", "^", "/", "\", '"', Chr(0x3B), "&", "$", "=", "+", "?"]
)

; Deviations from the .keylayout on individual keys, per table (see the
; module header, point 3). Descriptors use ErgoptiLayout_BuildSpec's shape.
global ERGOPTI_KEY_DEVIATIONS := Map(
	; AltGr+Shift+Space types nothing (the .keylayout types " - ").
	"altgr_rows_shift", Map("SC039", Map("none", true)),
	"altgr_plus_shift", Map(
		; Ergopti+ keeps Œ on AltGr+Shift+O (its .keylayout types " %").
		"SC012", Map("text", Chr(0x152)),
		; Ergopti+ types "!" after an ordinary space (its .keylayout uses a narrow no-break space).
		"SC018", Map("text", " !")
	)
)

; Deviations from the .keylayout in the dead-key tables: character typed
; after the dead key -> result, "" typing nothing at all.
global ERGOPTI_DEAD_KEY_DEVIATIONS := Map(
	"Circumflex", Map(
		; Characters the KbdEdit-made .keylayout cannot encode yet.
		"0", Chr(0x1F10B),
		; The magic key composes like the j it stands for.
		Chr(0x2605), "j"
	),
	"Diaresis", Map(
		"0", Chr(0x1F10C)
	),
	"Greek", Map(
		"X", Chr(0x39E), "x", Chr(0x3BE),
		; GREEK CAPITAL LETTER OMEGA (the .keylayout types the OHM SIGN).
		"_", Chr(0x3A9),
		Chr(0xCA), ""
	),
	"R", Map(
		; Letters without a double-struck form type nothing.
		"b", "", "c", "", "e", "", "f", "", "h", "", "j", "", "m", "", "n", "",
		"p", "", "q", "", "r", "", "s", "", "t", "", "u", "", "x", "", "z", "",
		Chr(0xAB), Chr(0x27EA), Chr(0xBB), Chr(0x27EB)
	),
	"Subscript", Map(
		"P", Chr(0x209A), "p", Chr(0x1D68), Chr(0xC6), Chr(0x1D01),
		; Letters without a subscript form type nothing.
		"c", "", "d", "", "f", "", "q", "", "w", "", "z", "",
		Chr(0xC8), "", Chr(0xCA), "", Chr(0xE6), "", Chr(0x153), ""
	),
	"Superscript", Map(
		"g", Chr(0x1DA2), "q", Chr(0x107A5), Chr(0xC6), Chr(0x1D2D), Chr(0xE6), Chr(0x10783),
		; Letters without a superscript form type nothing.
		"S", "", "X", "", "Y", "", "Z", "",
		Chr(0xC0), "", Chr(0xC8), "", Chr(0xC9), "", Chr(0xCA), "", Chr(0x152), ""
	)
)





; ========================
; ========================
; ======= 2/ State =======
; ========================
; ========================

; Built tables (ErgoptiLayout_BuildSpec), 0 until ErgoptiLayout_Init ran.
global ERGOPTI_SPEC := 0

; Published dead-key tables: the objects DeadKey and the hotstrings receive.
global DeadkeyMappingCircumflex := Map()
global DeadkeyMappingDiaresis := Map()
global DeadkeyMappingSuperscript := Map()
global DeadkeyMappingSubscript := Map()
global DeadkeyMappingGreek := Map()
global DeadkeyMappingR := Map()
global DeadkeyMappingCurrency := Map()





; =========================
; =========================
; ======= 3/ Tables =======
; =========================
; =========================

_ErgoptiCharacterSet(Characters) {
	Set := Map()
	for Character in Characters
		Set[Character] := true
	return Set
}

; Wrap catalogue spelling of an output: the catalogue writes the guillemets
; with an ordinary space where the .keylayout types a no-break one.
_ErgoptiCatalogueSpelling(Text) {
	global ERGOPTI_NO_BREAK_SPACES
	for Space in ERGOPTI_NO_BREAK_SPACES
		Text := StrReplace(Text, Space, " ")
	return Text
}

_ErgoptiStartsWithNoBreakSpace(Text) {
	global ERGOPTI_NO_BREAK_SPACES
	First := SubStr(Text, 1, 1)
	for Space in ERGOPTI_NO_BREAK_SPACES
		if (First == Space)
			return true
	return false
}

; Catalogue side -> [left, right]. A character that closes one pair and opens
; another (“) resolves to the pair it opens, its canonical key.
_ErgoptiWrapPairIndex(WrapPairs) {
	Index := Map()
	for Pair in WrapPairs
		Index[Pair["right"]] := [Pair["left"], Pair["right"]]
	for Pair in WrapPairs
		Index[Pair["left"]] := [Pair["left"], Pair["right"]]
	return Index
}

/**
 * Descriptor of what one key does on one level.
 * @param {Map} Entry - KeylayoutTables_Levels entry.
 * @param {Map} WrapSet - Characters that wrap the selection on this level.
 * @param {boolean} Typography - Whether no-break-space outputs commit the hotstring first.
 * @param {boolean} Chain - Whether a dead key types its accent inside a sequence.
 * @param {Map} Names - Dead-key state -> table name.
 * @param {Map} Pairs - _ErgoptiWrapPairIndex result.
 * @returns {Map}
 */
_ErgoptiDescribe(Entry, WrapSet, Typography, Chain, Names, Pairs) {
	if (Entry["Kind"] == "dead") {
		if !Names.Has(Entry["State"])
			throw ValueError("The Ergopti .keylayout enters an unknown dead-key state.", -1, Entry["State"])
		Descriptor := Map("dead", Names[Entry["State"]])
		if Chain
			Descriptor["chain"] := Entry["Text"]
		return Descriptor
	}
	Text := Entry["Text"]
	Spelled := _ErgoptiCatalogueSpelling(Text)
	if WrapSet.Has(Spelled) {
		Pair := Pairs.Has(Spelled) ? Pairs[Spelled] : [Spelled, Spelled]
		return Map("wrap", Spelled, "left", Pair[1], "right", Pair[2])
	}
	if Typography && _ErgoptiStartsWithNoBreakSpace(Text)
		return Map("text", Text, "hotstrings", true)
	if RegExMatch(Text, "^\p{L}{2,}$")
		return Map("word", Text)
	return Map("text", Text)
}

_ErgoptiSameOutput(A, B) {
	return (A["Kind"] == B["Kind"]) && (A["Text"] == B["Text"]) && (A["State"] == B["State"])
}

; Plain and Shifted descriptors of the AltGr keys of one table.
_ErgoptiAltGrTables(Plain, Shifted, Keys, WrapSet, Names, Pairs) {
	PlainOut := Map()
	ShiftedOut := Map()
	for Sc in Keys {
		PlainOut[Sc] := Plain.Has(Sc) ? _ErgoptiDescribe(Plain[Sc], WrapSet, false, false, Names, Pairs) : Map("none", true)
		ShiftedOut[Sc] := Shifted.Has(Sc) ? _ErgoptiDescribe(Shifted[Sc], Map(), false, false, Names, Pairs) : Map("none", true)
	}
	return [PlainOut, ShiftedOut]
}

/**
 * Builds the Ergopti emulation tables from the parsed Ergopti and Ergopti+
 * layouts.
 * @param {Map} ErgoptiModel - Parsed ergopti.keylayout.
 * @param {Map} PlusModel - Parsed ergopti_plus.keylayout.
 * @param {Map} KeyCodes - AHK scan code -> macOS key code.
 * @param {Array} WrapPairs - Map("left", ..., "right", ...) of the wrap catalogue.
 * @param {Map} KeyDeviations - Per-table key deviations (ERGOPTI_KEY_DEVIATIONS by default).
 * @param {Map} DeadKeyDeviations - Per-dead-key deviations (ERGOPTI_DEAD_KEY_DEVIATIONS by default).
 * @returns {Map} "levels" (table -> scan code -> descriptor), "dead_keys"
 *   (name -> character -> result) and "terminators" (name -> what the dead key
 *   types alone). A descriptor types "text" (after committing the hotstring when
 *   "hotstrings" is set), types "word" and the space-around-symbols setting,
 *   wraps the selection ("wrap", "left", "right"), starts the dead key "dead"
 *   (typing "chain" inside a sequence), or does nothing ("none"); a base key
 *   whose chords send a configurable letter names it in "shortcut_feature".
 * @throws {ValueError} On a dead key the Ergopti emulation cannot run.
 */
ErgoptiLayout_BuildSpec(ErgoptiModel, PlusModel, KeyCodes, WrapPairs, KeyDeviations := unset,
	DeadKeyDeviations := unset) {
	global ERGOPTI_KEY_DEVIATIONS, ERGOPTI_DEAD_KEY_DEVIATIONS, ERGOPTI_DEAD_KEY_NAMES
	global ERGOPTI_NUMBER_ROW, ERGOPTI_CAPS_LAYER_EXCLUDED, ERGOPTI_WRAP_CHARACTERS
	global ACCENTED_SHORTCUT_LETTERS
	if !IsSet(KeyDeviations)
		KeyDeviations := ERGOPTI_KEY_DEVIATIONS
	if !IsSet(DeadKeyDeviations)
		DeadKeyDeviations := ERGOPTI_DEAD_KEY_DEVIATIONS

	Tables := KeylayoutTables_Build(ErgoptiModel, KeyCodes)
	Levels := Tables["Levels"]
	PlusLevels := KeylayoutTables_Levels(PlusModel, KeyCodes)

	DeadKeys := Map()
	Terminators := Map()
	for State, Dead in Tables["DeadKeys"] {
		if !ERGOPTI_DEAD_KEY_NAMES.Has(State)
			throw ValueError("The Ergopti .keylayout has a dead key the emulation does not name.", -1, State)
		Name := ERGOPTI_DEAD_KEY_NAMES[State]
		Table := Map()
		for Input, Result in Dead["Inputs"] {
			; DeadKey reads one character after the dead key, so a sequence can
			; only end on an output, never enter another dead key.
			if (Result["Next"] != "")
				throw ValueError("The Ergopti emulation cannot chain dead keys.", -1, State . " + " . Input)
			Table[Input] := Result["Output"]
		}
		if DeadKeyDeviations.Has(Name)
			for Input, Output in DeadKeyDeviations[Name]
				Table[Input] := Output
		DeadKeys[Name] := Table
		Terminators[Name] := Dead["Terminator"]
	}
	for Name in DeadKeyDeviations
		if !DeadKeys.Has(Name)
			throw ValueError("A dead-key deviation names a dead key the layout lacks.", -1, Name)

	Names := ERGOPTI_DEAD_KEY_NAMES
	Pairs := _ErgoptiWrapPairIndex(WrapPairs)
	NoWrap := Map()
	ShiftWrap := _ErgoptiCharacterSet(ERGOPTI_WRAP_CHARACTERS["shift"])
	AltGrWrap := _ErgoptiCharacterSet(ERGOPTI_WRAP_CHARACTERS["altgr"])
	ShortcutFeatures := Map()
	for Id, Letter in ACCENTED_SHORTCUT_LETTERS
		ShortcutFeatures[Letter] := Id

	Spec := Map()
	Base := Map()
	for Sc, Entry in Levels["base"] {
		if ERGOPTI_NUMBER_ROW.Has(Sc)
			continue
		Descriptor := _ErgoptiDescribe(Entry, NoWrap, false, false, Names, Pairs)
		if Descriptor.Has("text") && ShortcutFeatures.Has(Descriptor["text"])
			Descriptor["shortcut_feature"] := ShortcutFeatures[Descriptor["text"]]
		Base[Sc] := Descriptor
	}
	Spec["base"] := Base

	Shift := Map()
	for Sc, Entry in Levels["shift"]
		Shift[Sc] := _ErgoptiDescribe(Entry, ShiftWrap, true, false, Names, Pairs)
	Spec["shift"] := Shift

	Caps := Map()
	for Sc, Entry in Levels["caps"] {
		if !ERGOPTI_CAPS_LAYER_EXCLUDED.Has(Sc)
			Caps[Sc] := _ErgoptiDescribe(Entry, NoWrap, false, true, Names, Pairs)
	}
	Spec["caps"] := Caps

	NumberRow := []
	OtherRows := []
	for Sc in KeyCodes {
		if !Levels["altgr"].Has(Sc) && !Levels["altgr_shift"].Has(Sc)
			continue
		if ERGOPTI_NUMBER_ROW.Has(Sc)
			NumberRow.Push(Sc)
		else
			OtherRows.Push(Sc)
	}
	Built := _ErgoptiAltGrTables(Levels["altgr"], Levels["altgr_shift"], NumberRow, AltGrWrap, Names, Pairs)
	Spec["altgr_number_row"] := Built[1]
	Spec["altgr_number_row_shift"] := Built[2]
	Built := _ErgoptiAltGrTables(Levels["altgr"], Levels["altgr_shift"], OtherRows, AltGrWrap, Names, Pairs)
	Spec["altgr_rows"] := Built[1]
	Spec["altgr_rows_shift"] := Built[2]

	; Ergopti+ changes the AltGr keys whose AltGr output differs from Ergopti's;
	; the magic key it also moves belongs to the magic-key feature.
	PlusKeys := []
	for Sc, Entry in PlusLevels["altgr"] {
		if !Levels["altgr"].Has(Sc) || !_ErgoptiSameOutput(Entry, Levels["altgr"][Sc])
			PlusKeys.Push(Sc)
	}
	Built := _ErgoptiAltGrTables(PlusLevels["altgr"], PlusLevels["altgr_shift"], PlusKeys, AltGrWrap, Names, Pairs)
	Spec["altgr_plus"] := Built[1]
	Spec["altgr_plus_shift"] := Built[2]

	for Table, Keys in KeyDeviations {
		if !Spec.Has(Table)
			throw ValueError("A key deviation names an unknown table.", -1, Table)
		for Sc, Descriptor in Keys {
			if !Spec[Table].Has(Sc)
				throw ValueError("A key deviation names a key its table lacks.", -1, Table . " " . Sc)
			Spec[Table][Sc] := Descriptor.Clone()
		}
	}
	return Map("levels", Spec, "dead_keys", DeadKeys, "terminators", Terminators)
}

/**
 * Pairs of the shared wrap catalogue.
 * @param {string} Path - _shared/modules/wrap_symbols/wrap_symbols.json.
 * @returns {Array} Map("left", ..., "right", ...) per pair.
 * @throws {Error} When the catalogue is missing or malformed.
 */
ErgoptiLayout_ReadWrapPairs(Path) {
	Root := JsonParse(FSReadStrict(Path))
	if !(Root is Map) || !Root.Has("groups") || !(Root["groups"] is Array)
		throw Error("The wrap catalogue has no groups: " . Path)
	Pairs := []
	for Group in Root["groups"] {
		for Pair in Group["pairs"] {
			if !(Pair is Map) || !Pair.Has("left") || !Pair.Has("right")
				throw Error("The wrap catalogue holds a malformed pair: " . Path)
			Pairs.Push(Map("left", Pair["left"], "right", Pair["right"]))
		}
	}
	if (Pairs.Length == 0)
		throw Error("The wrap catalogue lists no pair: " . Path)
	return Pairs
}





; ==========================
; ==========================
; ======= 4/ Actions =======
; ==========================
; ==========================

_ErgoptiNothing(*) {
	return 0
}

_ErgoptiTypeAfterHotstrings(Text) {
	ActivateHotstrings()
	SendNewResult(Text)
}

_ErgoptiTypeWord(Word) {
	global SpaceAroundSymbols
	SendNewResult(Word . SpaceAroundSymbols)
}

; A dead key pressed inside a dead-key sequence types its accent instead of
; starting a second sequence.
_ErgoptiDeadKeyOrChain(Chain, Table) {
	global InDeadKeySequence
	if InDeadKeySequence
		SendNewResult(Chain)
	else
		DeadKey(Table)
}

/**
 * Callable a layer registers for a descriptor.
 * @param {Map} Descriptor - ErgoptiLayout_BuildSpec descriptor.
 * @param {Map} DeadTables - Dead-key name -> published table.
 * @returns {Func}
 * @throws {ValueError} On an unknown descriptor or dead key.
 */
ErgoptiLayout_Action(Descriptor, DeadTables) {
	if Descriptor.Has("none")
		return _ErgoptiNothing
	if Descriptor.Has("dead") {
		Name := Descriptor["dead"]
		if !DeadTables.Has(Name)
			throw ValueError("Unknown Ergopti dead key.", -1, Name)
		if Descriptor.Has("chain")
			return _ErgoptiDeadKeyOrChain.Bind(Descriptor["chain"], DeadTables[Name])
		return DeadKey.Bind(DeadTables[Name])
	}
	if Descriptor.Has("wrap")
		return WrapTextIfSelected.Bind(Descriptor["wrap"], Descriptor["left"], Descriptor["right"])
	if Descriptor.Has("word")
		return _ErgoptiTypeWord.Bind(Descriptor["word"])
	if Descriptor.Has("text") {
		if Descriptor.Get("hotstrings", false)
			return _ErgoptiTypeAfterHotstrings.Bind(Descriptor["text"])
		return SendNewResult.Bind(Descriptor["text"])
	}
	Fields := ""
	for Name in Descriptor
		Fields .= Name . " "
	throw ValueError("Unknown Ergopti key descriptor.", -1, Fields)
}





; ==========================
; ==========================
; ======= 5/ Loading =======
; ==========================
; ==========================

ErgoptiLayout_IsLoaded() {
	global ERGOPTI_SPEC
	return IsObject(ERGOPTI_SPEC)
}

/**
 * The loaded tables.
 * @returns {Map} ErgoptiLayout_BuildSpec result.
 * @throws {Error} Before ErgoptiLayout_Init.
 */
ErgoptiLayout_Spec() {
	global ERGOPTI_SPEC
	if !IsObject(ERGOPTI_SPEC)
		throw Error("The Ergopti layout tables are read by ErgoptiLayout_Init, which has not run.")
	return ERGOPTI_SPEC
}

/**
 * Reads the shipped Ergopti layouts and publishes the emulation tables. Runs
 * once, at boot, before any Ergopti layer registers.
 * @param {string} RegistryDir - Folder from LayoutRegistry_BundledDir.
 * @throws {Error} On a second call, or when the shipped layouts are missing,
 *   damaged or unusable: the Ergopti emulation cannot run without them.
 */
ErgoptiLayout_Init(RegistryDir) {
	global ERGOPTI_SPEC, ERGOPTI_LAYOUT_ID, ERGOPTI_PLUS_LAYOUT_ID, ERGOPTI_DEAD_KEY_NAMES, _SharedDir
	global DeadkeyMappingCircumflex, DeadkeyMappingDiaresis, DeadkeyMappingSuperscript
	global DeadkeyMappingSubscript, DeadkeyMappingGreek, DeadkeyMappingR, DeadkeyMappingCurrency
	if IsObject(ERGOPTI_SPEC)
		throw Error("The Ergopti layout tables are already loaded.")
	LoggerStart("ErgoptiLayout", "Reading the Ergopti layout tables from {1}…", RegistryDir)
	Started := A_TickCount
	try {
		Ergopti := LayoutRegistry_ReadBundled(ERGOPTI_LAYOUT_ID, RegistryDir)
		Plus := LayoutRegistry_ReadBundled(ERGOPTI_PLUS_LAYOUT_ID, RegistryDir)
		Convention := Ergopti["Entry"]["keycode_convention"]
		if (Plus["Entry"]["keycode_convention"] !== Convention)
			throw Error("Ergopti and Ergopti+ number their keys differently in the registry.")
		Spec := ErgoptiLayout_BuildSpec(Keylayout_Parse(Ergopti["Text"]), Keylayout_Parse(Plus["Text"]),
			KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), Convention),
			ErgoptiLayout_ReadWrapPairs(_SharedDir . "\modules\wrap_symbols\wrap_symbols.json"))
		DeadKeys := Spec["dead_keys"]
		for State, Name in ERGOPTI_DEAD_KEY_NAMES
			if !DeadKeys.Has(Name)
				throw Error("The Ergopti .keylayout lacks the " . Name . " dead key.")
	} catch as Err {
		LoggerError("ErgoptiLayout", "The Ergopti layout tables cannot be read: {1}", Err.Message)
		throw Err
	}
	DeadkeyMappingCircumflex := DeadKeys["Circumflex"]
	DeadkeyMappingDiaresis := DeadKeys["Diaresis"]
	DeadkeyMappingSuperscript := DeadKeys["Superscript"]
	DeadkeyMappingSubscript := DeadKeys["Subscript"]
	DeadkeyMappingGreek := DeadKeys["Greek"]
	DeadkeyMappingR := DeadKeys["R"]
	DeadkeyMappingCurrency := DeadKeys["Currency"]
	ERGOPTI_SPEC := Spec
	LoggerSuccess("ErgoptiLayout", "Ergopti layout tables read from version {1} in {2} ms ({3} dead keys).",
		Ergopti["Entry"]["version"], A_TickCount - Started, DeadKeys.Count)
}





; =============================
; =============================
; ======= 6/ Base layer =======
; =============================
; =============================

; Reads the configurable target letter for an accented base-layer key from
; ``Features["shortcuts"][Key]["letter"]`` — falls back to ``Fallback``
; when the v2 entry is unset or shape-mismatched. Kept as a named function
; rather than an inline arrow lambda so the closure semantics around the
; ``Features`` global are unambiguous (the arrow form silently captured
; ``Features`` from the enclosing function's local scope, which in some
; AHK v2 builds short-circuited the read and always returned the fallback).
_ErgoptiLetterOr(Key, Fallback) {
	global Features
	if !IsSet(Features) {
		return Fallback
	}
	if !Features.Has("shortcuts") {
		return Fallback
	}
	if !Features["shortcuts"].Has(Key) {
		return Fallback
	}
	Entry := Features["shortcuts"][Key]
	if !IsObject(Entry) {
		return Fallback
	}
	; « Désactivé » in the tray only writes enabled=false and keeps the last
	; letter, so ignoring the flag left the shortcut active after the user turned
	; it off (accented-shortcut-disable-ignored).
	if !Entry.Get("enabled", true) || !Entry.Has("letter") {
		return Fallback
	}
	return Entry["letter"]
}

_ErgoptiScanCodeNumber(Sc) => Integer("0x" . SubStr(Sc, 3))

/**
 * Scan code (number) -> what the base layer types, for every remapped key.
 * An accented key is {c: the letter its Ctrl/Alt/Win chords send, read live
 * from Features["shortcuts"], alt: the letter it types}; the other keys are
 * the character itself. Dead keys are in ErgoptiBaseDeadKeys.
 * @returns {Map}
 */
ErgoptiBaseMapping() {
	Out := Map()
	for Sc, Descriptor in ErgoptiLayout_Spec()["levels"]["base"] {
		if !Descriptor.Has("text")
			continue
		Text := Descriptor["text"]
		Out[_ErgoptiScanCodeNumber(Sc)] := Descriptor.Has("shortcut_feature")
			? { c: _ErgoptiLetterOr(Descriptor["shortcut_feature"], Text), alt: Text }
			: Text
	}
	return Out
}

/**
 * The base layer's dead keys.
 * @returns {Map} Scan code -> Map("chain", what it types inside a dead-key
 *   sequence, "table", its published dead-key table).
 */
ErgoptiBaseDeadKeys() {
	Spec := ErgoptiLayout_Spec()
	Out := Map()
	for Sc, Descriptor in Spec["levels"]["base"] {
		if Descriptor.Has("dead")
			Out[Sc] := Map("chain", Spec["terminators"][Descriptor["dead"]],
				"table", Spec["dead_keys"][Descriptor["dead"]])
	}
	return Out
}

; The same keys flattened to ``sc_int → display_char`` for anything that only
; labels a key (heatmap, debug panels…); an accented key shows the letter its
; chords send, as it always has, and a dead key shows its accent.
ErgoptiBaseLabels() {
	Out := Map()
	for Sc, Value in ErgoptiBaseMapping()
		Out[Sc] := (Value is String) ? Value : Value.c
	for Sc, Dead in ErgoptiBaseDeadKeys()
		Out[_ErgoptiScanCodeNumber(Sc)] := Dead["chain"]
	return Out
}

; Scancode → the character the digit-row emulation (direct_access_digits) types
; on the three keys at the edges of the number row. Its hotkeys in
; modules/keymap/layout.ahk type from this table, and the tap-key menu label
; (infra/tap_keys.ahk) reads it, so a label cannot name a character the key
; does not type.
ErgoptiNumberRowEdgeMapping() {
	return Map(
		0x29, "$", ; SC029, left of 1
		0x0C, "%", ; SC00C, first right of 0
		0x0D, "=", ; SC00D, second right of 0
	)
}

/**
 * Resolves the helper-backed variant from effective features, never a raw registry layout.
 * A runtime gate projects the variant to Ergopti while retained desired intent stays intact.
 * @param {Map} FeaturesSource Effective features; the live map when omitted.
 * @returns {String} Built-in variant, or an empty string for malformed input.
 */
ErgoptiLayout_BuiltinVariant(FeaturesSource := unset) {
	global Features
	if !IsSet(FeaturesSource) {
		if !IsSet(Features)
			return ""
		FeaturesSource := Features
	}
	if !(FeaturesSource is Map)
		return ""
	Layout := FeaturesSource.Get("layout", Map())
	if !(Layout is Map)
		return ""
	Variant := Layout.Get("ergopti_variant", "none")
	return (Variant is String) && (StrCompare(Variant, "none", true) == 0 || StrCompare(Variant, "ergopti", true) == 0 || StrCompare(Variant, "ergopti_plus", true) == 0) ? Variant : ""
}

/**
 * Keeps the helper overlay independent from base and general AltGr admission.
 * A selected registry source supersedes helpers even before its model is loaded.
 * @param {Map} FeaturesSource Effective feature source; the live source when omitted.
 * @returns {Boolean}
 */
ErgoptiLayout_PlusIsActive(FeaturesSource := unset) {
	global Features
	if !IsSet(FeaturesSource) {
		if !IsSet(Features)
			return false
		FeaturesSource := Features
	}
	if ErgoptiLayout_BuiltinVariant(FeaturesSource) != "ergopti_plus"
		return false
	Layout := FeaturesSource["layout"]
	Selected := Layout.Get("emulated_layout", "")
	return (Selected is String) && Selected == ""
}
