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
global KLE_ALTGR_SC := "SC138"

global KLE_INPUT_LEVEL := "I2"
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
; "s|c|o" flags (Shift, CapsLock, Option) -> keyMap index, plus "command".
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
	if !FeaturesSource.Has("layout") || !FeaturesSource["layout"].Has("emulated_layout")
		return ""
	Id := FeaturesSource["layout"]["emulated_layout"]
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
	return KeylayoutEmulation_LayerIsActive("ergopti_base") && !_KLE_DigitsOwnKey(Sc, Shift, ForegroundFn)
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
		&& Features["hotstrings"]["magic_key"]["replace"]["enabled"]
}

_KLE_DigitsOwnKey(Sc, Shift, ForegroundFn := 0) {
	global Features, _SHIFT_DIGIT_SCS
	if NumberRowEffectiveMode() != "digits"
		return false
	if Shift {
		Hkl := IsObject(ForegroundFn) ? ForegroundFn.Call() : GetForegroundKeyboardLayout()
		Code := Integer("0x" . SubStr(Sc, 3))
		return _SHIFT_DIGIT_SCS.Has(Sc) && _DigitRowSwapResolution(Code, Hkl)["swap"]
	}
	Code := Integer("0x" . SubStr(Sc, 3))
	return _SHIFT_DIGIT_SCS.Has(Sc) || ErgoptiNumberRowEdgeMapping().Has(Code)
}

/**
 * Resolves the effective base/Shift descriptors without advancing dead-key state.
 * @param {Integer} Sc Physical Windows scan code.
 * @param {Boolean} Caps CapsLock state of the effective source.
 * @returns {Map|Integer} Plain and Shift descriptors, or 0 if native input owns base.
 */
KeylayoutEmulation_NumberRowLevels(Sc, Caps) {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex
	if !KeylayoutEmulation_LayerIsActive("ergopti_base")
		return 0
	Name := Format("SC{:03X}", Sc)
	if !KLE_KeyCodes.Has(Name)
		return 0
	Code := KLE_KeyCodes[Name]
	return Map(
		"plain", Keylayout_Resolve(KLE_Model, KLE_LevelIndex[_KLE_ComboKey(false, Caps, false)], Code),
		"shift", Keylayout_Resolve(KLE_Model, KLE_LevelIndex[_KLE_ComboKey(true, Caps, false)], Code))
}

_KLE_ShortcutCriterion(*) {
	return KeylayoutEmulation_LayerIsActive("ergopti_base")
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
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions, KEYLAYOUT_NEUTRAL_STATE
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
	; Resolve every key once so a broken action fails here, not on a keystroke.
	for _, Index in LevelIndex
		for _, Code in KeyCodes
			Keylayout_Resolve(Model, Index, Code)
	Compositions := _KLE_BuildCompositions(Model)
	KLE_Model := Model
	KLE_Id := Id
	KLE_State := KEYLAYOUT_NEUTRAL_STATE
	KLE_KeyCodes := KeyCodes
	KLE_LevelIndex := LevelIndex
	KLE_Compositions := Compositions
	return KeyCodes.Count
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
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_Compositions, KEYLAYOUT_NEUTRAL_STATE
	KLE_Model := 0
	KLE_Id := ""
	KLE_State := KEYLAYOUT_NEUTRAL_STATE
	KLE_KeyCodes := Map()
	KLE_Compositions := Map()
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
	if NumberRowEffectiveMode() == "digits" {
		if !Shift && Code >= 0x02 && Code <= 0x0B
			Native := {Count: 1, Text: Mod(Code - 1, 10) . ""}
		else if !Shift && ErgoptiNumberRowEdgeMapping().Has(Code)
			Native := {Count: 1, Text: ErgoptiNumberRowEdgeMapping()[Code]}
		else if Shift && DigitRowIsSwapped(Hkl) && Code >= 0x02 && Code <= 0x0B
			Native := {Count: 1, Text: DigitRowSwapSymbol(Code, Hkl)}
	}
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
 * Character a shortcut chord sends for ``Sc``: the layout's Command level.
 * @param {string} Sc - AHK scan code.
 * @returns {string} One character, or "" when the layout types nothing there
 *   or a dead key (the chord then stays on the physical key).
 */
KeylayoutEmulation_ShortcutChar(Sc) {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex
	if !IsObject(KLE_Model) || !KLE_KeyCodes.Has(Sc)
		return ""
	Resolved := Keylayout_Resolve(KLE_Model, KLE_LevelIndex["command"], KLE_KeyCodes[Sc])
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
		Output := KeylayoutEmulation_Press(Sc, Shift, GetKeyState("CapsLock", "T"), Option)
		if (Output != "")
			SendNewResult(Output)
	} finally {
		Critical(_AtCrit)
	}
}

_KLE_OnKey(Sc, Shift, *) {
	global _SHIFT_DIGIT_SCS
	if NumberRowEffectiveMode() == "symbols" && _SHIFT_DIGIT_SCS.Has(Sc)
			&& NumberRowSymbolsCapable(GetKeyState("CapsLock", "T")) {
		Code := Integer("0x" . SubStr(Sc, 3))
		Level := NumberRowSymbolsLevel(Code, GetKeyState("CapsLock", "T"))
		if Level["supported"] {
			; Walk the same original source action machine, including pending dead
			; keys and repeats. Ctrl/AltGr registrations retain their own levels.
			_KLE_Emit(Sc, Level["shift"] != Shift, false)
			return
		}
	}
	if Shift && _SHIFT_DIGIT_SCS.Has(Sc) {
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
	if KeylayoutEmulation_LayerIsActive("ergopti_base") && !_KLE_DigitsOwnKey(Sc, Shift) {
		_KLE_Emit(Sc, Shift, false)
		return
	}
	_AtCrit := Critical("On")
	try {
		Step := KeylayoutEmulation_PressNative(Sc, Shift, GetKeyState("CapsLock", "T"), GetForegroundKeyboardLayout())
		if Step["Output"] != ""
			SendNewResult(Step["Output"])
		if Step["Native"]
			SendEvent((Shift ? "+" : "") . "{" . Sc . "}")
	} finally {
		Critical(_AtCrit)
	}
}

_KLE_OnAltGr(Sc, *) {
	_KLE_Emit(Sc, GetKeyState("Shift", "P"), true)
}

_KLE_OnShortcut(Sc, Mods, *) {
	Char := KeylayoutEmulation_ShortcutChar(Sc)
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

_KLE_AltGrCriterion(*) {
	return KeylayoutEmulation_LayerIsActive("ergopti_alt_gr") && IsRealAltGrPress()
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
 * @param {Func} HotkeyFn - Hotkey(Name, Callback, Options) implementation.
 * @param {Func} HotIfFn - HotIf(Criterion?) implementation.
 * @param {Func|Integer} ForegroundFn Foreground layout reader; native by default.
 * @returns {Integer} Number of hotkeys registered.
 * @throws {Error} On a second registration.
 */
KeylayoutEmulation_Register(KeycodeTable, HotkeyFn := Hotkey, HotIfFn := HotIf, ForegroundFn := 0,
		BrokerFn := MagicEditorRecordLayoutFallback) {
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
				if Prefix == "#"
					BrokerFn.Call(Sc, _KLE_OnShortcut.Bind(Sc, Prefix), _KLE_ShortcutCriterion)
				else
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





; =======================
; =======================
; ======= 7/ Boot =======
; =======================
; =======================

_KLE_DefaultBootDeps() {
	return Map(
		"keycodes", LayoutRegistry_Keycodes,
		"register", KeylayoutEmulation_Register,
		"read_local", LayoutRegistry_ReadLocal,
		"install", LayoutCatalogue_Install
	)
}

/**
 * Registers the emulation and loads the selected layout, installing it first
 * through the layout catalogue when it is not installed or its copy no longer
 * matches its record. Runs once at boot, before the Ergopti layers register
 * their hotkeys.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @param {Map} Deps - "keycodes", "register", "read_local" and "install"
 *   implementations; injectable for tests.
 * @returns {boolean} Whether the layout is emulated when this returns (false
 *   while it downloads, or when nothing is selected or it failed).
 */
KeylayoutEmulation_Boot(ConfigDir, Deps := 0) {
	if !(Deps is Map)
		Deps := _KLE_DefaultBootDeps()
	Id := KeylayoutEmulation_SelectedId()
	if (Id == "")
		return false
	if !LayoutRegistry_IsValidId(Id) {
		LoggerError("LayoutEmulation", "The emulated layout '{1}' is not a registry id; nothing is emulated.", Id)
		return false
	}
	KeycodeTable := Deps["keycodes"].Call()
	Hotkeys := Deps["register"].Call(KeycodeTable)
	LoggerInfo("LayoutEmulation", "Registered {1} emulation hotkeys for the '{2}' layout.", Hotkeys, Id)
	LocalDir := LayoutRegistry_LocalDir(ConfigDir)
	try {
		LocalCopy := Deps["read_local"].Call(Id, LocalDir)
	} catch as Err {
		LoggerInfo("LayoutEmulation", "The '{1}' layout is not usable locally ({2}); installing it.", Id, Err.Message)
		Deps["install"].Call(Id, LocalDir, _KLE_OnInstalled.Bind(Id, LocalDir, KeycodeTable, Deps))
		return false
	}
	return _KLE_Activate(Id, LocalCopy, KeycodeTable)
}

_KLE_OnInstalled(Id, LocalDir, KeycodeTable, Deps, Ok, Detail*) {
	; LayoutCatalogue_Install already logged the failure and its reason.
	if !Ok
		return
	try {
		LocalCopy := Deps["read_local"].Call(Id, LocalDir)
	} catch as Err {
		LoggerError("LayoutEmulation", "The downloaded '{1}' layout cannot be read back: {2}", Id, Err.Message)
		return
	}
	_KLE_Activate(Id, LocalCopy, KeycodeTable)
}

_KLE_Activate(Id, LocalCopy, KeycodeTable) {
	LoggerStart("LayoutEmulation", "Loading the '{1}' layout for emulation…", Id)
	try {
		Keys := KeylayoutEmulation_Load(Id, LocalCopy["Text"], LocalCopy["Entry"]["keycode_convention"], KeycodeTable)
	} catch as Err {
		KeylayoutEmulation_Unload()
		LoggerError("LayoutEmulation", "The '{1}' layout is not emulated: {2}", Id, Err.Message)
		return false
	}
	LoggerSuccess("LayoutEmulation", "Emulating the '{1}' layout, version {2} ({3} keys).",
		Id, LocalCopy["Entry"]["version"], Keys)
	return true
}
