; modules/keymap/keylayout/keylayout_tables.ahk

; ==============================================================================
; MODULE: .keylayout Level Tables
; DESCRIPTION:
; Turns a parsed .keylayout (keylayout_parser.ahk) into the tables a
; character-based emulation types from: what every key types on the base,
; Shift, CapsLock, AltGr and AltGr+Shift levels, and for every dead-key state
; which character typed after the dead key gives which result.
;
; FEATURES & RATIONALE:
; 1. Pure and layout-agnostic: no file, hotkey or global state, and nothing
;    specific to one layout. The Ergopti emulation builds its layers from these
;    tables (modules/keymap/layout/layout_ergopti.ahk); any registry layout
;    can be read the same way.
; 2. Built once, when a layout is loaded or changed, never on the typing path.
; 3. Dead-key tables are keyed by the character the following key types on its
;    own, the form a character-based dead-key handler receives. A key that is
;    itself a dead key is named by what it types alone (its terminator), which
;    is what the emulation sends when a dead key is pressed inside a sequence.
; 4. Fail fast: two keys typing the same character with different results in
;    one dead-key state make the character-keyed table ambiguous, so the build
;    throws instead of keeping either.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================
; =============================
; ======= 1/ Vocabulary =======
; =============================
; =============================

; Levels a character-based emulation types through, as the modifiers the
; layout's modifierMap receives. Caps+Shift and Caps+AltGr are not levels of
; their own on Windows: Shift and AltGr hotkeys take precedence over CapsLock.
global KEYLAYOUT_TABLE_LEVELS := Map(
	"base", [],
	"shift", ["shift"],
	"caps", ["caps"],
	"altgr", ["option"],
	"altgr_shift", ["option", "shift"]
)

; Order in which the levels are read when a dead-key table is built, so the
; result does not depend on Map enumeration.
global KEYLAYOUT_TABLE_LEVEL_ORDER := ["base", "shift", "caps", "altgr", "altgr_shift"]





; =========================
; =========================
; ======= 2/ Levels =======
; =========================
; =========================

/**
 * keyMap index of every emulated level.
 * @param {Map} Model - Parsed layout.
 * @returns {Map} Level name -> keyMap index.
 */
KeylayoutTables_LevelIndexes(Model) {
	global KEYLAYOUT_TABLE_LEVELS
	Indexes := Map()
	for Level, Modifiers in KEYLAYOUT_TABLE_LEVELS {
		Pressed := Map()
		for Name in Modifiers
			Pressed[Name] := true
		Indexes[Level] := Keylayout_KeyMapIndex(Model, Pressed)
	}
	return Indexes
}

/**
 * What every key types on every level, from the neutral state.
 * @param {Map} Model - Parsed layout.
 * @param {Map} KeyCodes - AHK scan code ("SC010") -> macOS key code.
 * @returns {Map} Level -> Map(scan code -> Map("Kind", "text"|"dead",
 *   "Text", output or what the dead key types alone, "State", dead-key state
 *   or "")). A key that types nothing on a level is absent from that level.
 */
KeylayoutTables_Levels(Model, KeyCodes) {
	Levels := Map()
	for Level, Index in KeylayoutTables_LevelIndexes(Model) {
		Keys := Map()
		for Sc, Code in KeyCodes {
			Resolved := Keylayout_Resolve(Model, Index, Code)
			if (Resolved["Kind"] == "none")
				continue
			Keys[Sc] := Map("Kind", Resolved["Kind"], "Text", Resolved["Text"], "State", Resolved["State"])
		}
		Levels[Level] := Keys
	}
	return Levels
}





; ============================
; ============================
; ======= 3/ Dead keys =======
; ============================
; ============================

_KLTables_AddDeadInput(Inputs, State, InputChar, Result) {
	if !Inputs.Has(InputChar) {
		Inputs[InputChar] := Result
		return
	}
	Known := Inputs[InputChar]
	if (Known["Output"] !== Result["Output"] || Known["Next"] !== Result["Next"])
		throw ValueError("Two keys typing the same character compose differently in a dead-key state.",
			-1, State . " + " . InputChar)
}

/**
 * Character-keyed dead-key tables.
 * @param {Map} Model - Parsed layout.
 * @param {Map} KeyCodes - AHK scan code -> macOS key code.
 * @returns {Map} State -> Map("Terminator", what the dead key types alone,
 *   "Inputs", Map(character typed after it -> Map("Output", text, "Next",
 *   chained state or ""))).
 * @throws {ValueError} When one character composes two different ways.
 */
KeylayoutTables_DeadKeys(Model, KeyCodes) {
	global KEYLAYOUT_TABLE_LEVEL_ORDER, KEYLAYOUT_NEUTRAL_STATE
	Tables := Map()
	for State, Terminator in Model["Terminators"]
		Tables[State] := Map("Terminator", Terminator, "Inputs", Map())
	Indexes := KeylayoutTables_LevelIndexes(Model)
	for Level in KEYLAYOUT_TABLE_LEVEL_ORDER {
		Index := Indexes[Level]
		for Sc, Code in KeyCodes {
			Entry := Keylayout_KeyEntry(Model, Index, Code)
			if !IsObject(Entry) || (Entry["Kind"] != "action")
				continue
			Resolved := Keylayout_Resolve(Model, Index, Code)
			if (Resolved["Kind"] == "none")
				continue
			for State, When in Model["Actions"][Entry["Value"]] {
				if (State == KEYLAYOUT_NEUTRAL_STATE)
					continue
				if !Tables.Has(State)
					throw ValueError("A .keylayout action composes in a dead-key state that has no terminator.", -1, State)
				Output := Keylayout_IsPrintable(When["Output"]) ? When["Output"] : ""
				_KLTables_AddDeadInput(Tables[State]["Inputs"], State, Resolved["Text"],
					Map("Output", Output, "Next", When["Next"]))
			}
		}
	}
	return Tables
}

/**
 * Levels and dead-key tables of a parsed layout.
 * @param {Map} Model - Parsed layout.
 * @param {Map} KeyCodes - AHK scan code -> macOS key code.
 * @returns {Map} "Levels" and "DeadKeys", as the two functions above return them.
 */
KeylayoutTables_Build(Model, KeyCodes) {
	return Map(
		"Levels", KeylayoutTables_Levels(Model, KeyCodes),
		"DeadKeys", KeylayoutTables_DeadKeys(Model, KeyCodes)
	)
}
