; modules/keymap/keylayout/keylayout_emulation.ahk

; ==============================================================================
; MODULE: Registry Layout Emulation
; DESCRIPTION:
; Emulates a registry keyboard layout on Windows by reading its macOS
; .keylayout directly: no Windows version of a layout is compiled, generated
; or stored. The layout the user chose ([layout] emulated_layout) is parsed
; once, at boot or when its download completes; every keystroke then walks the
; parsed Maps.
;
; FEATURES & RATIONALE:
; 1. One source per layout: the .keylayout from the registry is the only thing
;    read. Levels come from the layout's own modifierMap (Shift, CapsLock,
;    AltGr = Option, Ctrl/Alt/Win shortcuts = Command), dead keys and chained
;    dead keys from its actions, exactly as macOS types them.
; 2. Nothing is parsed on the typing path: KeylayoutEmulation_Load builds the
;    scan-code table and the keyMap index of every modifier combination once;
;    a keystroke is a few Map lookups (Keylayout_Step).
; 3. The hotkeys are registered at boot from the shared keycode table, before
;    the Ergopti layers, whether or not the layout is already downloaded: AHK
;    fires the earliest-created variant whose criterion holds, so the
;    emulation wins every key it covers as soon as its layout is loaded, and
;    stays inert (criterion false) until then.
; 4. The base and AltGr switches select which registry layers are emulated.
;    MasterGateDesiredFeatures retains those choices while the effective
;    projection disables the corresponding built-in Ergopti registrations.
;    The independent direct-digit override keeps ownership of its own keys.
; 5. Registration takes injectable Hotkey/HotIf functions and refuses a second
;    call, so tests enumerate every hotkey without touching the keyboard.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Hotkey prefixes of the shortcut chords. Each sends the character of the
; layout's Command level with the same modifiers, like the Ergopti emulation.
; Ctrl+Alt is left out: on Windows it is AltGr.
global KLE_SHORTCUT_PREFIXES := ["^", "^+", "!", "!+", "#", "#+"]

; Keys whose chords stay native: the space bar types the same character on
; every layout's Command level, and Win+Space / Ctrl+Space are system and
; application shortcuts the emulation must not intercept.
global KLE_NATIVE_CHORD_KEYS := Map("SC039", true)

; Keys that end a pending dead key without typing through the layout: the
; sequence is dropped the way a native Windows dead key drops it.
; Physical identities match the shared registry; registering names would be
; shadowed by the scan-code hotkeys of tap-holds and prediction navigation.
global KLE_DEAD_RESET_KEYS := ["SC00E", "SC001", "SC01C", "SC00F", "SC153",
	"SC14B", "SC14D", "SC148", "SC150", "SC147", "SC14F", "SC149", "SC151"]

; Scan code of AltGr (right Alt); the AltGr level uses it as a prefix key, the
; same form as the Ergopti AltGr layer so AHK's variant rules apply to both.
/** Owns the canonical native AltGr declarations used by both registration paths. */
_KLE_BindingDeclaration(Name) {
	switch Name {
		case "altgr_scan": return "SC138"
		case "input_level": return "I2"
	}
	throw ValueError("Unknown native layout binding declaration.")
}

global KLE_ALTGR_SC := _KLE_BindingDeclaration("altgr_scan")

global KLE_INPUT_LEVEL := _KLE_BindingDeclaration("input_level")
; Alt chords need a higher input level to keep the application's own Alt
; shortcuts, as in the Ergopti emulation.
global KLE_ALT_INPUT_LEVEL := "I3"





; ========================
; ========================
; ======= 2/ State =======
; ========================
; ========================

; Parsed layout (Keylayout_Parse model) or 0 while no layout is emulated.
global KLE_Model := 0
; Registry id of the emulated layout, "" while none is.
global KLE_Id := ""
; Dead-key state of the running sequence (KEYLAYOUT_NEUTRAL_STATE when none).
global KLE_State := KEYLAYOUT_NEUTRAL_STATE
; AHK scan code ("SC010") -> macOS key code, for the loaded layout.
global KLE_KeyCodes := Map()
; "s|c|o" flags (Shift, CapsLock, Option) -> keyMap index, plus "command" and the
; "ctrl", "alt" and "win" shortcut levels (the composed layout's own, else "command").
global KLE_LevelIndex := Map()
; Dead-key state -> native character -> resolved transition, built at load.
global KLE_Compositions := Map()
global KLE_Registered := false
; Captured reset metadata is unavailable after partial registration. No rollback
; of already installed hotkeys, native consumption or replay admission is implied.
global _KLE_ResetObserverRegistering := 0
global _KLE_ResetObserverCohort := 0
global _KLE_ResetObserverCapture := 0
global _KLE_ResetObserverGeneration := 0
; The layout source emulation (source_emulation.ahk) of the composed layout:
; its session, or 0 while no emulation table is performed, and the scan code
; of every physical key (KeyboardEvent.code) its actions send.
global KLE_SourceSession := 0
global KLE_SourceScans := Map()
global KLE_SourceRegistered := false

/**
 * The physical rows the layout emulation (a registry layout or the built-in
 * Ergopti one) can leave to the OS layout, each behind its own [layout] switch
 * (emulate_<row>, on by default): a row switched off types what the OS layout
 * types there, on every level the emulation would have typed (base, Shift,
 * CapsLock, AltGr and the shortcut chords). The keys come from the shared
 * physical-key registry through the shared policy (LayoutRowsPolicyKeys), read
 * once: the number row from the key left of 1 to the two right of 0, the top
 * row from the key right of Tab, the home row from the key right of CapsLock
 * (with the ISO key left of Enter), the bottom row from the ISO key left of Z.
 * @param {String} SharedRoot The _shared folder; the driver's own when omitted.
 * @returns {Map} Row id -> Array of scan code names ("SC010"), left to right.
 */
LayoutEmulationRows(SharedRoot := unset) {
	static Rows := 0
	global _SharedDir
	if Rows is Map
		return Rows
	Root := IsSet(SharedRoot) ? SharedRoot : _SharedDir
	Registry := JsonParse(FSReadStrict(Root . "\data\keycodes\physical_keys.json"))
	Built := Map()
	for Row, Codes in LayoutRowsPolicyKeys(Registry) {
		Names := []
		for Code in Codes
			Names.Push(StrUpper(Registry["keys"][Code]["ahk"]))
		Built[Row] := Names
	}
	Rows := Built
	return Rows
}

/**
 * The row of a physical key, "" for a key outside the four rows (the space
 * bar, the modifiers...), which the row switches never leave to the OS.
 * @param {String} Sc Scan code name ("SC010").
 * @returns {String}
 */
LayoutRowOf(Sc) {
	static RowOf := 0
	if !(RowOf is Map) {
		Built := Map()
		for Row, Keys in LayoutEmulationRows()
			for Key in Keys
				Built[Key] := Row
		RowOf := Built
	}
	return RowOf.Get(StrUpper(Sc), "")
}

/**
 * The four row switches in force: the stored ones, each absent one at its
 * manifest default. Before Features is loaded (early boot, the parse-time
 * criteria) every switch is at its manifest default.
 * @returns {Map} "emulate_<row>" -> Boolean.
 */
LayoutRowSwitches() {
	global Features, LAYOUT_ROWS_POLICY_IDS
	Layout := IsSet(Features) && Features is Map && Features.Has("layout") && Features["layout"] is Map
		? Features["layout"] : Map()
	Switches := Map()
	for Row in LAYOUT_ROWS_POLICY_IDS {
		Key := "emulate_" . Row
		Switches[Key] := Layout.Has(Key) ? Layout[Key] : ManifestDefaultFor("layout." . Key)
	}
	return Switches
}

/**
 * Whether every row switch is on, as the manifest ships them: the emulation
 * then types every key it covers, and the row of a key need not be looked up.
 * @param {Map} Switches LayoutRowSwitches().
 * @returns {Boolean}
 */
LayoutRowsAllEmulated(Switches := unset) {
	global LAYOUT_ROWS_POLICY_IDS
	if !IsSet(Switches)
		Switches := LayoutRowSwitches()
	for Row in LAYOUT_ROWS_POLICY_IDS {
		if !LayoutRowsPolicyEmulates(Switches, Row)
			return false
	}
	return true
}

/**
 * Whether the layout emulation types key Sc: its row's switch is on.
 * @param {String} Sc Scan code name ("SC010").
 * @returns {Boolean}
 */
LayoutRowIsEmulated(Sc) {
	Switches := LayoutRowSwitches()
	if LayoutRowsAllEmulated(Switches)
		return true
	Row := LayoutRowOf(Sc)
	return Row == "" || LayoutRowsPolicyEmulates(Switches, Row)
}

/**
 * The same for a hotkey name, read from its last scan code: "SC138 & SC010"
 * is the AltGr level of SC010. A HotIf criterion receives this name.
 * @param {String} HotkeyName
 * @returns {Boolean}
 */
LayoutRowIsEmulatedHotkey(HotkeyName) {
	if !(HotkeyName is String) || !RegExMatch(HotkeyName, "i)(SC[0-9A-F]{3})(?!.*SC[0-9A-F]{3})", &Found)
		return true
	return LayoutRowIsEmulated(Found[1])
}

_KLE_AltGrBindingOwner("initialize")
_KLE_CanonicalSourceOwner("initialize")





; ============================
; ============================
; ======= 3/ Selection =======
; ============================
; ============================

/**
 * Registry id of the layout the user chose to emulate, "" for none.
 * @param {Map} FeaturesSource - Features Map to read; the live one by default.
 * @returns {string}
 */
KeylayoutEmulation_SelectedId(FeaturesSource := unset) {
	global Features
	if !IsSet(FeaturesSource) {
		if !IsSet(Features)
			return ""
		FeaturesSource := Features
	}
	if !FeaturesSource.Has("layout") || !FeaturesSource["layout"].Has(ConfigLeaf.EMULATED_LAYOUT)
		return ""
	Id := FeaturesSource["layout"][ConfigLeaf.EMULATED_LAYOUT]
	return (Id is String) ? Id : ""
}

/**
 * Hotkey criterion: a layout is loaded, the Layout category is enabled and
 * the navigation layer does not own the keys.
 * @returns {boolean}
 */
KeylayoutEmulation_IsActive(*) {
	global KLE_Model, LayerEnabled
	if !IsObject(KLE_Model)
		return false
	if IsSet(LayerEnabled) && LayerEnabled
		return false
	return IsCategoryGated("Layout")
}

/**
 * Whether a requested registry layer owns input under the current master.
 * @param {string} Feature - Layout switch in the retained desired state.
 * @returns {boolean}
 */
KeylayoutEmulation_LayerIsActive(Feature) {
	global Features
	if !KeylayoutEmulation_IsActive() || !IsSet(Features)
		return false
	Desired := MasterGateDesiredFeatures(Features)
	return Desired.Has("layout") && Desired["layout"].Get(Feature, false)
}

_KLE_BaseCriterion(Sc, Shift, ForegroundFn := 0, *) {
	global KLE_State, KEYLAYOUT_NEUTRAL_STATE
	if !KeylayoutEmulation_IsActive()
		return false
	if KLE_State != KEYLAYOUT_NEUTRAL_STATE
		return true
	if !Shift && _KLE_MagicKeyOwnsKey(Sc)
		return false
	; A row switched off is the OS layout's (LayoutRowIsEmulated).
	return KeylayoutEmulation_LayerIsActive(ConfigLeaf.ERGOPTI_BASE) && LayoutRowIsEmulated(Sc)
		&& !_KLE_DigitsOwnKey(Sc, Shift, ForegroundFn)
}

; The magic key is an Ergopti feature tied to the layout that declares it: when
; the active layout declares its key (the built-in Ergopti emulation) or the
; user chose one, that key's unshifted level belongs to the magic-key remap
; (modules/keymap/layout.ahk), as the independent digit row belongs to its own
; override. An emulated layout that declares none, such as Ergo-L, keeps its
; own character there. Shift, AltGr and the shortcut chords always keep the
; emulated layout's characters.
_KLE_MagicKeyOwnsKey(Sc) {
	global Features, ScriptInformation
	return ScriptInformation["MagicKeySourceOverridesEmulation"]
		&& Sc == ScriptInformation["MagicKeySourceScan"]
		&& Features["hotstrings"][ConfigLeaf.MAGIC_KEY]["replace"]["enabled"]
}

_KLE_DigitsOwnKey(Sc, Shift, ForegroundFn := 0) {
	global Features, _SHIFT_DIGIT_SCS
	; The ordering in effect on the layout of the press (the seam's in tests).
	if IsObject(ForegroundFn) {
		Hkl := ForegroundFn.Call()
		Effective := NumberRowEffectiveMode(Hkl)
	} else
		Effective := NumberRowEffectiveMode()
	if Effective != "digits"
		return false
	if Shift {
		if !IsSet(Hkl)
			Hkl := GetForegroundKeyboardLayout()
		Code := Integer("0x" . SubStr(Sc, 3))
		return _SHIFT_DIGIT_SCS.Has(Sc) && _DigitRowSwapResolution(Code, Hkl)["swap"]
	}
	Code := Integer("0x" . SubStr(Sc, 3))
	; Only the ten digit keys: the edge keys keep the emulation's own level.
	return _SHIFT_DIGIT_SCS.Has(Sc)
}

/**
 * Resolves the effective base/Shift descriptors without advancing dead-key state.
 * @param {Integer} Sc Physical Windows scan code.
 * @param {Boolean} Caps CapsLock state of the effective source.
 * @returns {Map|Integer} Plain and Shift descriptors, or 0 if native input owns base.
 */
KeylayoutEmulation_NumberRowLevels(Sc, Caps) {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex
	if !KeylayoutEmulation_LayerIsActive(ConfigLeaf.ERGOPTI_BASE)
		return 0
	Name := Format("SC{:03X}", Sc)
	; A number row switched off is the OS layout's, so is its ordering.
	if !KLE_KeyCodes.Has(Name) || !LayoutRowIsEmulated(Name)
		return 0
	Code := KLE_KeyCodes[Name]
	return Map(
		"plain", Keylayout_Resolve(KLE_Model, KLE_LevelIndex[_KLE_ComboKey(false, Caps, false)], Code),
		"shift", Keylayout_Resolve(KLE_Model, KLE_LevelIndex[_KLE_ComboKey(true, Caps, false)], Code))
}

_KLE_ShortcutCriterion(HotkeyName := "", *) {
	return KeylayoutEmulation_LayerIsActive(ConfigLeaf.ERGOPTI_BASE) && LayoutRowIsEmulatedHotkey(HotkeyName)
}





; ==========================
; ==========================
; ======= 4/ Loading =======
; ==========================
; ==========================

_KLE_ComboKey(Shift, Caps, Option) {
	return (Shift ? "s" : "") . (Caps ? "c" : "") . (Option ? "o" : "")
}

/**
 * AHK scan code -> macOS key code of every key of the shared table, read
 * through a layout's keycode convention.
 * @param {Map} KeycodeTable - Parsed _shared/modules/layouts/mac_keycodes.json.
 * @param {string} Convention - Registry keycode_convention ("iso" | "ansi").
 * @returns {Map}
 * @throws {ValueError} On an unknown convention.
 */
KeylayoutEmulation_KeyCodes(KeycodeTable, Convention) {
	ConventionKnown := false
	for Name in KeycodeTable["conventions"]
		ConventionKnown := ConventionKnown || (Name == Convention)
	if !ConventionKnown
		throw ValueError("Unknown keycode convention.", -1, Convention)
	KeyCodes := Map()
	for Key in KeycodeTable["keys"] {
		Mac := Key["mac"]
		KeyCodes[Key["ahk"]] := (Mac is Map) ? Mac[Convention] : Mac
	}
	return KeyCodes
}

/**
 * Parses a .keylayout and makes it the emulated layout.
 * @param {string} Id - Registry id.
 * @param {string} Text - .keylayout content.
 * @param {string} Convention - Registry keycode_convention ("iso" | "ansi").
 * @param {Map} KeycodeTable - Parsed _shared/modules/layouts/mac_keycodes.json.
 * @returns {Integer} Number of keys emulated.
 * @throws {ValueError} On a malformed layout or keycode table; the previous
 *   layout, if any, stays loaded.
 */
KeylayoutEmulation_Load(Id, Text, Convention, KeycodeTable) {
	return _KLE_CanonicalSourceOwner("load", Id, Text, Convention, KeycodeTable)
}

/**
 * Whether the emulation would accept a .keylayout, without loading it: the
 * same parse, the same level lookup, the same resolution of every key of every
 * level and the same dead-key composition as KeylayoutEmulation_Load, but the
 * emulated layout and the typing state are left alone. The composer's Debug
 * check reads a user's installed layout through it while the emulation runs.
 * @param {string} Id - Registry id.
 * @param {string} Text - .keylayout content.
 * @param {string} Convention - Registry keycode_convention ("iso" | "ansi").
 * @param {Map} KeycodeTable - Parsed _shared/modules/layouts/mac_keycodes.json.
 * @returns {Integer} Number of keys the emulation would take.
 * @throws {Error} Where Load would refuse the layout.
 */
KeylayoutEmulation_Check(Id, Text, Convention, KeycodeTable) {
	KeyCodes := KeylayoutEmulation_KeyCodes(KeycodeTable, Convention)
	Model := Keylayout_Parse(Text)
	LevelIndex := Map()
	for Shift in [false, true] {
		for Caps in [false, true] {
			for Option in [false, true] {
				Pressed := Map()
				if Shift
					Pressed["shift"] := true
				if Caps
					Pressed["caps"] := true
				if Option
					Pressed["option"] := true
				LevelIndex[_KLE_ComboKey(Shift, Caps, Option)] := Keylayout_KeyMapIndex(Model, Pressed)
			}
		}
	}
	LevelIndex["command"] := Keylayout_KeyMapIndex(Model, Map("command", true))
	_KLE_ShortcutLevels(Model, Id, LevelIndex)
	for _, Index in LevelIndex
		for _, Code in KeyCodes
			Keylayout_Resolve(Model, Index, Code)
	_KLE_BuildCompositions(Model)
	return KeyCodes.Count
}

; The shortcut levels of a loaded layout. A registry layout types every Ctrl, Alt
; and Win chord from its Command level; the layout the composer built
; (docs/design/layout-composer.md) selects a keyMap of its own for each of the three, so
; its chords follow the modifier held. A modifier the layout selects no keyMap
; for falls back to the Command level.
_KLE_ShortcutLevels(Model, Id, LevelIndex) {
	LevelIndex["win"] := LevelIndex["command"]
	LevelIndex["ctrl"] := LevelIndex["command"]
	LevelIndex["alt"] := LevelIndex["command"]
	if Id != LayoutRegistry_Composer()["id"]
		return
	for Name, Pressed in Map("ctrl", Map("control", true), "alt", Map("option", true, "command", true)) {
		Index := Keylayout_KeyMapIndex(Model, Pressed)
		if Index != Model["DefaultIndex"]
			LevelIndex[Name] := Index
	}
}

; Native base characters address the layout's actions by their neutral output,
; never by the physical position of the selected layout's different base layer.
_KLE_BuildCompositions(Model) {
	global KEYLAYOUT_NEUTRAL_STATE
	Result := Map()
	for _, Action in Model["Actions"] {
		Neutral := Action.Get(KEYLAYOUT_NEUTRAL_STATE, 0)
		if !(Neutral is Map) || Neutral["Next"] != "" || !Keylayout_IsPrintable(Neutral["Output"])
			continue
		Text := Neutral["Output"]
		for State, Step in Action {
			if State == KEYLAYOUT_NEUTRAL_STATE
				continue
			if !Result.Has(State)
				Result[State] := Map()
			if Result[State].Has(Text) {
				Previous := Result[State][Text]
				if Previous["Output"] != Step["Output"] || Previous["Next"] != Step["Next"]
					throw ValueError("The layout has ambiguous native character composition.", -1, State . ": " . Text)
			}
			Result[State][Text] := Step
		}
	}
	return Result
}

/**
 * Stops emulating: drops the model so every emulation hotkey stands down.
 */
KeylayoutEmulation_Unload() {
	_KLE_CanonicalSourceOwner("unload")
}





; =========================
; =========================
; ======= 5/ Typing =======
; =========================
; =========================

/**
 * Advances the dead-key state machine for one key and returns what it types.
 * @param {string} Sc - AHK scan code ("SC010").
 * @param {boolean} Shift - Shift held.
 * @param {boolean} Caps - CapsLock on.
 * @param {boolean} Option - AltGr held.
 * @returns {string} Text to type ("" while a dead key is pending).
 */
KeylayoutEmulation_Press(Sc, Shift, Caps, Option) {
	global KLE_Model, KLE_State, KLE_KeyCodes, KLE_LevelIndex
	if !IsObject(KLE_Model) || !KLE_KeyCodes.Has(Sc)
		return ""
	Recipe := KeylayoutEmulation_CaptureReplayRoute(Sc, Shift, Caps, Option)
	Step := KeylayoutEmulation_StepReplayRoute(Recipe, KLE_State)
	KLE_State := Step["Next"]
	return Step["Output"]
}

/**
 * Captures one layout route without consulting live modifiers at replay time.
 * @param {string} Sc - Physical AHK scan code.
 * @param {boolean} Shift - Event-time Shift state.
 * @param {boolean} Caps - Event-time CapsLock state.
 * @param {boolean} Option - Event-time AltGr state.
 * @returns {Map} Recipe retaining its admitted model, level and key identity.
 * @throws {ValueError} If the loaded layout does not own this physical key.
 */
KeylayoutEmulation_CaptureReplayRoute(Sc, Shift, Caps, Option) {
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex
	if !(KLE_Model is Map) || !(Sc is String) || !KLE_KeyCodes.Has(Sc)
		throw ValueError("The current layout does not own the replay key.")
	; Supported Load/Unload replace the admitted model rather than mutate it.
	; Retaining that model keeps an accepted recipe valid across a layout swap.
	return Map("model", KLE_Model, "layout_id", KLE_Id, "scan", Sc,
		"index", KLE_LevelIndex[_KLE_ComboKey(Shift, Caps, Option)],
		"keycode", KLE_KeyCodes[Sc])
}

/**
 * Steps one accepted route with its explicit event-time dead-key state.
 * @param {Map} Recipe - Route captured before queued replay or layout changes.
 * @param {string} State - Composition state owned by the replay event stream.
 * @returns {Map} The canonical Next and Output transition from the same parser.
 * @throws {ValueError} If the recipe is incomplete or its state is invalid.
 */
KeylayoutEmulation_StepReplayRoute(Recipe, State) {
	if !(Recipe is Map) || !(State is String)
		throw ValueError("A replay route and composition state are required.")
	for Key in ["model", "layout_id", "scan", "index", "keycode"]
		if !Recipe.Has(Key)
			throw ValueError("The replay route is incomplete.")
	if !(Recipe["model"] is Map) || !(Recipe["layout_id"] is String)
			|| !(Recipe["scan"] is String) || !(Recipe["index"] is Integer)
			|| !(Recipe["keycode"] is Integer) || Recipe["keycode"] < 0
		throw ValueError("The replay route contains invalid layout ownership.")
	return Keylayout_Step(Recipe["model"], State, Recipe["index"], Recipe["keycode"])
}

/**
 * Completes a registry dead key with the effective native base character.
 * @param {string} Sc - Physical AHK scan code.
 * @param {boolean} Shift - Shift held.
 * @param {boolean} Caps - CapsLock toggled.
 * @param {Integer} Hkl - Foreground Windows layout to read without changing it.
 * @returns {Map} Output and Native (whether the OS must receive the original key).
 */
KeylayoutEmulation_PressNative(Sc, Shift, Caps, Hkl) {
	global KLE_Model, KLE_State, KLE_Compositions, KEYLAYOUT_NEUTRAL_STATE, Features
	Code := Integer("0x" . SubStr(Sc, 3))
	Native := KS_KeyTextNoStateChange(KS_ScancodeToVk(Code, Hkl), Code, Hkl, Shift, Caps)
	if NumberRowEffectiveMode(Hkl, Caps) == "digits" {
		if !Shift && Code >= 0x02 && Code <= 0x0B
			Native := {Count: 1, Text: Mod(Code - 1, 10) . ""}
		else if Shift && DigitRowIsSwapped(Hkl) && Code >= 0x02 && Code <= 0x0B
			Native := {Count: 1, Text: DigitRowSwapSymbol(Code, Hkl)}
	} else if Code >= 0x02 && Code <= 0x0B {
		; « Symbols first » on the native row continues a registry dead key too.
		Swapped := NumberRowSymbolsFirstText(Code, Shift, Hkl, Caps)
		if Swapped != ""
			Native := {Count: 1, Text: Swapped}
	}
	return KeylayoutEmulation_ComposeNative(Native)
}

/**
 * Completes the pending registry dead key with what the OS layout types.
 * Split from KeylayoutEmulation_PressNative so the shared emulation vectors
 * can feed the OS character the corpus names instead of reading the machine's.
 * @param {Object} Native - {Count, Text}: the OS character, Count 0 for none.
 * @returns {Map} Output and Native (whether the OS must receive the original key).
 */
KeylayoutEmulation_ComposeNative(Native) {
	global KLE_Model, KLE_State, KLE_Compositions, KEYLAYOUT_NEUTRAL_STATE
	Transitions := KLE_Compositions.Get(KLE_State, Map())
	if Native.Count > 0 && Transitions.Has(Native.Text) {
		Step := Transitions[Native.Text]
		KLE_State := Step["Next"] != "" ? Step["Next"] : KEYLAYOUT_NEUTRAL_STATE
		return Map("Output", Keylayout_IsPrintable(Step["Output"]) ? Step["Output"] : "", "Native", false)
	}
	Prefix := KLE_Model["Terminators"].Get(KLE_State, "")
	if !Keylayout_IsPrintable(Prefix)
		Prefix := ""
	KeylayoutEmulation_ResetDeadKey()
	return Map("Output", Prefix . (Native.Count > 0 ? Native.Text : ""), "Native", Native.Count <= 0)
}

/**
 * Character a shortcut chord sends for ``Sc``: the layout's Command level, or,
 * for the layout the composer built, the level of the held modifier.
 * @param {string} Sc - AHK scan code.
 * @param {string} Mods - The chord's AutoHotkey modifier prefix ("^", "!+", "#"...);
 *   its first character names the modifier. Win (the Command level) by default.
 * @returns {string} One character, or "" when the layout types nothing there
 *   or a dead key (the chord then stays on the physical key).
 */
KeylayoutEmulation_ShortcutChar(Sc, Mods := "#") {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex
	if !IsObject(KLE_Model) || !KLE_KeyCodes.Has(Sc)
		return ""
	Level := Map("^", "ctrl", "!", "alt").Get(SubStr(Mods, 1, 1), "win")
	Resolved := Keylayout_Resolve(KLE_Model, KLE_LevelIndex[Level], KLE_KeyCodes[Sc])
	if (Resolved["Kind"] != "text")
		return ""
	Text := Resolved["Text"]
	return (StrLen(Text) == 1) ? Text : ""
}

KeylayoutEmulation_ResetDeadKey(*) {
	global KLE_State, KEYLAYOUT_NEUTRAL_STATE
	KLE_State := _KLE_ResetDeadKeyTransition()
}

; Shared physical/pure transition. It performs no emission or observer dispatch.
_KLE_ResetDeadKeyTransition() => KEYLAYOUT_NEUTRAL_STATE

/**
 * Captures a callable, non-emitting reset recipe from the exact successful
 * passthrough registration. Its private proof is retained by the BoundFunc;
 * it grants no native FIFO ownership, consumption or production admission.
 */
KeylayoutEmulation_CaptureResetObserver(Sc) {
	global _KLE_ResetObserverCapture
	Factory := _KLE_ResetObserverCapture
	return Factory is BoundFunc && !Object.Prototype.HasOwnProp.Call(Factory, "Call")
		? Factory.Call(Sc) : 0
}

_KLE_CaptureResetObserverOwned(OwnedCohort, OwnedBindings, ExpectedBindings, Generation, Sc) {
	global _KLE_ResetObserverCohort, _KLE_ResetObserverCapture, KLE_Model, KLE_Id, KLE_State
	global KEYLAYOUT_NEUTRAL_STATE, KLE_INPUT_LEVEL
	Cohort := _KLE_ResetObserverCohort
	if Cohort != OwnedCohort || !_KLE_ResetObserverPlainMap(Cohort) || Cohort.Get("generation", 0) != Generation
			|| Cohort.Get("bindings", 0) != OwnedBindings
		return 0
	if !(Sc is String) || !RegExMatch(Sc, "^SC[0-9A-F]{3}$") || !(Cohort is Map) || !(KLE_Model is Map)
			|| !(KLE_Id is String) || KLE_Id == "" || !(KLE_State is String)
			|| KLE_State == KEYLAYOUT_NEUTRAL_STATE
			|| !(Cohort.Get("bindings", 0) is Map) || !Cohort["bindings"].Has(Sc)
		return 0
	Binding := Cohort["bindings"][Sc]
	if !_KLE_ResetObserverPlainMap(Binding) || ExpectedBindings.Get(Sc, 0) != Binding
		return 0
	Proof := Map("cohort", Cohort, "generation", Generation, "factory", _KLE_ResetObserverCapture,
		"bindings", OwnedBindings, "binding", Binding, "scan", Sc, "name", "~" . Sc,
		"callback", KeylayoutEmulation_ResetDeadKey,
		"criterion", _KLE_PendingDeadKeyCriterion, "options", KLE_INPUT_LEVEL,
		"model", KLE_Model, "layout", KLE_Id, "state", KLE_State,
		"neutral", KEYLAYOUT_NEUTRAL_STATE)
	if !_KLE_ResetObserverCurrent(Proof)
		return 0
	try Active := Proof["criterion"].Call()
	catch
		return 0
	if !(Active is Integer) || Active != 1 || !_KLE_ResetObserverCurrent(Proof)
		return 0
	return _KLE_StepCapturedResetObserver.Bind(Proof)
}

; Only the feature's native Maps may carry retained registration metadata.
; Method/property replacement must not execute an opaque getter during fencing.
_KLE_ResetObserverPlainMap(Value) {
	if !(Value is Map) || ObjGetBase(Value) != Map.Prototype
		return false
	for Name in ["Get", "Has", "__Item", "__Enum", "Count"]
		if Object.Prototype.HasOwnProp.Call(Value, Name)
			return false
	return true
}

/** Checks copied registration/source identity without invoking a current handler. */
_KLE_ResetObserverCurrent(Proof) {
	global _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering, KLE_Registered
	global _KLE_ResetObserverCapture, _KLE_ResetObserverGeneration
	global KLE_Model, KLE_Id, KLE_State, KEYLAYOUT_NEUTRAL_STATE, KLE_INPUT_LEVEL
	Cohort := Proof["cohort"], Binding := Proof["binding"]
	if !_KLE_ResetObserverPlainMap(Cohort) || !_KLE_ResetObserverPlainMap(Binding)
			|| !_KLE_ResetObserverPlainMap(Proof["bindings"])
			|| Object.Prototype.HasOwnProp.Call(Proof["factory"], "Call")
		return false
	if IsObject(_KLE_ResetObserverRegistering) || !(KLE_Registered is Integer)
			|| KLE_Registered != 1 || _KLE_ResetObserverCohort != Cohort
			|| !(Cohort.Get("generation", 0) is Integer)
			|| Cohort["generation"] != Proof["generation"] || Proof["generation"] <= 0
			|| _KLE_ResetObserverGeneration != Proof["generation"]
			|| _KLE_ResetObserverCapture != Proof["factory"]
			|| Cohort.Get("bindings", 0) != Proof["bindings"]
			|| Proof["bindings"].Get(Proof["scan"], 0) != Binding
			|| KLE_Model != Proof["model"] || !(KLE_Id is String)
			|| !(KLE_Id == Proof["layout"]) || !(KLE_State is String)
			|| !(KLE_State == Proof["state"]) || !(KEYLAYOUT_NEUTRAL_STATE == Proof["neutral"])
			|| !(KLE_INPUT_LEVEL == Proof["options"])
		return false
	for Name in ["scan", "name", "options"]
		if !(Binding.Get(Name, 0) is String) || !(Binding[Name] == Proof[Name])
			return false
	for Name in ["callback", "criterion"]
		if Binding.Get(Name, 0) != Proof[Name] || !HasMethod(Proof[Name], "Call")
			return false
	return true
}

/** Pure down-edge interpretation; repeated calls do not consume an edge. */
_KLE_StepCapturedResetObserver(Proof, Event, State) {
	if !(Event is Map) || !(State is String) || !(State == Proof["state"])
			|| !_KLE_ResetObserverCurrent(Proof)
		throw ValueError("The captured reset observer source is unavailable.")
	CapturedEvent := Map()
	for Name in ["scan", "origin", "key_up", "repeat"] {
		if !Event.Has(Name)
			throw ValueError("The captured reset observer event is malformed.")
		Value := Event[Name]
		if !(Value is Integer)
			throw ValueError("The captured reset observer event is malformed.")
		CapturedEvent[Name] := Value
	}
	if CapturedEvent["scan"] != Integer("0x" . SubStr(Proof["scan"], 3))
			|| CapturedEvent["origin"] < 1 || CapturedEvent["origin"] > 2
			|| CapturedEvent["key_up"] != 0 || CapturedEvent["repeat"] < 0 || CapturedEvent["repeat"] > 1
		throw ValueError("The captured reset observer edge is unsupported.")
	Next := _KLE_ResetDeadKeyTransition()
	if !(Next == Proof["neutral"]) || !_KLE_ResetObserverCurrent(Proof)
		throw ValueError("The captured reset observer changed its source.")
	return Map("Next", Next, "Output", "", "metadata_only", true,
		"cohort_complete", false, "transformed_output_enabled", false,
		"native_consumed", false)
}

_KLE_Emit(Sc, Shift, Option) {
	_AtCrit := Critical("On")
	try {
		Output := KeylayoutEmulation_Press(Sc, Shift, KS_CapsLockToggleState(), Option)
		if (Output != "")
			SendNewResult(Output)
	} finally {
		Critical(_AtCrit)
	}
}

_KLE_OnKey(Sc, Shift, *) {
	global _SHIFT_DIGIT_SCS
	; A pending dead key admits every continuation (_KLE_BaseCriterion), but a
	; row switched off still belongs to the OS layout: its native character
	; completes the accent, whatever the global base switch says.
	RowEmulated := LayoutRowIsEmulated(Sc)
	if RowEmulated && NumberRowEffectiveMode() == "symbols" && _SHIFT_DIGIT_SCS.Has(Sc)
			&& NumberRowSymbolsCapable(KS_CapsLockToggleState()) {
		Code := Integer("0x" . SubStr(Sc, 3))
		Level := NumberRowSymbolsLevel(Code, KS_CapsLockToggleState())
		if Level["supported"] {
			; Walk the same original source action machine, including pending dead
			; keys and repeats. Ctrl/AltGr registrations retain their own levels.
			_KLE_Emit(Sc, Level["shift"] != Shift, false)
			return
		}
	}
	if RowEmulated && Shift && _SHIFT_DIGIT_SCS.Has(Sc) {
		Code := Integer("0x" . SubStr(Sc, 3))
		Resolution := _DigitRowSwapResolution(Code, GetForegroundKeyboardLayout())
		if Resolution["swap"] && Resolution["source"] == "emulated" {
			; The pending-dead-key variant can already own this physical press.
			; Keep the selected source's action machine, using the same level swap
			; as the dedicated row callback instead of composing native HKL text.
			_KLE_Emit(Sc, false, false)
			return
		}
	}
	if RowEmulated && KeylayoutEmulation_LayerIsActive(ConfigLeaf.ERGOPTI_BASE) && !_KLE_DigitsOwnKey(Sc, Shift) {
		_KLE_Emit(Sc, Shift, false)
		return
	}
	_AtCrit := Critical("On")
	try {
		Step := KeylayoutEmulation_PressNative(Sc, Shift, KS_CapsLockToggleState(), GetForegroundKeyboardLayout())
		if Step["Output"] != ""
			SendNewResult(Step["Output"])
		if Step["Native"]
			SendEvent((Shift ? "+" : "") . "{" . Sc . "}")
	} finally {
		Critical(_AtCrit)
	}
}

_KLE_OnAltGr(Sc, *) {
	Shift := KS_ShiftIsHeld()
	Mods := _KLE_AltGrShortcutMods(_KLE_RealCtrlHeld(), Shift)
	if (Mods != "") {
		_KLE_OnShortcut(Sc, Mods)
		return
	}
	_KLE_Emit(Sc, Shift, true)
}

; Ctrl+AltGr+key sends Ctrl and the logical key, AltGr suspended (ILD-2, decided
; by the maintainer on 2026-11-11, as Linux does): the chord a real Ctrl makes
; of an AltGr press, or "" when AltGr types its level.
; @param CtrlHeld {Boolean} A Ctrl other than AltGr's own is physically held.
; @param Shift {Boolean} Shift is held.
; @returns {String} "^", "^+" or "".
_KLE_AltGrShortcutMods(CtrlHeld, Shift) {
	if !CtrlHeld
		return ""
	return Shift ? "^+" : "^"
}

; Whether a Ctrl other than AltGr's own is physically held: the right Ctrl, or a
; left Ctrl that is not the fake LCtrl a standard AltGr layout adds to every
; AltGr press (the press ledger tells the real key from that alias).
; @param StateFn {Func} (Name) -> physical state; GetKeyState by default.
; @param RealFn {Func} (Name) -> 1 real, 0 alias, -1 unknown; KS_RealPressState by default.
; @returns {Boolean}
_KLE_RealCtrlHeld(StateFn := 0, RealFn := 0) {
	if !HasMethod(StateFn, "Call")
		StateFn := (Name) => GetKeyState(Name, "P")
	if !HasMethod(RealFn, "Call")
		RealFn := KS_RealPressState
	if StateFn.Call("RCtrl")
		return true
	if !StateFn.Call("LCtrl")
		return false
	if !KS_AltGrAddsFakeLCtrl()
		return true
	return RealFn.Call("LCtrl") == 1
}

_KLE_OnShortcut(Sc, Mods, *) {
	Char := KeylayoutEmulation_ShortcutChar(Sc, Mods)
	_AtCrit := Critical("On")
	try {
		KeylayoutEmulation_ResetDeadKey()
		if (Char == "") {
			SendEvent(Mods . "{" . Sc . "}")
		} else if (Mods == "#" && Char == "l" && IsSet(_LockWorkstationEmit)) {
			; A synthetic Win+L does not lock; the Ergopti emulation's helper does.
			_LockWorkstationEmit()
		} else {
			SendEvent(Mods . "{" . Char . "}")
		}
	} finally {
		Critical(_AtCrit)
	}
}

_KLE_AltGrCriterion(HotkeyName := "", *) {
	return KeylayoutEmulation_LayerIsActive(ConfigLeaf.ERGOPTI_ALT_GR) && IsRealAltGrPress()
		&& LayoutRowIsEmulatedHotkey(HotkeyName)
}

_KLE_PendingDeadKeyCriterion(*) {
	global KLE_State, KEYLAYOUT_NEUTRAL_STATE
	return KeylayoutEmulation_IsActive() && KLE_State !== KEYLAYOUT_NEUTRAL_STATE
}





; ===============================
; ===============================
; ======= 6/ Registration =======
; ===============================
; ===============================

/**
 * Registers the emulation hotkeys of every key of the shared keycode table.
 * They stay inert until a layout is loaded. Must run before the Ergopti
 * layers register theirs (see the module header).
 * @param {Map} KeycodeTable - Parsed _shared/modules/layouts/mac_keycodes.json.
 * @param {Func} HotkeyFn - The Hotkey built-in, or a stand-in taking Name, Callback, Options.
 * @param {Func} HotIfFn - The HotIf built-in, or a stand-in taking an optional Criterion.
 * @param {Func|Integer} ForegroundFn Foreground layout reader; native by default.
 * @returns {Integer} Number of hotkeys registered.
 * @throws {Error} On a second registration.
 */
KeylayoutEmulation_Register(KeycodeTable, HotkeyFn := Hotkey, HotIfFn := HotIf, ForegroundFn := 0,
		BrokerFn := MagicEditorRecordLayoutFallback) {
	return _KLE_AltGrBindingOwner("register", KeycodeTable, HotkeyFn, HotIfFn, ForegroundFn, BrokerFn)
}

/** Returns the original AltGr binding factory after complete native registration. */
KeylayoutEmulation_AltGrBindingSource() {
	return _KLE_AltGrBindingOwner("source")
}

/** Captures binding metadata only; caller Maps grant no native input authority. */
KeylayoutEmulation_CaptureAltGrBinding(Source, Scan) {
	return _KLE_AltGrBindingOwner("capture", Source, Scan)
}

/** Owns one native registration attempt independently of the loaded layout. */
_KLE_AltGrBindingOwner(Request, Args*) {
	global KLE_Registered, KLE_ALTGR_SC, KLE_INPUT_LEVEL, _KLE_ResetObserverRegistering, _SharedDir
	static Phase := "uninitialized", Factory := 0, Bindings := Map(), Scans := []
	static OriginalRoot := "", ExpectedScans := [], ExpectedPrefix := "", ExpectedOptions := ""
	static BindingPrefix := "", Options := "", ActiveCriterion := 0, NativeGuard := 0
	static ContextReleased := false
	static NativeCall := Func.Prototype.Call, NativeBind := Func.Prototype.Bind
	static NativeHotIfFunction := HotIf, NativeHotkeyFunction := Hotkey, NativeCriticalFunction := Critical
	static Owners := [KeylayoutEmulation_Register, _KLE_RegisterBindings,
		KeylayoutEmulation_AltGrBindingSource, KeylayoutEmulation_CaptureAltGrBinding,
		_KLE_AltGrBindingOwner, _KLE_OnAltGr, _KLE_AltGrCriterion,
		_KLE_BaseCriterion, _KLE_OnKey, _KLE_ShortcutCriterion, _KLE_OnShortcut,
		_KLE_PendingDeadKeyCriterion, KeylayoutEmulation_ResetDeadKey,
		LayoutRegistry_Keycodes, _LayoutRegistryReadKeycodes, FSReadStrict, JsonParse, FileExist,
		_KLE_BindingDeclaration, MagicEditorRecordLayoutFallback,
		Hotkey, HotIf, Critical, Map.Call, Func.Prototype.Call, Func.Prototype.Bind]

	OwnersCurrent() {
		Current := [KeylayoutEmulation_Register, _KLE_RegisterBindings,
			KeylayoutEmulation_AltGrBindingSource, KeylayoutEmulation_CaptureAltGrBinding,
			_KLE_AltGrBindingOwner, _KLE_OnAltGr, _KLE_AltGrCriterion,
			_KLE_BaseCriterion, _KLE_OnKey, _KLE_ShortcutCriterion, _KLE_OnShortcut,
			_KLE_PendingDeadKeyCriterion, KeylayoutEmulation_ResetDeadKey,
			LayoutRegistry_Keycodes, _LayoutRegistryReadKeycodes, FSReadStrict, JsonParse, FileExist,
			_KLE_BindingDeclaration, MagicEditorRecordLayoutFallback,
			Hotkey, HotIf, Critical, Map.Call, Func.Prototype.Call, Func.Prototype.Bind]
		for BindingIndex, BindingOwnerFunction in Owners
			if !(BindingOwnerFunction is Func) || BindingOwnerFunction != Current[BindingIndex]
					|| Object.Prototype.HasOwnProp.Call(BindingOwnerFunction, "Call")
					|| Object.Prototype.HasOwnProp.Call(BindingOwnerFunction, "Bind")
				return false
		return true
	}

	Plain(Value, Prototype) {
		if !IsObject(Value) || ObjGetBase(Value) != Prototype
			return false
		for BindingName in ObjOwnProps(Value)
			return false
		return true
	}

	BindingsCurrent() {
		if Scans.Length == 0 || Bindings.Count != Scans.Length
			return false
		for BindingScan in Scans {
			if !Bindings.Has(BindingScan)
				return false
			BindingCallback := Bindings[BindingScan]
			if !(BindingCallback is BoundFunc) || Object.Prototype.HasOwnProp.Call(BindingCallback, "Call")
					|| Object.Prototype.HasOwnProp.Call(BindingCallback, "Bind")
				return false
		}
		return true
	}

	SourceCurrent() {
		if Phase != "ready"
			return false
		if !OwnersCurrent() || !(Factory is BoundFunc)
				|| Object.Prototype.HasOwnProp.Call(Factory, "Call")
				|| Object.Prototype.HasOwnProp.Call(Factory, "Bind")
				|| !(KLE_Registered is Integer) || KLE_Registered != 1
				|| !BindingsCurrent() {
			Factory := 0
			Phase := "failed"
			return false
		}
		return true
	}

	CaptureOwned(BindingScan) {
		if !SourceCurrent() || !(BindingScan is String) || !Bindings.Has(BindingScan)
			return 0
		return Map("source", Factory, "scan", BindingScan, "prefix", BindingPrefix,
			"name", BindingPrefix . " & " . BindingScan, "callback", Bindings[BindingScan],
			"criterion", _KLE_AltGrCriterion, "options", Options, "metadata_only", true)
	}

	RequireRegistering() {
		if Phase != "registering" || !OwnersCurrent() || KLE_Registered
			throw Error("The original AltGr binding registration was withdrawn.")
		if IsObject(NativeGuard) && (_KLE_ResetObserverRegistering != NativeGuard
				|| !Plain(NativeGuard, Map.Prototype) || NativeGuard.Get("invalid", true))
			throw Error("The original layout registration guard was withdrawn.")
	}

	NativeHotIf(Values*) {
		; A withdrawn source must still release the original process-wide context.
		if Values.Length == 0 {
			NativeCall.Call(NativeHotIfFunction)
			ActiveCriterion := 0, ContextReleased := true
			return
		}
		RequireRegistering()
		if !IsObject(NativeGuard) {
			NativeGuard := _KLE_ResetObserverRegistering
			if !Plain(NativeGuard, Map.Prototype) || NativeGuard.Get("invalid", true)
				throw Error("The original layout registration guard is unavailable.")
		}
		NativeCall.Call(NativeHotIfFunction, Values*)
		RequireRegistering()
		ActiveCriterion := Values.Length ? Values[1] : 0
		ContextReleased := Values.Length == 0
	}

	NativeHotkey(BindingName, BindingCallback, InputOptions) {
		RequireRegistering()
		NativeCall.Call(NativeHotkeyFunction, BindingName, BindingCallback, InputOptions)
		RequireRegistering()
		if ActiveCriterion != _KLE_AltGrCriterion
			return
		Position := Bindings.Count + 1
		if Position > Scans.Length || BindingName != BindingPrefix . " & " . Scans[Position]
				|| InputOptions != Options || !(BindingCallback is BoundFunc)
				|| Object.Prototype.HasOwnProp.Call(BindingCallback, "Call")
			throw Error("The original AltGr slot did not register completely.")
		Bindings[Scans[Position]] := BindingCallback
	}

	if !(Request is String)
		throw TypeError("A layout binding operation is required.")
	if Request == "initialize" {
		PreviousCritical := NativeCall.Call(NativeCriticalFunction, "On")
		try {
			if Phase != "uninitialized"
				throw Error("Layout binding ownership is already initialized.")
			if !OwnersCurrent() || !IsSet(_SharedDir) || !(_SharedDir is String) || _SharedDir == ""
				throw Error("The original layout binding initialization is unavailable.")
			OriginalRoot := _SharedDir
			ExpectedPrefix := NativeCall.Call(_KLE_BindingDeclaration, "altgr_scan")
			ExpectedOptions := NativeCall.Call(_KLE_BindingDeclaration, "input_level")
			Phase := "fresh"
			return true
		} finally NativeCall.Call(NativeCriticalFunction, PreviousCritical)
	}
	if Request == "source"
		return SourceCurrent() ? Factory : 0
	if Request == "capture"
		return Args.Length == 2 && SourceCurrent() && Args[1] is BoundFunc && Args[1] == Factory
			? CaptureOwned(Args[2]) : 0
	if Request != "register" || Args.Length != 5
		throw ValueError("The layout binding operation is invalid.")
	PreviousCritical := NativeCall.Call(NativeCriticalFunction, "On")
	try {
		if Phase == "uninitialized"
			throw Error("Layout binding ownership has not been initialized.")
		if Phase == "preflight" || Phase == "registering" {
			Phase := "failed"
			throw Error("Layout binding registration was reentered.")
		}
		if Phase == "ready"
			SourceCurrent()
		DelegateLegacy := KLE_Registered || Phase != "fresh"
		if !DelegateLegacy
			Phase := "preflight"
	} finally NativeCall.Call(NativeCriticalFunction, PreviousCritical)
	if DelegateLegacy
		return NativeCall.Call(_KLE_RegisterBindings, Args*)
	try {
		; Injected ports retain their old controlled behavior without source issuance.
		if !OwnersCurrent() || Args[2] != Hotkey || Args[3] != HotIf
				|| !(Args[4] is Integer) || Args[4] != 0 || Args[5] != MagicEditorRecordLayoutFallback {
			Phase := "failed"
			return NativeCall.Call(_KLE_RegisterBindings, Args*)
		}
		if !(KLE_ALTGR_SC is String) || KLE_ALTGR_SC != ExpectedPrefix
				|| !(KLE_INPUT_LEVEL is String) || KLE_INPUT_LEVEL != ExpectedOptions
			throw ValueError("The original AltGr binding declarations were replaced.")
		; Read the original shared file through its retained owner and root, ignoring
		; the replaceable public registry cache. No private inventory is exported.
		Canonical := NativeCall.Call(_LayoutRegistryReadKeycodes, OriginalRoot)
		if Phase != "preflight" || !OwnersCurrent()
			throw Error("Layout binding preflight was withdrawn.")
		if !Plain(Canonical, Map.Prototype) || !Canonical.Has("keys")
				|| !Plain(Canonical["keys"], Array.Prototype) || Canonical["keys"].Length == 0
			throw ValueError("The original layout keycode source is malformed.")
		Seen := Map()
		for BindingKey in Canonical["keys"] {
			if !Plain(BindingKey, Map.Prototype) || !BindingKey.Has("ahk") || !(BindingKey["ahk"] is String)
					|| !RegExMatch(BindingKey["ahk"], "^SC[0-9A-F]{3}$") || Seen.Has(BindingKey["ahk"])
				throw ValueError("The original layout keycode source is malformed.")
			Seen[BindingKey["ahk"]] := true
			ExpectedScans.Push(BindingKey["ahk"])
		}
		Table := Args[1]
		if !Plain(Table, Map.Prototype) || !Table.Has("keys") || !Plain(Table["keys"], Array.Prototype)
				|| Table["keys"].Length != ExpectedScans.Length
			throw ValueError("The supplied layout keycode inventory is not complete.")
		for BindingIndex, BindingKey in Table["keys"] {
			if !Plain(BindingKey, Map.Prototype) || !BindingKey.Has("ahk") || !(BindingKey["ahk"] is String)
					|| BindingKey["ahk"] != ExpectedScans[BindingIndex]
				throw ValueError("The supplied layout keycode inventory was replaced.")
			Scans.Push(ExpectedScans[BindingIndex])
		}
		PreviousCritical := NativeCall.Call(NativeCriticalFunction, "On")
		try {
			if Phase != "preflight" || !OwnersCurrent()
				throw Error("Layout binding preflight cannot adopt a reentered attempt.")
			BindingPrefix := ExpectedPrefix, Options := ExpectedOptions
			Phase := "registering"
		} finally NativeCall.Call(NativeCriticalFunction, PreviousCritical)
	} catch as Err {
		Phase := "failed"
		throw Err
	}
	try {
		BindingResult := NativeCall.Call(_KLE_RegisterBindings, Table,
			NativeBind.Call(NativeHotkey), NativeBind.Call(NativeHotIf), 0, Args[5])
		PreviousCritical := NativeCall.Call(NativeCriticalFunction, "On")
		try {
			if Phase != "registering" || !OwnersCurrent() || !ContextReleased
					|| !BindingsCurrent() || !(KLE_Registered is Integer) || KLE_Registered != 1
				throw Error("The original AltGr binding source did not complete.")
			Factory := NativeBind.Call(CaptureOwned)
			Phase := "ready"
		} finally NativeCall.Call(NativeCriticalFunction, PreviousCritical)
	} catch as Err {
		Factory := 0
		Phase := "failed"
		throw Err
	}
	if !SourceCurrent()
		throw Error("The original AltGr binding source was withdrawn before publication.")
	return BindingResult

	; The effectful body is lexical: no public alternate registration can bypass ownership.
	_KLE_RegisterBindings(KeycodeTable, HotkeyFn := Hotkey, HotIfFn := HotIf, ForegroundFn := 0,
			BrokerFn := MagicEditorRecordLayoutFallback) {
		local Count
		static WinCriteria := Map()
		global KLE_Registered, KLE_SHORTCUT_PREFIXES, KLE_NATIVE_CHORD_KEYS
		global KLE_DEAD_RESET_KEYS, KLE_ALTGR_SC, KLE_INPUT_LEVEL, KLE_ALT_INPUT_LEVEL
		global _KLE_ResetObserverRegistering, _KLE_ResetObserverCohort, _KLE_ResetObserverGeneration
		global _KLE_ResetObserverCapture
		if KLE_Registered
			throw Error("The layout emulation hotkeys are already registered.")
		if IsObject(_KLE_ResetObserverRegistering) {
			_KLE_ResetObserverRegistering["invalid"] := true
			throw Error("Layout emulation registration is already in progress.")
		}
		; A failed attempt may leave physical bindings installed. No captured
		; observer is published until the complete original registration returns.
		_KLE_ResetObserverCohort := 0, _KLE_ResetObserverCapture := 0
		_KLE_ResetObserverGeneration += 1
		if _KLE_ResetObserverGeneration <= 0
			throw Error("Reset observer registration identity overflowed.")
		Registration := Map("generation", _KLE_ResetObserverGeneration, "bindings", Map())
		Guard := Map("invalid", false)
		ScanCodes := []
		for Key in KeycodeTable["keys"]
			ScanCodes.Push(Key["ahk"])
		Count := 0
		; HotIf is process-wide: a timer thread registering another layer must not
		; interleave with this sequence, and the criterion is reset even on a throw.
		_AtCrit := Critical("On")
		_KLE_ResetObserverRegistering := Guard
		try {
			for Sc in ScanCodes {
				HotIfFn.Call(_KLE_BaseCriterion.Bind(Sc, false, ForegroundFn))
				HotkeyFn.Call(Sc, _KLE_OnKey.Bind(Sc, false), KLE_INPUT_LEVEL)
				HotIfFn.Call(_KLE_BaseCriterion.Bind(Sc, true, ForegroundFn))
				HotkeyFn.Call("+" . Sc, _KLE_OnKey.Bind(Sc, true), KLE_INPUT_LEVEL)
				Count += 2
				if KLE_NATIVE_CHORD_KEYS.Has(Sc)
					continue
				HotIfFn.Call(_KLE_ShortcutCriterion)
				for Prefix in KLE_SHORTCUT_PREFIXES {
					Level := (SubStr(Prefix, 1, 1) == "!") ? KLE_ALT_INPUT_LEVEL : KLE_INPUT_LEVEL
					if Prefix == "#" {
						; The broker calls admission without a HotIf name. Retain the
						; physical row here, including across a registration retry.
						if !WinCriteria.Has(Sc)
							WinCriteria[Sc] := _KLE_ShortcutCriterion.Bind("#" . Sc)
						BrokerFn.Call(Sc, _KLE_OnShortcut.Bind(Sc, Prefix), WinCriteria[Sc])
					} else
						HotkeyFn.Call(Prefix . Sc, _KLE_OnShortcut.Bind(Sc, Prefix), Level)
					Count += 1
				}
			}
			HotIfFn.Call(_KLE_AltGrCriterion)
			for Sc in ScanCodes {
				HotkeyFn.Call(KLE_ALTGR_SC . " & " . Sc, _KLE_OnAltGr.Bind(Sc), KLE_INPUT_LEVEL)
				Count += 1
			}
			ResetCriterion := _KLE_PendingDeadKeyCriterion
			HotIfFn.Call(ResetCriterion)
			for Key in KLE_DEAD_RESET_KEYS {
				Binding := Map("scan", Key, "name", "~" . Key,
					"callback", KeylayoutEmulation_ResetDeadKey,
					"criterion", ResetCriterion, "options", KLE_INPUT_LEVEL)
				HotkeyFn.Call(Binding["name"], Binding["callback"], Binding["options"])
				Registration["bindings"][Key] := Binding
				Count += 1
			}
		} finally {
			try HotIfFn.Call()
			finally {
				try Critical(_AtCrit)
				finally {
					if _KLE_ResetObserverRegistering != Guard
						Guard["invalid"] := true
					_KLE_ResetObserverRegistering := 0
				}
			}
		}
		KLE_Registered := true
		if !Guard["invalid"] && Registration["bindings"].Count == KLE_DEAD_RESET_KEYS.Length {
			_KLE_ResetObserverCohort := Registration
			_KLE_ResetObserverCapture := _KLE_CaptureResetObserverOwned.Bind(Registration,
				Registration["bindings"], Registration["bindings"].Clone(), _KLE_ResetObserverGeneration)
		}
		return Count
	}
}







; =======================
; =======================
; ======= 7/ Boot =======
; =======================
; =======================

_KLE_DefaultBootDeps() {
	return Map(
		"keycodes", LayoutRegistry_Keycodes,
		"register", KeylayoutEmulation_Register,
		"read_local", LayoutRegistry_ReadLocal
	)
}

; The registry id the boot could not emulate (not installed, unreadable or
; refused), "" otherwise: the menu names it with « — cannot be emulated ».
global KLE_BootFailedId := ""

/**
 * The selected layout the boot could not emulate, as macOS and Linux report
 * their emulation status error.
 * @returns {string} Its registry id, or "".
 */
KeylayoutEmulation_FailedId() {
	global KLE_BootFailedId
	return KLE_BootFailedId
}

/**
 * Registers the emulation and loads the selected layout from its installed
 * copy. Runs once at boot, before the Ergopti layers register their hotkeys.
 * The boot never installs (decided on 2026-11-12, as macOS and Linux): a layout
 * the user uninstalled stays chosen and is not emulated until it is installed
 * again, and a missing or damaged copy is reported, never silently downloaded.
 * The menu choice installs a layout that is not installed yet.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @param {Map} Deps - "keycodes", "register" and "read_local" implementations;
 *   injectable for tests.
 * @returns {boolean} Whether the layout is emulated when this returns (false
 *   when nothing is selected or it cannot be emulated).
 */
KeylayoutEmulation_Boot(ConfigDir, Deps := 0) {
	global KLE_BootFailedId
	if !(Deps is Map)
		Deps := _KLE_DefaultBootDeps()
	KLE_BootFailedId := ""
	Id := KeylayoutEmulation_SelectedId()
	if (Id == "")
		return false
	if !LayoutRegistry_IsValidId(Id) {
		LoggerError("LayoutEmulation", "The emulated layout '{1}' is not a registry id; nothing is emulated.", Id)
		KLE_BootFailedId := Id
		return false
	}
	KeycodeTable := Deps["keycodes"].Call()
	Composed := Id == LayoutRegistry_Composer()["id"]
	; The source emulation registers first: AHK fires the earliest-created
	; variant whose criterion holds, and its keys go on to the layout below.
	if Composed
		_KLE_SourceBoot(ConfigDir, Deps)
	Hotkeys := Deps["register"].Call(KeycodeTable)
	LoggerInfo("LayoutEmulation", "Registered {1} emulation hotkeys for the '{2}' layout.", Hotkeys, Id)
	LocalDir := LayoutRegistry_LocalDir(ConfigDir)
	try {
		LocalCopy := Deps["read_local"].Call(Id, LocalDir)
	} catch as Err {
		if Composed {
			; The composition exists only on this machine: there is nothing to
			; download. A source stored for the emulation alone (composer_emulate)
			; is read from the composer folder, as read_composed does on macOS and Linux.
			try Stored := Deps.Get("read_composed", LayoutComposer_ReadComposed).Call(ConfigDir)
			catch as StoredErr {
				LoggerError("LayoutEmulation", "The composed layout source is not usable ({1}); save it again in the layout editor.", StoredErr.Message)
				KLE_BootFailedId := Id
				return false
			}
			if Stored is Map {
				LoggerInfo("LayoutEmulation", "Emulating the layout source stored in the composer folder.")
				return _KLE_Activate(Id, Stored, KeycodeTable)
			}
			LoggerError("LayoutEmulation", "The composed layout is not usable ({1}); save it again in the layout manager.", Err.Message)
			KLE_BootFailedId := Id
			return false
		}
		LoggerError("LayoutEmulation", "The '{1}' layout cannot be emulated ({2}); it stays chosen. Choose it again in the Keyboard layout menu, or install it in the layout manager.",
			Id, Err.Message)
		KLE_BootFailedId := Id
		return false
	}
	return _KLE_Activate(Id, LocalCopy, KeycodeTable)
}

_KLE_Activate(Id, LocalCopy, KeycodeTable) {
	global KLE_BootFailedId
	LoggerStart("LayoutEmulation", "Loading the '{1}' layout for emulation…", Id)
	try {
		Keys := KeylayoutEmulation_Load(Id, LocalCopy["Text"], LocalCopy["Entry"]["keycode_convention"], KeycodeTable)
	} catch as Err {
		; Failed preparation must not unload the previously admitted source.
		LoggerError("LayoutEmulation", "Loading the '{1}' layout failed: {2}", Id, Err.Message)
		KLE_BootFailedId := Id
		return false
	}
	LoggerSuccess("LayoutEmulation", "Emulating the '{1}' layout, version {2} ({3} keys).",
		Id, LocalCopy["Entry"]["version"], Keys)
	return true
}

/**
 * Builds complete canonical data for one fixed Caps/Option family.
 * This pure constructor grants no source, handler, native or output authority.
 * The registration frame must capture it through its original private owner.
 * @param {Map} Model Exact admitted parser model retained by the graph.
 * @param {Map} KeyCodes Physical scan to canonical macOS key identity.
 * @param {Array} Levels Base and Shift keyMap indices of the fixed family.
 * @param {String} LayoutName Exact registry identity of the captured model.
 * @param {Boolean} Caps Fixed family value; not a native event selector.
 * @param {Boolean} Option Fixed family value; not an AltGr ownership proof.
 * @returns {BoundFunc} Read-only graph operations returning independent records.
 */
_KLE_BuildReplayGraph(Model, KeyCodes, Levels, LayoutName, Caps, Option) {
	if !(Model is Map) || !(KeyCodes is Map) || !(Levels is Array) || Levels.Length != 2
			|| !(LayoutName is String) || LayoutName == ""
			|| !(Caps is Integer) || Caps < 0 || Caps > 1
			|| !(Option is Integer) || Option < 0 || Option > 1
		throw ValueError("A complete fixed canonical graph family is required.")
	Selectors := []
	for Shift in [0, 1]
		Selectors.Push(Map("shift", Shift, "caps", Caps, "option", Option, "index", Levels[Shift + 1]))
	return _KLE_BuildReplayGraphOwned(Model, KeyCodes, Selectors, LayoutName, false, Caps, Option)
}

/**
 * Builds one state namespace across all eight normal modifier selectors.
 * @param {Map} Model Parsed canonical model.
 * @param {Map} KeyCodes Complete physical scan-to-keycode inventory.
 * @param {Map} Levels Canonical normal combo-to-keyMap indices.
 * @param {String} LayoutName Original source layout identity.
 * @returns {BoundFunc} Detached scalar graph reader, without native authority.
 */
_KLE_BuildNormalReplayGraph(Model, KeyCodes, Levels, LayoutName) {
	if !(Levels is Map)
		throw ValueError("A complete normal canonical selector table is required.")
	Selectors := []
	for Caps in [0, 1] {
		for Option in [0, 1] {
			for Shift in [0, 1] {
				Name := _KLE_ComboKey(Shift, Caps, Option)
				if !Levels.Has(Name)
					throw ValueError("The normal canonical selector table is incomplete.")
				Selectors.Push(Map("shift", Shift, "caps", Caps, "option", Option, "index", Levels[Name]))
			}
		}
	}
	return _KLE_BuildReplayGraphOwned(Model, KeyCodes, Selectors, LayoutName, true)
}

; Both public data scopes share the same transition and immutable-reader owner.
_KLE_BuildReplayGraphOwned(Model, KeyCodes, Selectors, LayoutName, Normal, Caps := 0, Option := 0) {
	global KEYLAYOUT_NEUTRAL_STATE
	GraphCall := Func.Prototype.Call, GraphMapClone := Map.Prototype.Clone, GraphArrayClone := Array.Prototype.Clone
	if !(Model is Map) || !(KeyCodes is Map) || !(LayoutName is String) || LayoutName == ""
			|| !(Normal is Integer) || (Normal != 0 && Normal != 1)
			|| !(Selectors is Array) || Selectors.Length != (Normal ? 8 : 2)
		throw ValueError("A complete canonical graph selector inventory is required.")
	Sets := Model.Get("KeyMapSets", 0), MapSet := Model.Get("MapSet", 0)
	if !(Sets is Map) || !(MapSet is String) || !Sets.Has(MapSet) || !(Sets[MapSet] is Map)
		throw ValueError("The canonical graph map set is undefined.")
	Bases := Model.Get("Bases", Map()).Get(MapSet, 0)
	CapturedSelectors := [], SelectorKeys := Map()
	for Selector in Selectors {
		if !(Selector is Map)
			throw ValueError("The canonical graph selector is invalid.")
		for Name in ["shift", "caps", "option"]
			if !Selector.Has(Name) || !(Selector[Name] is Integer) || Selector[Name] < 0 || Selector[Name] > 1
				throw ValueError("The canonical graph modifier selector is invalid.")
		if !Selector.Has("index")
			throw ValueError("The canonical graph level identity is invalid.")
		Index := Selector["index"]
		if !(Index is Integer) || Index < 0
				|| (!Sets[MapSet].Has(Index) && (!(Bases is Map) || !Bases.Has(Index)))
			throw ValueError("The canonical graph level identity is invalid.")
		SelectorKey := Selector["shift"] . "|" . Selector["caps"] . "|" . Selector["option"]
		if SelectorKeys.Has(SelectorKey) || (!Normal && (Selector["caps"] != Caps || Selector["option"] != Option))
			throw ValueError("The canonical graph selector inventory is ambiguous.")
		SelectorKeys[SelectorKey] := true
		CapturedSelectors.Push([Selector["shift"], Selector["caps"], Selector["option"], Index])
	}
	if KeyCodes.Count == 0
		throw ValueError("The canonical graph requires its physical key inventory.")
	Names := ""
	for Scan, Code in KeyCodes {
		if !(Scan is String) || !RegExMatch(Scan, "^SC[0-9A-F]{3}$")
				|| Integer("0x" . SubStr(Scan, 3)) == 0
				|| Integer("0x" . SubStr(Scan, 3)) > 0x1FF
				|| !(Code is Integer) || Code < 0
			throw ValueError("The canonical graph physical identity is invalid.")
		Names .= Scan . "`n"
	}
	Keys := [], SeenKeys := Map()
	Loop Parse, Sort(RTrim(Names, "`n")), "`n" {
		Scan := A_LoopField
		if !KeyCodes.Has(Scan) || SeenKeys.Has(Scan)
			throw ValueError("The canonical graph physical inventory changed during sorting.")
		SeenKeys[Scan] := true
		Keys.Push([Scan, KeyCodes[Scan]])
	}
	if Keys.Length != KeyCodes.Count
		throw Error("The canonical graph physical inventory was truncated.")
	States := [KEYLAYOUT_NEUTRAL_STATE], StateIds := Map()
	StateIds.CaseSense := "On"
	StateIds[KEYLAYOUT_NEUTRAL_STATE] := 0
	Rows := [], Lookup := Map(), Cursor := 1
	Lookup.CaseSense := "On"
	while Cursor <= States.Length {
		Before := States[Cursor], BeforeId := Cursor - 1
		Cursor += 1
		for Key in Keys {
			for Selector in CapturedSelectors {
				Shift := Selector[1], RowCaps := Selector[2], RowOption := Selector[3], Index := Selector[4]
				Step := Keylayout_Step(Model, Before, Index, Key[2])
				if !(Step is Map) || !(Step.Get("Output", 0) is String)
						|| !(Step.Get("Next", 0) is String) || Step["Next"] == ""
					throw ValueError("The canonical graph transition is invalid.")
				After := Step["Next"]
				if !StateIds.Has(After) {
					StateIds[After] := States.Length
					States.Push(After)
				}
				AfterId := StateIds[After]
				; A neutral nonprinting key is data, never a character admission.
				Kind := BeforeId || AfterId ? 3
					: Step["Output"] == "" ? 0 : RegExMatch(Step["Output"], "^[0-9]$") ? 2 : 1
				Row := Map("before", Before, "after", After,
					"before_id", BeforeId, "after_id", AfterId,
					"scan", Key[1], "shift", Shift, "index", Index, "keycode", Key[2],
					"output", Step["Output"], "kind", Kind)
				if Normal
					Row["caps"] := RowCaps, Row["option"] := RowOption
				Rows.Push(Row)
				LookupKey := Before . "|" . Key[1] . "|" . Shift
				if Normal
					LookupKey .= "|" . RowCaps . "|" . RowOption
				if Lookup.Has(LookupKey)
					throw Error("The canonical graph transition selector is duplicated.")
				Lookup[LookupKey] := Rows.Length
			}
		}
	}
	if Rows.Length != States.Length * Keys.Length * CapturedSelectors.Length
		throw Error("The canonical graph family was truncated.")
	Information := Map("layout_name", LayoutName, "model_key", ObjPtr(Model),
		"caps", Caps, "option", Option, "physical_keys", Keys.Length,
		"states", States.Length, "transitions", Rows.Length)
	if Normal {
		Information.Delete("caps"), Information.Delete("option")
		Information["selectors"] := CapturedSelectors.Length
	}
	return Read.Bind()

	Read(Operation, Args*) {
		switch Operation {
			case "info":
				if Args.Length != 0
					throw ValueError("Canonical graph info takes no arguments.")
				return GraphCall.Call(GraphMapClone, Information)
			case "row":
				if Args.Length != 1 || !(Args[1] is Integer) || Args[1] < 1 || Args[1] > Rows.Length
					throw ValueError("The canonical graph row identity is invalid.")
				return GraphCall.Call(GraphMapClone, Rows[Args[1]])
			case "states":
				if Args.Length != 0
					throw ValueError("Canonical graph states take no arguments.")
				return GraphCall.Call(GraphArrayClone, States)
			case "find":
				if Args.Length != (Normal ? 5 : 3) || !(Args[1] is String) || !(Args[2] is String)
						|| !(Args[3] is Integer) || Args[3] < 0 || Args[3] > 1
						|| !StateIds.Has(Args[1]) || !RegExMatch(Args[2], "^SC[0-9A-F]{3}$")
					throw ValueError("The canonical graph lookup identity is invalid.")
				LookupKey := Args[1] . "|" . Args[2] . "|" . Args[3]
				if Normal {
					for Position in [4, 5]
						if !(Args[Position] is Integer) || Args[Position] < 0 || Args[Position] > 1
							throw ValueError("The canonical graph lookup modifier is invalid.")
					LookupKey .= "|" . Args[4] . "|" . Args[5]
				}
				if !Lookup.Has(LookupKey)
					throw ValueError("The canonical graph does not own that transition.")
				return GraphCall.Call(GraphMapClone, Rows[Lookup[LookupKey]])
			case "matches_model":
				; Identity only. Source-epoch and semantic admission belong to the frame.
				if Args.Length != 1
					throw ValueError("Canonical graph model comparison takes one argument.")
				return Args[1] == Model
			default:
				throw ValueError("Unknown canonical graph operation.")
		}
	}
}

/**
 * Retains exact identities and scalar contents of plain canonical source data.
 * The returned guard reads no callback or user property. It does not copy input
 * authority: only the original source loader may use it to issue a live lease.
 * @param {Array} Roots Parser model and its companion source containers.
 * @returns {BoundFunc} Read-only structural identity and content guard.
 */
_KLE_CaptureCanonicalImage(Roots) {
	Images := Map()
	Capture(Roots)
	return Current.Bind()

	Plain(Value, Prototype) {
		if ObjGetBase(Value) != Prototype
			return false
		for Name in ObjOwnProps(Value)
			return false
		return true
	}

	Capture(Value) {
		if !IsObject(Value) {
			if !(Value is String) && !(Value is Integer)
				throw ValueError("Canonical source scalars must have exact types.")
			return
		}
		if Images.Has(Value)
			return
		if Value is Map && Plain(Value, Map.Prototype) {
			Pairs := []
			Images[Value] := {Kind: "map", Policy: Value.CaseSense, Items: Pairs}
			for Key, Item in Value {
				if !(Key is String) && !(Key is Integer)
					throw ValueError("Canonical source keys must have exact scalar types.")
				Pairs.Push([Key, Item])
				Capture(Item)
			}
		} else if Value is Array && Plain(Value, Array.Prototype) {
			Items := []
			Images[Value] := {Kind: "array", Items: Items}
			Loop Value.Length {
				if !Value.Has(A_Index)
					throw ValueError("Canonical source arrays cannot contain holes.")
				Items.Push(Value[A_Index])
				Capture(Value[A_Index])
			}
		} else
			throw ValueError("Canonical source containers must be plain data.")
	}

	Same(Actual, Expected) {
		return Type(Actual) == Type(Expected) && Actual == Expected
	}

	Current() {
		for Value, Image in Images {
			if Image.Kind == "map" {
				if !(Value is Map) || !Plain(Value, Map.Prototype)
						|| !Same(Value.CaseSense, Image.Policy) || Value.Count != Image.Items.Length
					return false
				Index := 0
				for Key, Item in Value {
					Index += 1
					if !Same(Key, Image.Items[Index][1]) || !Same(Item, Image.Items[Index][2])
						return false
				}
			} else {
				if !(Value is Array) || !Plain(Value, Array.Prototype) || Value.Length != Image.Items.Length
					return false
				Loop Value.Length
					if !Value.Has(A_Index) || !Same(Value[A_Index], Image.Items[A_Index])
						return false
			}
		}
		return true
	}
}

/**
 * Owns parsing, publication and capture of the original canonical layout source.
 * No operation accepts an already-parsed model, a graph or a publication witness.
 * Preparation finishes before atomic publication; failed loads preserve the old
 * source. A retained reader remains data after live-source withdrawal.
 * @param {String} Request initialize, load, unload or capture.
 * @param {Array} Args Exact public Load arguments for the load operation only.
 * @returns {Integer|Map} Loaded key count, or an original read-only source lease.
 */
_KLE_CanonicalSourceOwner(Request, Args*) {
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions
	global KEYLAYOUT_NEUTRAL_STATE
	global KEYLAYOUT_MODIFIER_TOKENS, KEYLAYOUT_MAX_BASE_DEPTH
	global _KEYLAYOUT_TAG_RE, _KEYLAYOUT_ATTR_RE, _KEYLAYOUT_ENTITY_RE
	static Initialized := false, Busy := false, Epoch := 0, Cell := 0, Vocabulary := 0
	static OriginalOwners := [_KLE_CanonicalSourceOwner, _KLE_CaptureCanonicalImage,
		_KLE_BuildReplayGraph, KeylayoutEmulation_Load, KeylayoutEmulation_Unload,
		KeylayoutEmulation_CaptureCanonicalSource, KeylayoutEmulation_KeyCodes,
		_KLE_BuildCompositions, _KLE_ComboKey, Keylayout_Parse, Keylayout_DecodeEntities,
		_Keylayout_Attributes, _Keylayout_ParseModifierKeys, Keylayout_KeyMapIndex,
		Keylayout_KeyEntry, Keylayout_Resolve, Keylayout_IsPrintable, Keylayout_Step,
		Map.Call, Map.Prototype.Clone, Array.Prototype.Clone,
		Func.Prototype.Call, Func.Prototype.Bind, Critical,
		_KLE_BuildNormalReplayGraph, _KLE_BuildReplayGraphOwned, Keylayout_ParseCanonical]
	static NativeCall := Func.Prototype.Call, NativeBind := Func.Prototype.Bind, NativeCritical := Critical

	FunctionsCurrent() {
		Owners := [_KLE_CanonicalSourceOwner, _KLE_CaptureCanonicalImage,
			_KLE_BuildReplayGraph, KeylayoutEmulation_Load, KeylayoutEmulation_Unload,
			KeylayoutEmulation_CaptureCanonicalSource, KeylayoutEmulation_KeyCodes,
			_KLE_BuildCompositions, _KLE_ComboKey, Keylayout_Parse, Keylayout_DecodeEntities,
			_Keylayout_Attributes, _Keylayout_ParseModifierKeys, Keylayout_KeyMapIndex,
			Keylayout_KeyEntry, Keylayout_Resolve, Keylayout_IsPrintable, Keylayout_Step,
			Map.Call, Map.Prototype.Clone, Array.Prototype.Clone,
			Func.Prototype.Call, Func.Prototype.Bind, Critical,
			_KLE_BuildNormalReplayGraph, _KLE_BuildReplayGraphOwned, Keylayout_ParseCanonical]
		for Index, Original in OriginalOwners
			if !(Original is Func) || Original != Owners[Index]
					|| Object.Prototype.HasOwnProp.Call(Original, "Call")
				return false
		if IsObject(Vocabulary) {
			for Pair in [[KEYLAYOUT_NEUTRAL_STATE, Vocabulary.Neutral],
				[KEYLAYOUT_MAX_BASE_DEPTH, Vocabulary.MaxDepth], [_KEYLAYOUT_TAG_RE, Vocabulary.Tag],
				[_KEYLAYOUT_ATTR_RE, Vocabulary.Attribute], [_KEYLAYOUT_ENTITY_RE, Vocabulary.Entity]]
				if Type(Pair[1]) != Type(Pair[2]) || !(Pair[1] == Pair[2])
					return false
			if KEYLAYOUT_MODIFIER_TOKENS != Vocabulary.Tokens
					|| Object.Prototype.HasOwnProp.Call(Vocabulary.Image, "Call")
					|| !NativeCall.Call(Vocabulary.Image)
				return false
		}
		return true
	}

	RequireFunctions() {
		if !FunctionsCurrent() {
			if IsObject(Cell)
				Cell.Revoked := true
			throw Error("The original canonical source constructor was withdrawn.")
		}
	}

	PrepareCell(Active, Model, Id, Keys, Levels, Compositions, Graph := 0, NormalGraph := 0) {
		RequireFunctions()
		Image := NativeCall.Call(OriginalOwners[2], [Model, Keys, Levels, Compositions])
		RequireFunctions()
		if !(Image is BoundFunc) || Object.Prototype.HasOwnProp.Call(Image, "Call") || !Image.Call()
			throw Error("The prepared canonical source data changed before issuance.")
		return {Active: Active, Revoked: false, Model: Model, Id: Id, Keys: Keys, Levels: Levels,
			Compositions: Compositions, Graph: Graph, NormalGraph: NormalGraph, Image: Image}
	}

	CellCurrent(OriginalCell, OriginalEpoch) {
		return FunctionsCurrent() && !OriginalCell.Revoked && Cell == OriginalCell && Epoch == OriginalEpoch
			&& Type(KLE_Model) == Type(OriginalCell.Model) && KLE_Model == OriginalCell.Model
			&& Type(KLE_Id) == Type(OriginalCell.Id) && KLE_Id == OriginalCell.Id && KLE_KeyCodes == OriginalCell.Keys
			&& KLE_LevelIndex == OriginalCell.Levels && KLE_Compositions == OriginalCell.Compositions
			&& !Object.Prototype.HasOwnProp.Call(OriginalCell.Image, "Call")
			&& (!IsObject(OriginalCell.Graph) || !Object.Prototype.HasOwnProp.Call(OriginalCell.Graph, "Call"))
			&& (!IsObject(OriginalCell.NormalGraph) || !Object.Prototype.HasOwnProp.Call(OriginalCell.NormalGraph, "Call"))
			&& NativeCall.Call(OriginalCell.Image)
	}

	IssueLease(OriginalCell, OriginalEpoch) {
		RequireFunctions()
		for Graph in [OriginalCell.Graph, OriginalCell.NormalGraph]
			if IsObject(Graph) && (!(Graph is BoundFunc) || Object.Prototype.HasOwnProp.Call(Graph, "Call"))
				throw Error("The original canonical graph reader was withdrawn.")
		CurrentGuard := NativeCall.Call(NativeBind, Current)
		Reader := NativeCall.Call(NativeBind, Read, OriginalCell.Graph)
		NormalReader := NativeCall.Call(NativeBind, Read, OriginalCell.NormalGraph)
		RequireFunctions()
		return Map("active", OriginalCell.Active, "epoch", OriginalEpoch,
			"layout_name", OriginalCell.Id, "model", OriginalCell.Model,
			"current", CurrentGuard, "read", Reader, "normal_read", NormalReader)

		Current() {
			; Preparation temporarily blocks admission; a failed Load keeps its source.
			if !Initialized || Busy
				return false
			if CellCurrent(OriginalCell, OriginalEpoch)
				return true
			OriginalCell.Revoked := true
			return false
		}

		Read(CapturedGraph, Operation, ReadArgs*) {
			; Historical scalar rows do not require the current loader or parser.
			if Func.Prototype.Call != NativeCall || Object.Prototype.HasOwnProp.Call(NativeCall, "Call")
					|| !(CapturedGraph is BoundFunc) || Object.Prototype.HasOwnProp.Call(CapturedGraph, "Call")
				throw Error("The captured canonical source has no admitted graph reader.")
			return NativeCall.Call(CapturedGraph, Operation, ReadArgs*)
		}
	}

	RequireFunctions()
	if !(Request is String)
		throw ValueError("A canonical source operation is required.")
	if Request == "initialize" {
		if Args.Length != 0 || Initialized || Busy
			throw Error("The canonical source owner cannot initialize twice.")
		PreparedVocabulary := {Tokens: KEYLAYOUT_MODIFIER_TOKENS, Neutral: KEYLAYOUT_NEUTRAL_STATE,
			MaxDepth: KEYLAYOUT_MAX_BASE_DEPTH, Tag: _KEYLAYOUT_TAG_RE,
			Attribute: _KEYLAYOUT_ATTR_RE, Entity: _KEYLAYOUT_ENTITY_RE}
		PreparedVocabulary.Image := NativeCall.Call(OriginalOwners[2], [KEYLAYOUT_MODIFIER_TOKENS])
		Vocabulary := PreparedVocabulary
		Cell := PrepareCell(false, KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions)
		Initialized := true
		return 0
	}
	if !Initialized || Busy
		throw Error("The canonical source owner is unavailable.")
	if Request == "capture" {
		if Args.Length != 0
			throw ValueError("Canonical source capture takes no supplied witness.")
		Lease := IssueLease(Cell, Epoch)
		if !Lease["current"].Call()
			throw Error("The live canonical source changed during capture.")
		return Lease
	}
	if Request != "load" && Request != "unload"
		throw ValueError("Unknown canonical source operation.")
	if Args.Length != (Request == "load" ? 4 : 0)
		throw ValueError("The canonical source operation has invalid arguments.")
	PreviousCell := Cell, PreviousEpoch := Epoch
	; Explicit Load reparses new inputs; it does not adopt the old public state.
	; The starting image only fences concurrent mutation during that preparation.
	PreviousModel := KLE_Model, PreviousId := KLE_Id, PreviousKeys := KLE_KeyCodes
	PreviousLevels := KLE_LevelIndex, PreviousCompositions := KLE_Compositions
	StartingImage := NativeCall.Call(OriginalOwners[2],
		[PreviousModel, PreviousKeys, PreviousLevels, PreviousCompositions])
	Busy := true
	try {
		if Request == "load" {
			Id := Args[1], Text := Args[2], Convention := Args[3], KeycodeTable := Args[4]
			KeyCodes := NativeCall.Call(OriginalOwners[7], KeycodeTable, Convention)
			; Supplied keycode data may run an observer before the next producer.
			RequireFunctions()
			Model := NativeCall.Call(OriginalOwners[10], Text)
			RequireFunctions()
			LevelIndex := Map()
			for Shift in [false, true] {
				for Caps in [false, true] {
					for Option in [false, true] {
						Pressed := Map()
						if Shift
							Pressed["shift"] := true
						if Caps
							Pressed["caps"] := true
						if Option
							Pressed["option"] := true
						LevelIndex[_KLE_ComboKey(Shift, Caps, Option)] := Keylayout_KeyMapIndex(Model, Pressed)
					}
				}
			}
			LevelIndex["command"] := Keylayout_KeyMapIndex(Model, Map("command", true))
			_KLE_ShortcutLevels(Model, Id, LevelIndex)
			for _, Index in LevelIndex
				for _, Code in KeyCodes
					Keylayout_Resolve(Model, Index, Code)
			Compositions := _KLE_BuildCompositions(Model)
			RequireFunctions()
			Levels := [LevelIndex[_KLE_ComboKey(0, 0, 0)], LevelIndex[_KLE_ComboKey(1, 0, 0)]]
			Graph := NativeCall.Call(OriginalOwners[3], Model, KeyCodes, Levels, Id, 0, 0)
			NormalGraph := NativeCall.Call(OriginalOwners[25], Model, KeyCodes, LevelIndex, Id)
			NewCell := PrepareCell(true, Model, Id, KeyCodes, LevelIndex, Compositions, Graph, NormalGraph)
		} else {
			Model := 0, Id := "", KeyCodes := Map(), Compositions := Map()
			LevelIndex := KLE_LevelIndex
			NewCell := PrepareCell(false, Model, Id, KeyCodes, LevelIndex, Compositions)
		}
		RequireFunctions()
		NewEpoch := Epoch + 1
		if !(NewEpoch is Integer) || NewEpoch <= Epoch
			throw Error("The canonical source epoch overflowed.")
		PreviousCritical := NativeCall.Call(NativeCritical, "On")
		try {
			RequireFunctions()
			if Cell != PreviousCell || Epoch != PreviousEpoch
					|| Type(KLE_Model) != Type(PreviousModel) || !(KLE_Model == PreviousModel)
					|| Type(KLE_Id) != Type(PreviousId) || !(KLE_Id == PreviousId) || KLE_KeyCodes != PreviousKeys
					|| KLE_LevelIndex != PreviousLevels || KLE_Compositions != PreviousCompositions
					|| Object.Prototype.HasOwnProp.Call(StartingImage, "Call")
					|| !NativeCall.Call(StartingImage)
				throw Error("The starting canonical source changed during preparation.")
			KLE_Model := Model, KLE_Id := Id, KLE_State := KEYLAYOUT_NEUTRAL_STATE
			KLE_KeyCodes := KeyCodes, KLE_LevelIndex := LevelIndex, KLE_Compositions := Compositions
			Cell := NewCell, Epoch := NewEpoch
			Busy := false
		} finally NativeCall.Call(NativeCritical, PreviousCritical)
		return KeyCodes.Count
	} finally Busy := false
}

/** Returns source data issued by the original loader, never by supplied maps. */
KeylayoutEmulation_CaptureCanonicalSource() {
	return _KLE_CanonicalSourceOwner("capture")
}





; ===================================
; ===================================
; ======= 8/ Source emulation =======
; ===================================
; ===================================

; Keys the source emulation never takes: the built-in modifiers it reads the
; state of, and the keys the source compiler reports as not emulated.
_KLE_SourceUntaken() {
	static Untaken := Map("ShiftLeft", true, "ShiftRight", true, "ControlLeft", true, "ControlRight", true,
		"AltLeft", true, "AltRight", true, "MetaLeft", true, "MetaRight", true, "CapsLock", true, "ContextMenu", true)
	return Untaken
}

; The hotkey names one source key takes: those of the layout below (so the
; earlier variant wins whatever the precedence of a wildcard), then the wildcard.
_KLE_SourceHotkeyNames(Sc) {
	Names := [Sc, "+" . Sc]
	for Prefix in KLE_SHORTCUT_PREFIXES
		Names.Push(Prefix . Sc)
	Names.Push("*" . Sc)
	return Names
}

/**
 * Loads the emulation table of the composed layout's source and registers its
 * keys. Registered before the keylayout emulation and at the default input
 * level 0, so only physical input reaches it: a key it leaves alone is sent on
 * at SendLevel 1, which the layout emulation below (I2) receives.
 * @param {Map} Model - From SourceEmulation_Compile.
 * @param {Map} Registry - Decoded physical_keys.json.
 * @param {Func} HotkeyFn - The Hotkey built-in, or a stand-in taking Name, Callback, Options.
 * @param {Func} HotIfFn - The HotIf built-in, or a stand-in taking an optional Criterion.
 * @returns {Integer} Number of hotkeys registered.
 * @throws {Error} On a second registration or a key the registry does not know.
 */
KeylayoutEmulation_SourceLoad(Model, Registry, HotkeyFn := Hotkey, HotIfFn := HotIf) {
	global KLE_SourceSession, KLE_SourceScans, KLE_SourceRegistered
	if KLE_SourceRegistered
		throw Error("The layout source emulation is already registered.")
	Scans := Map()
	for Code, Key in Registry["keys"]
		if Key.Get("kind", "") == "key" && Key.Get("ahk", 0) is String
			Scans[Code] := StrUpper(Key["ahk"])
	Codes := SourceEmulation_Keys(Model)
	; An emulated layer types nothing on the keys it does not map: it takes them all.
	if SourceEmulation_HasEmulatedLayer(Model)
		for Code, Key in Registry["keys"]
			if Key.Get("group", "") == "alphanumeric" && Scans.Has(Code)
				Codes[Code] := true
	Taken := []
	for Code in Codes {
		if _KLE_SourceUntaken().Has(Code)
			continue
		if !Scans.Has(Code)
			throw Error("The layout source emulation names the unknown key " . Code . ".")
		Taken.Push(Code)
	}
	KLE_SourceScans := Scans
	KLE_SourceSession := SourceEmulation_NewSession(Model)
	KLE_SourceRegistered := true
	Count := 0
	HotIfFn.Call(_KLE_SourceCriterion)
	try {
		for Code in Taken {
			Sc := Scans[Code]
			for Name in _KLE_SourceHotkeyNames(Sc)
				HotkeyFn.Call(Name, _KLE_SourceOnPress.Bind(Code, Sc), "I0"), Count += 1
			HotkeyFn.Call("*" . Sc . " up", _KLE_SourceOnRelease.Bind(Code, Sc), "I0"), Count += 1
		}
	} finally HotIfFn.Call()
	return Count
}

; Reads, compiles and registers the composed layout's emulation table, when the
; source form stored one (composer_emulate or composer_save with a source).
_KLE_SourceBoot(ConfigDir, Deps) {
	global _SharedDir
	try {
		Table := Deps.Get("read_emulation", LayoutComposer_ReadEmulation).Call(ConfigDir)
		if !(Table is Map)
			return 0
		Model := SourceEmulation_Compile(Table)
		if !SourceEmulation_HasRecords(Model)
			return 0
		Registry := Deps.Has("physical_keys") ? Deps["physical_keys"]
			: JsonParse(FSReadStrict(_SharedDir . "\data\keycodes\physical_keys.json"))
		Count := KeylayoutEmulation_SourceLoad(Model, Registry, Deps.Get("source_hotkey", Hotkey),
			Deps.Get("source_hotif", HotIf))
	} catch as Err {
		LoggerError("LayoutEmulation", "The layout source emulation table is not performed: {1}", Err.Message)
		return 0
	}
	LoggerInfo("LayoutEmulation", "Registered {1} hotkeys of the layout source emulation.", Count)
	return Count
}

/** Drops the source emulation's state, for a test or a stop. */
KeylayoutEmulation_SourceUnload() {
	global KLE_SourceSession, KLE_SourceScans, KLE_SourceRegistered
	KLE_SourceSession := 0
	KLE_SourceScans := Map()
	KLE_SourceRegistered := false
}

_KLE_SourceCriterion(*) {
	global KLE_SourceSession
	return (KLE_SourceSession is Map) && !A_IsSuspended
}

/**
 * The built-in modifiers held now, as the engine names them.
 * @param {Func} StateFn - GetKeyState, or a stand-in for a test.
 * @returns {Map}
 */
KeylayoutEmulation_SourceHeld(StateFn := GetKeyState) {
	Held := Map()
	if StateFn.Call("LShift", "P") || StateFn.Call("RShift", "P")
		Held["shift"] := true
	if StateFn.Call("LControl", "P") || StateFn.Call("RControl", "P")
		Held["control"] := true
	if StateFn.Call("LAlt", "P")
		Held["alt"] := true
	if StateFn.Call("RAlt", "P")
		Held["alt_right"] := true
	if StateFn.Call("LWin", "P") || StateFn.Call("RWin", "P")
		Held["meta"] := true
	if StateFn.Call("CapsLock", "T")
		Held["caps_lock"] := true
	return Held
}

/**
 * What one engine action sends: the text to type, or the Send keys of a key or
 * modifier action. Key actions release the hand's modifiers and press only
 * theirs, as the macOS and Linux drivers post them.
 * @param {Map} Action - From SourceEmulation_Press.
 * @param {Map} Scans - KeyboardEvent.code -> scan code name.
 * @returns {Map} "text" or "keys".
 */
KeylayoutEmulation_SourceSend(Action, Scans) {
	static Prefixes := Map("shift", "+", "shift_left", "<+", "shift_right", ">+", "control", "^",
		"control_left", "<^", "control_right", ">^", "alt", "!", "alt_left", "<!", "alt_right", ">!",
		"meta", "#", "meta_left", "<#", "meta_right", ">#")
	static Keys := Map("shift", "LShift", "shift_left", "LShift", "shift_right", "RShift",
		"control", "LControl", "control_left", "LControl", "control_right", "RControl",
		"alt", "LAlt", "alt_left", "LAlt", "alt_right", "RAlt", "meta", "LWin", "meta_left", "LWin",
		"meta_right", "RWin")
	switch Action["type"] {
		case "text":
			return Map("text", Action["text"])
		case "key":
			if !Scans.Has(Action["key"])
				throw Error("The layout source emulation sends the unknown key " . Action["key"] . ".")
			Prefix := ""
			for Id in Action["modifiers"]
				if Prefixes.Has(Id) && !InStr(Prefix, Prefixes[Id])
					Prefix .= Prefixes[Id]
			return Map("keys", Prefix . "{" . Scans[Action["key"]] . "}")
		case "modifier":
			if !Keys.Has(Action["id"])
				throw Error("The layout source emulation holds the unknown modifier " . Action["id"] . ".")
			return Map("keys", "{" . Keys[Action["id"]] . (Action["down"] ? " down}" : " up}"))
	}
	throw Error("The layout source emulation returned an unknown action.")
}

; Performs the engine's actions in order: text through the driver's text
; sender, keys at SendLevel 1 so the layout emulation below interprets them.
_KLE_SourcePerform(Actions) {
	global KLE_SourceScans
	for Action in Actions {
		Emitted := KeylayoutEmulation_SourceSend(Action, KLE_SourceScans)
		if Emitted.Has("text") {
			SendNewResult(Emitted["text"])
			continue
		}
		SendLevel(1)
		SendEvent(Emitted["keys"])
	}
}

; A tap-hold whose threshold passes starts its hold without waiting for a key.
_KLE_SourceArmTick() {
	global KLE_SourceSession
	Delay := (KLE_SourceSession is Map) ? SourceEmulation_PendingDelay(KLE_SourceSession, A_TickCount) : 0
	if Delay > 0
		SetTimer(_KLE_SourceTick, -Delay)
}

_KLE_SourceTick() {
	global KLE_SourceSession
	if !(KLE_SourceSession is Map)
		return
	_AtCrit := Critical("On")
	try {
		; A timer still runs while the driver is paused: release what the engine holds.
		Actions := A_IsSuspended ? SourceEmulation_Reset(KLE_SourceSession)
			: SourceEmulation_Tick(KLE_SourceSession, A_TickCount)
		_KLE_SourcePerform(Actions)
	} finally Critical(_AtCrit)
}

_KLE_SourceOnPress(Code, Sc, *) {
	global KLE_SourceSession
	_AtCrit := Critical("On")
	try {
		Result := SourceEmulation_Press(KLE_SourceSession, Code, KeylayoutEmulation_SourceHeld(), A_TickCount)
		_KLE_SourcePerform(Result["actions"])
		if !Result["consumed"] {
			SendLevel(1)
			SendEvent("{Blind}{" . Sc . " down}")
		}
	} finally Critical(_AtCrit)
	_KLE_SourceArmTick()
}

_KLE_SourceOnRelease(Code, Sc, *) {
	global KLE_SourceSession
	_AtCrit := Critical("On")
	try {
		Result := SourceEmulation_Release(KLE_SourceSession, Code, A_TickCount)
		_KLE_SourcePerform(Result["actions"])
		if !Result["consumed"] {
			SendLevel(1)
			SendEvent("{Blind}{" . Sc . " up}")
		}
	} finally Critical(_AtCrit)
}