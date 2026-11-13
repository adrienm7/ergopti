; modules/keymap/keylayout/source_emulation.ahk

; ==============================================================================
; MODULE: Layout Source Emulation Engine (Windows)
; DESCRIPTION:
; Performs the records of an Ergopti layout source that no .keylayout holds:
; custom modifiers (held or locked) and the layers they select, key-chord
; mappings, shortcuts sending another key, tap-holds and remaps of system keys.
; It reads the emulation table the one source compiler writes
; (_shared/ui/layout_composer/source_compiler.js, compileEmulation) and is the
; AutoHotkey port of _shared/layouts/engine/composer/source_emulation.lua: every driver and
; the web emulation replay the same vectors
; (_shared/tests/corpus/layouts/source/emulation_vectors.json).
;
; FEATURES & RATIONALE:
; 1. Pure: no hotkey, no file, no clock. The caller passes the press time in
;    milliseconds and performs the returned actions in order
;    (keylayout_emulation.ahk owns the hotkeys and the sends).
; 2. TN2056 selection: the first layer whose selector the held modifiers match
;    wins, a required modifier must be held and every held one must be allowed;
;    an unsided id (alt) matches either side, two sides never match. An
;    emulated layer types nothing on a key it does not map.
; 3. Tap-holds follow the shared typing rule: a press under a pending key
;    before its threshold types the tap first, a press after it, or the
;    threshold passing (tick), starts the hold.
; 4. Fail fast: a table of another format or version, or one naming an
;    undeclared layer or modifier, throws at compile time, never on a key.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

/**
 * The table format and version the engine performs.
 * @param {String} Name - "format" or "version".
 * @returns {String|Integer}
 */
SourceEmulation_Contract(Name) {
	switch Name {
		case "format": return "ergopti-layout-emulation"
		case "version": return 1
	}
	throw ValueError("Unknown source emulation contract field.", -1, Name)
}

/**
 * The built-in modifiers a driver reports, in the order key actions name them.
 * @returns {Array}
 */
SourceEmulation_Reported() {
	static Reported := ["shift", "control", "alt", "alt_right", "meta", "caps_lock"]
	return Reported
}

; The layout table field that lists tap-hold keys. It is a field of the emulation table,
; not the [tap_holds] configuration section that shares its spelling.
_SrcEmu_TapHoldsField() {
	return "tap_holds" ; config-key-literal-ok
}

; The built-in modifiers that have a left and a right key.
_SrcEmu_Sided() {
	static Sided := Map("shift", true, "control", true, "alt", true, "meta", true)
	return Sided
}





; ===========================
; ===========================
; ======= 2/ Matching =======
; ===========================
; ===========================

; The modifier family of an id: shift for shift_left and shift_right. A custom
; id is its own family, whatever its spelling.
_SrcEmu_Family(Id) {
	if RegExMatch(Id, "^(.*?)_(left|right)$", &Match) && _SrcEmu_Sided().Has(Match[1])
		return Match[1]
	return Id
}

; Whether a selector modifier id stands for a held one.
_SrcEmu_Covers(Spec, Held) {
	if Spec == Held
		return true
	if _SrcEmu_Family(Spec) != _SrcEmu_Family(Held)
		return false
	return _SrcEmu_Family(Spec) == Spec || _SrcEmu_Family(Held) == Held
}

_SrcEmu_AnyCovers(List, Held) {
	for Spec in List
		if _SrcEmu_Covers(Spec, Held)
			return true
	return false
}

/**
 * Whether a selector matches the held modifier ids exactly (TN2056).
 * @param {Map} Selector - "required" and "optional" Arrays of ids.
 * @param {Array} Pressed - The held modifier ids.
 * @returns {Boolean}
 */
SourceEmulation_SelectorMatches(Selector, Pressed) {
	for Required in Selector["required"] {
		Held := false
		for Id in Pressed {
			if _SrcEmu_Covers(Required, Id) {
				Held := true
				break
			}
		}
		if !Held
			return false
	}
	for Id in Pressed
		if !_SrcEmu_AnyCovers(Selector["required"], Id) && !_SrcEmu_AnyCovers(Selector["optional"], Id)
			return false
	return true
}





; ==============================
; ==============================
; ======= 3/ Compilation =======
; ==============================
; ==============================

; Checks one mapping of the table and copies it.
_SrcEmu_MappingOf(Value, Where) {
	if Value is Map {
		if Value.Get("text", 0) is String
			return Map("text", Value["text"])
		if Value.Get("key", 0) is String {
			Modifiers := []
			if Value.Get("modifiers", 0) is Array
				for Id in Value["modifiers"]
					Modifiers.Push(Id)
			return Map("key", Value["key"], "modifiers", Modifiers)
		}
		if Value.Get("disabled", "") == 1
			return Map("disabled", true)
	}
	throw Error("The emulation table holds a malformed mapping at " . Where . ".")
}

; Copies an array of modifier ids, refusing an undeclared one.
_SrcEmu_IdsOf(List, Known, Where) {
	if !(List is Array)
		throw Error("The emulation table holds no modifier list at " . Where . ".")
	Out := []
	for Id in List {
		if !(Id is String) || !Known.Call(Id)
			throw Error("The emulation table names the unknown modifier '" . String(Id) . "' at " . Where . ".")
		Out.Push(Id)
	}
	return Out
}

_SrcEmu_List(Table, Name) {
	Value := Table.Get(Name, [])
	if !(Value is Array)
		throw Error("The emulation table holds a malformed " . Name . " list.")
	return Value
}

/**
 * Compiles a decoded emulation table into the lookups the key path walks.
 * @param {Map} Table - The decoded JSON of compileEmulation.
 * @returns {Map} The model.
 * @throws {Error} On any malformed or inconsistent record.
 */
SourceEmulation_Compile(Table) {
	if !(Table is Map) || Table.Get("format", "") != SourceEmulation_Contract("format")
			|| !(Table.Get("version", "") is Integer) || Table["version"] != SourceEmulation_Contract("version")
		throw Error("The layout emulation table is not an " . SourceEmulation_Contract("format") . " version "
			. SourceEmulation_Contract("version") . " table.")
	Model := Map("layout", Table.Get("layout", ""), "modifier_keys", Map(), "custom", Map(), "layers", [],
		"layer_by_id", Map(), "shortcuts", [], _SrcEmu_TapHoldsField(), Map(), "remaps", Map())
	for Modifier in _SrcEmu_List(Table, "modifiers") {
		if !(Modifier is Map) || !(Modifier.Get("id", 0) is String)
				|| (Modifier.Get("mode", "") != "held" && Modifier.Get("mode", "") != "locked")
			throw Error("The emulation table holds a malformed custom modifier.")
		Model["custom"][Modifier["id"]] := Modifier["mode"]
		for Key in _SrcEmu_List(Modifier, "keys") {
			if Model["modifier_keys"].Has(Key)
				throw Error("Two custom modifiers share the key " . Key . ".")
			Model["modifier_keys"][Key] := Map("id", Modifier["id"], "mode", Modifier["mode"])
		}
	}
	; Kana is a built-in no driver reports: the targets compile its layers to
	; their native AltGr level, so a selector naming it never matches here.
	Known(Id) {
		for Reported in SourceEmulation_Reported()
			if Reported == Id
				return true
		return Id == "kana" || Model["custom"].Has(Id) || _SrcEmu_Sided().Has(_SrcEmu_Family(Id))
	}
	for Index, Layer in _SrcEmu_List(Table, "layers") {
		if !(Layer is Map) || !(Layer.Get("id", 0) is String) || !(Layer.Get("selectors", 0) is Array)
				|| !(Layer.Get("keys", 0) is Map)
			throw Error("The emulation table holds a malformed layer.")
		Selectors := []
		for Position, Selector in Layer["selectors"] {
			Where := "layers[" . Index . "].selectors[" . Position . "]"
			if !(Selector is Map)
				throw Error("The emulation table holds no modifier list at " . Where . ".")
			Selectors.Push(Map("required", _SrcEmu_IdsOf(Selector.Get("required", 0), Known, Where),
				"optional", _SrcEmu_IdsOf(Selector.Get("optional", 0), Known, Where)))
		}
		Keys := Map()
		for Code, Value in Layer["keys"]
			Keys[Code] := _SrcEmu_MappingOf(Value, "layers." . Layer["id"] . "." . Code)
		Native := Layer.Get("native", 0)
		Selectable := Layer.Get("selectable", 1)
		Compiled := Map("id", Layer["id"], "native", (Native is Integer) && Native == 1,
			"selectable", !((Selectable is Integer) && Selectable == 0), "selectors", Selectors, "keys", Keys)
		Model["layers"].Push(Compiled)
		Model["layer_by_id"][Layer["id"]] := Compiled
	}
	for Index, Shortcut in _SrcEmu_List(Table, "shortcuts") {
		Where := "shortcuts[" . Index . "]"
		if !(Shortcut is Map) || !(Shortcut.Get("key", 0) is String) || !(Shortcut.Get("send_key", 0) is String)
			throw Error("The emulation table holds a malformed shortcut at " . Where . ".")
		Model["shortcuts"].Push(Map("key", Shortcut["key"],
			"modifiers", _SrcEmu_IdsOf(Shortcut.Get("modifiers", 0), Known, Where),
			"send_key", Shortcut["send_key"],
			"send_modifiers", _SrcEmu_IdsOf(Shortcut.Get("send_modifiers", 0), Known, Where)))
	}
	for Index, Entry in _SrcEmu_List(Table, _SrcEmu_TapHoldsField()) {
		Where := "tap_holds[" . Index . "]"
		Threshold := (Entry is Map) ? Entry.Get("threshold_ms", 0) : 0
		if !(Entry is Map) || !(Entry.Get("key", 0) is String) || !(Threshold is Integer) || Threshold <= 0
			throw Error("The emulation table holds a malformed tap-hold at " . Where . ".")
		if Entry.Has("hold_layer") == Entry.Has("hold_modifier")
			throw Error("A tap-hold of the emulation table needs one hold at " . Where . ".")
		if Entry.Has("hold_layer") && !Model["layer_by_id"].Has(Entry["hold_layer"])
			throw Error("A tap-hold holds the unknown layer '" . String(Entry["hold_layer"]) . "'.")
		if Entry.Has("hold_modifier") && !((Entry["hold_modifier"] is String) && Known(Entry["hold_modifier"]))
			throw Error("A tap-hold holds the unknown modifier '" . String(Entry["hold_modifier"]) . "'.")
		if Model[_SrcEmu_TapHoldsField()].Has(Entry["key"]) || Model["modifier_keys"].Has(Entry["key"])
			throw Error("The key " . Entry["key"] . " has two roles in the emulation table.")
		Model[_SrcEmu_TapHoldsField()][Entry["key"]] := Map("key", Entry["key"],
			"tap", _SrcEmu_MappingOf(Entry.Get("tap", 0), Where . ".tap"),
			"hold_layer", Entry.Get("hold_layer", ""), "hold_modifier", Entry.Get("hold_modifier", ""),
			"threshold_ms", Threshold)
	}
	for Remap in _SrcEmu_List(Table, "remaps") {
		if !(Remap is Map) || !(Remap.Get("key", 0) is String) || !(Remap.Get("to", 0) is String)
			throw Error("The emulation table holds a malformed remap.")
		Model["remaps"][Remap["key"]] := Remap["to"]
	}
	return Model
}

/**
 * Whether a compiled table does anything a .keylayout does not.
 * @param {Map} Model - From SourceEmulation_Compile.
 * @returns {Boolean}
 */
SourceEmulation_HasRecords(Model) {
	if Model["modifier_keys"].Count || Model[_SrcEmu_TapHoldsField()].Count || Model["remaps"].Count
			|| Model["shortcuts"].Length
		return true
	for Layer in Model["layers"]
		if Layer["keys"].Count
			return true
	return false
}

/**
 * Every physical key (KeyboardEvent.code) the table gives a role, so the host
 * registers a hotkey on each: modifier, tap-hold, shortcut, remap and layer keys.
 * @param {Map} Model - From SourceEmulation_Compile.
 * @returns {Map} Code -> true.
 */
SourceEmulation_Keys(Model) {
	Codes := Map()
	for Code in Model["modifier_keys"]
		Codes[Code] := true
	for Code in Model[_SrcEmu_TapHoldsField()]
		Codes[Code] := true
	for Code in Model["remaps"]
		Codes[Code] := true
	for Shortcut in Model["shortcuts"]
		Codes[Shortcut["key"]] := true
	for Layer in Model["layers"]
		for Code in Layer["keys"]
			Codes[Code] := true
	return Codes
}

/**
 * Whether one of the layers is emulated (no keyMap of the OS behind it): such a
 * layer types nothing on the keys it does not map, so the host takes every key.
 * @param {Map} Model - From SourceEmulation_Compile.
 * @returns {Boolean}
 */
SourceEmulation_HasEmulatedLayer(Model) {
	for Layer in Model["layers"]
		if !Layer["native"]
			return true
	return false
}





; ==========================
; ==========================
; ======= 4/ Session =======
; ==========================
; ==========================

/**
 * Starts performing a compiled table.
 * @param {Map} Model - From SourceEmulation_Compile.
 * @returns {Map} The session.
 */
SourceEmulation_NewSession(Model) {
	if !(Model is Map) || !(Model.Get("layers", 0) is Array)
		throw Error("A session needs a compiled table.")
	return Map("model", Model, "active", Map(), "held_keys", Map(), "pending", 0, "hold", 0)
}

; The modifier ids held now: the driver's built-ins, then the active customs.
_SrcEmu_PressedIds(Session, Held) {
	Pressed := []
	for Id in SourceEmulation_Reported()
		if Held.Get(Id, false)
			Pressed.Push(Id)
	for Id in Session["active"]
		Pressed.Push(Id)
	return Pressed
}

; The built-in modifiers a key action keeps from the hand (Caps Lock is a lock).
_SrcEmu_HeldModifiers(Held) {
	Out := []
	for Id in SourceEmulation_Reported()
		if Id != "caps_lock" && Held.Get(Id, false)
			Out.Push(Id)
	return Out
}

_SrcEmu_Perform(Mapping, Actions) {
	if Mapping.Has("text")
		Actions.Push(Map("type", "text", "text", Mapping["text"]))
	else if Mapping.Has("key")
		Actions.Push(Map("type", "key", "key", Mapping["key"], "modifiers", Mapping["modifiers"].Clone()))
}

_SrcEmu_StartHold(Session, Actions) {
	Entry := Session["pending"]["entry"]
	Session["hold"] := Map("entry", Entry, "code", Session["pending"]["code"])
	Session["pending"] := 0
	if Entry["hold_modifier"] != "" {
		if Session["model"]["custom"].Has(Entry["hold_modifier"])
			Session["active"][Entry["hold_modifier"]] := true
		else
			Actions.Push(Map("type", "modifier", "id", Entry["hold_modifier"], "down", true))
	}
}

_SrcEmu_EndHold(Session, Actions) {
	Entry := Session["hold"]["entry"]
	Session["hold"] := 0
	if Entry["hold_modifier"] != "" {
		if Session["model"]["custom"].Has(Entry["hold_modifier"])
			Session["active"].Delete(Entry["hold_modifier"])
		else
			Actions.Push(Map("type", "modifier", "id", Entry["hold_modifier"], "down", false))
	}
}

; Settles a pending tap-hold before another key: the tap before its threshold,
; the hold from it on.
_SrcEmu_Settle(Session, Now, Actions) {
	Pending := Session["pending"]
	if !(Pending is Map)
		return
	if Now - Pending["at"] < Pending["entry"]["threshold_ms"] {
		Session["pending"] := 0
		_SrcEmu_Perform(Pending["entry"]["tap"], Actions)
	} else {
		_SrcEmu_StartHold(Session, Actions)
	}
}

; The layer a press types on: a running layer hold, else the first match.
_SrcEmu_SelectedLayer(Session, Pressed) {
	Hold := Session["hold"]
	if (Hold is Map) && Hold["entry"]["hold_layer"] != ""
		return Session["model"]["layer_by_id"][Hold["entry"]["hold_layer"]]
	for Layer in Session["model"]["layers"] {
		if !Layer["selectable"]
			continue
		for Selector in Layer["selectors"]
			if SourceEmulation_SelectorMatches(Selector, Pressed)
				return Layer
	}
	return 0
}

; The shortcut a press of Code matches, Caps Lock ignored unless named.
_SrcEmu_ShortcutFor(Session, Code, Pressed) {
	for Shortcut in Session["model"]["shortcuts"] {
		if Shortcut["key"] != Code
			continue
		NamesCaps := false
		for Id in Shortcut["modifiers"]
			NamesCaps := NamesCaps || Id == "caps_lock"
		Chord := []
		for Id in Pressed
			if Id != "caps_lock" || NamesCaps
				Chord.Push(Id)
		if SourceEmulation_SelectorMatches(Map("required", Shortcut["modifiers"], "optional", []), Chord)
			return Shortcut
	}
	return 0
}

_SrcEmu_Result(Consumed, Actions) => Map("consumed", Consumed ? true : false, "actions", Actions)

/**
 * Decides one physical key press (a repeat of a held one included).
 * @param {Map} Session - From SourceEmulation_NewSession.
 * @param {String} Code - KeyboardEvent.code of the key.
 * @param {Map} Held - Built-in modifier id -> true for those the driver reports
 *   held (shift, control, alt, alt_right, meta) and caps_lock when it is on.
 * @param {Integer} Now - Milliseconds of the press, on any monotonic clock.
 * @returns {Map} "consumed" (the key itself must not reach the OS or the
 *   keylayout emulation) and "actions", ordered Maps of type text (text), key
 *   (key, modifiers) or modifier (id, down).
 */
SourceEmulation_Press(Session, Code, Held, Now) {
	Model := Session["model"]
	Actions := []
	if Session["held_keys"].Has(Code)
		return _SrcEmu_Result(true, Actions)
	Modifier := Model["modifier_keys"].Get(Code, 0)
	TapHoldEntry := Model[_SrcEmu_TapHoldsField()].Get(Code, 0)
	if !(Modifier is Map) && !(TapHoldEntry is Map)
		_SrcEmu_Settle(Session, Now, Actions)
	if Modifier is Map {
		Session["held_keys"][Code] := "modifier"
		if Modifier["mode"] == "locked" {
			if Session["active"].Has(Modifier["id"])
				Session["active"].Delete(Modifier["id"])
			else
				Session["active"][Modifier["id"]] := true
		} else {
			Session["active"][Modifier["id"]] := true
		}
		return _SrcEmu_Result(true, Actions)
	}
	if TapHoldEntry is Map {
		; A second tap-hold key settles the first, as any other key does.
		_SrcEmu_Settle(Session, Now, Actions)
		Session["held_keys"][Code] := "tap_hold"
		Session["pending"] := Map("entry", TapHoldEntry, "code", Code, "at", Now)
		return _SrcEmu_Result(true, Actions)
	}
	Pressed := _SrcEmu_PressedIds(Session, Held)
	Shortcut := _SrcEmu_ShortcutFor(Session, Code, Pressed)
	if Shortcut is Map {
		Actions.Push(Map("type", "key", "key", Shortcut["send_key"], "modifiers", Shortcut["send_modifiers"].Clone()))
		return _SrcEmu_Result(true, Actions)
	}
	if Model["remaps"].Has(Code) {
		Remap := Model["remaps"][Code]
		if Remap != ""
			Actions.Push(Map("type", "key", "key", Remap, "modifiers", _SrcEmu_HeldModifiers(Held)))
		return _SrcEmu_Result(true, Actions)
	}
	Layer := _SrcEmu_SelectedLayer(Session, Pressed)
	if !(Layer is Map)
		return _SrcEmu_Result(false, Actions)
	if Layer["keys"].Has(Code) {
		_SrcEmu_Perform(Layer["keys"][Code], Actions)
		return _SrcEmu_Result(true, Actions)
	}
	; An emulated layer has no keyMap for the OS to fall back on.
	if !Layer["native"]
		return _SrcEmu_Result(true, Actions)
	; A hold reaching a native layer: no modifier selects it on the OS, so the
	; key goes out with the modifiers of the layer's first selector.
	Hold := Session["hold"]
	if (Hold is Map) && Hold["entry"]["hold_layer"] == Layer["id"] {
		Required := Layer["selectors"].Length ? Layer["selectors"][1]["required"] : []
		Sent := Map()
		for Id in _SrcEmu_HeldModifiers(Held)
			Sent[Id] := true
		for Id in Required
			Sent[Id] := true
		Modifiers := []
		for Id in SourceEmulation_Reported()
			if Sent.Has(Id)
				Modifiers.Push(Id), Sent.Delete(Id)
		for Id in Required
			if Sent.Has(Id)
				Modifiers.Push(Id), Sent.Delete(Id)
		Actions.Push(Map("type", "key", "key", Code, "modifiers", Modifiers))
		return _SrcEmu_Result(true, Actions)
	}
	return _SrcEmu_Result(false, Actions)
}

/**
 * Decides one physical key release.
 * @param {Map} Session
 * @param {String} Code - KeyboardEvent.code.
 * @param {Integer} Now - Milliseconds of the release.
 * @returns {Map} As SourceEmulation_Press: consumed when the press was the engine's.
 */
SourceEmulation_Release(Session, Code, Now) {
	Actions := []
	Role := Session["held_keys"].Get(Code, "")
	if Role == ""
		return _SrcEmu_Result(false, Actions)
	Session["held_keys"].Delete(Code)
	if Role == "modifier" {
		Modifier := Session["model"]["modifier_keys"][Code]
		if Modifier["mode"] == "held" && Session["active"].Has(Modifier["id"])
			Session["active"].Delete(Modifier["id"])
		return _SrcEmu_Result(true, Actions)
	}
	Pending := Session["pending"]
	if (Pending is Map) && Pending["code"] == Code {
		Session["pending"] := 0
		if Now - Pending["at"] < Pending["entry"]["threshold_ms"]
			_SrcEmu_Perform(Pending["entry"]["tap"], Actions)
		return _SrcEmu_Result(true, Actions)
	}
	Hold := Session["hold"]
	if (Hold is Map) && Hold["code"] == Code
		_SrcEmu_EndHold(Session, Actions)
	return _SrcEmu_Result(true, Actions)
}

/**
 * Starts the hold of a pending tap-hold whose threshold has passed, so a held
 * modifier is down before any key comes under it.
 * @param {Map} Session
 * @param {Integer} Now - Milliseconds now.
 * @returns {Array} Actions as SourceEmulation_Press.
 */
SourceEmulation_Tick(Session, Now) {
	Actions := []
	Pending := Session["pending"]
	if (Pending is Map) && Now - Pending["at"] >= Pending["entry"]["threshold_ms"]
		_SrcEmu_StartHold(Session, Actions)
	return Actions
}

/**
 * Drops every pending and held state (stop, pause, reload), releasing a held
 * built-in modifier the engine pressed.
 * @param {Map} Session
 * @returns {Array} Actions as SourceEmulation_Press.
 */
SourceEmulation_Reset(Session) {
	Actions := []
	if Session["hold"] is Map
		_SrcEmu_EndHold(Session, Actions)
	Session["pending"] := 0, Session["hold"] := 0
	Session["held_keys"] := Map(), Session["active"] := Map()
	return Actions
}

/**
 * Whether a custom modifier is active, for a menu or a test.
 * @param {Map} Session
 * @param {String} Id
 * @returns {Boolean}
 */
SourceEmulation_Active(Session, Id) => Session["active"].Has(Id)

/**
 * The milliseconds left before the pending tap-hold's threshold, 0 when none.
 * @param {Map} Session
 * @param {Integer} Now
 * @returns {Integer}
 */
SourceEmulation_PendingDelay(Session, Now) {
	Pending := Session["pending"]
	if !(Pending is Map)
		return 0
	return Max(1, Pending["entry"]["threshold_ms"] - (Now - Pending["at"]))
}
