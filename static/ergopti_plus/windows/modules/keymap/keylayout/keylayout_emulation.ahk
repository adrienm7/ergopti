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
; 4. A selected registry layout supersedes the Ergopti emulation:
;    ApplyMasterGatesToFeatures (infra/master_gates.ahk) turns the Ergopti
;    layout features off in memory, on every path that rebuilds Features.
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
global KLE_DEAD_RESET_KEYS := ["BackSpace", "Escape", "Enter", "Tab", "Delete",
	"Left", "Right", "Up", "Down", "Home", "End", "PgUp", "PgDn"]

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
global KLE_Registered := false





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
	; The Layout master gate turns every layout feature to false in memory.
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
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KEYLAYOUT_NEUTRAL_STATE
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
	KLE_Model := Model
	KLE_Id := Id
	KLE_State := KEYLAYOUT_NEUTRAL_STATE
	KLE_KeyCodes := KeyCodes
	KLE_LevelIndex := LevelIndex
	return KeyCodes.Count
}

/**
 * Stops emulating: drops the model so every emulation hotkey stands down.
 */
KeylayoutEmulation_Unload() {
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KEYLAYOUT_NEUTRAL_STATE
	KLE_Model := 0
	KLE_Id := ""
	KLE_State := KEYLAYOUT_NEUTRAL_STATE
	KLE_KeyCodes := Map()
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
	Index := KLE_LevelIndex[_KLE_ComboKey(Shift, Caps, Option)]
	Step := Keylayout_Step(KLE_Model, KLE_State, Index, KLE_KeyCodes[Sc])
	KLE_State := Step["Next"]
	return Step["Output"]
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
	KLE_State := KEYLAYOUT_NEUTRAL_STATE
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
	_KLE_Emit(Sc, Shift, false)
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
	return KeylayoutEmulation_IsActive() && IsRealAltGrPress()
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
 * @returns {Integer} Number of hotkeys registered.
 * @throws {Error} On a second registration.
 */
KeylayoutEmulation_Register(KeycodeTable, HotkeyFn := Hotkey, HotIfFn := HotIf) {
	global KLE_Registered, KLE_SHORTCUT_PREFIXES, KLE_NATIVE_CHORD_KEYS
	global KLE_DEAD_RESET_KEYS, KLE_ALTGR_SC, KLE_INPUT_LEVEL, KLE_ALT_INPUT_LEVEL
	if KLE_Registered
		throw Error("The layout emulation hotkeys are already registered.")
	ScanCodes := []
	for Key in KeycodeTable["keys"]
		ScanCodes.Push(Key["ahk"])
	Count := 0
	; HotIf is process-wide: a timer thread registering another layer must not
	; interleave with this sequence, and the criterion is reset even on a throw.
	_AtCrit := Critical("On")
	try {
		HotIfFn.Call(KeylayoutEmulation_IsActive)
		for Sc in ScanCodes {
			HotkeyFn.Call(Sc, _KLE_OnKey.Bind(Sc, false), KLE_INPUT_LEVEL)
			HotkeyFn.Call("+" . Sc, _KLE_OnKey.Bind(Sc, true), KLE_INPUT_LEVEL)
			Count += 2
			if KLE_NATIVE_CHORD_KEYS.Has(Sc)
				continue
			for Prefix in KLE_SHORTCUT_PREFIXES {
				Level := (SubStr(Prefix, 1, 1) == "!") ? KLE_ALT_INPUT_LEVEL : KLE_INPUT_LEVEL
				HotkeyFn.Call(Prefix . Sc, _KLE_OnShortcut.Bind(Sc, Prefix), Level)
				Count += 1
			}
		}
		HotIfFn.Call(_KLE_AltGrCriterion)
		for Sc in ScanCodes {
			HotkeyFn.Call(KLE_ALTGR_SC . " & " . Sc, _KLE_OnAltGr.Bind(Sc), KLE_INPUT_LEVEL)
			Count += 1
		}
		HotIfFn.Call(_KLE_PendingDeadKeyCriterion)
		for Key in KLE_DEAD_RESET_KEYS {
			HotkeyFn.Call("~" . Key, KeylayoutEmulation_ResetDeadKey, KLE_INPUT_LEVEL)
			Count += 1
		}
	} finally {
		HotIfFn.Call()
		Critical(_AtCrit)
	}
	KLE_Registered := true
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
		"fetch", LayoutRegistry_Fetch
	)
}

/**
 * Registers the emulation and loads the selected layout, downloading it first
 * when it is not in the local folder or no longer matches its index. Runs once
 * at boot, before the Ergopti layers register their hotkeys.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @param {Map} Deps - "keycodes", "register", "read_local" and "fetch"
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
		LoggerInfo("LayoutEmulation", "The '{1}' layout is not usable locally ({2}); downloading it.", Id, Err.Message)
		Deps["fetch"].Call(Id, LocalDir, _KLE_OnFetched.Bind(Id, LocalDir, KeycodeTable, Deps))
		return false
	}
	return _KLE_Activate(Id, LocalCopy, KeycodeTable)
}

_KLE_OnFetched(Id, LocalDir, KeycodeTable, Deps, Ok, Detail) {
	; LayoutRegistry_Fetch already logged the failure and its reason.
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
