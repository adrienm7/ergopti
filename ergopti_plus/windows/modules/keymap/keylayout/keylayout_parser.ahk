; modules/keymap/keylayout/keylayout_parser.ahk

; ==============================================================================
; MODULE: macOS .keylayout Reader
; DESCRIPTION:
; Reads a macOS keyboard layout (.keylayout), the only format of a registry
; layout, into the Maps the Windows emulation walks: which keyMap each
; modifier combination selects, what every key types in every keyMap, and the
; dead-key state machine (actions and terminators).
;
; FEATURES & RATIONALE:
; 1. Pure: no file, hotkey or global state. The emulation parses once when a
;    layout is loaded or changed, never on the typing path; Keylayout_Step, the only
;    function called per keystroke, is Map lookups.
; 2. One reader, one form. Keylayout_ParseCanonical reads the file into the
;    canonical form (schema 1) documented in _shared/layouts/engine/composer/keylayout.lua,
;    the form the Lua reader, the Python converter and the web composer produce,
;    with the same rules: comments stripped, XML character references decoded,
;    double or single quoted attribute values, modifierMap tokens folded onto
;    shift/caps/option/command/control, first <key> of a code and first <action>
;    of an id kept. _shared/tests/corpus/keylayout pins them all to it.
;    Keylayout_Parse then indexes that form into the Maps a keystroke looks up.
; 3. Fail fast: a missing <layout first="0">, an undefined modifierMap or
;    keyMapSet, an unknown modifier token, a tag of a walked element the grammar
;    cannot read or an undefined action throws instead of producing a half-read
;    layout: skipping an unreadable tag silently lost keys.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\core\text\engine\number.ahk





; =============================
; =============================
; ======= 1/ Vocabulary =======
; =============================
; =============================

; modifierMap tokens (Apple TN2056) folded onto the five modifiers the
; emulation distinguishes; left/right variants are not told apart.
global KEYLAYOUT_MODIFIER_TOKENS := Map(
	"shift", "shift", "rightShift", "shift", "anyShift", "shift",
	"option", "option", "rightOption", "option", "anyOption", "option",
	"control", "control", "rightControl", "control", "anyControl", "control",
	"command", "command",
	"caps", "caps"
)

; State a key starts from and returns to once a dead-key sequence ends.
global KEYLAYOUT_NEUTRAL_STATE := "none"

; Guards a baseMapSet chain that loops back on itself.
global KEYLAYOUT_MAX_BASE_DEPTH := 8

; The tag starting exactly at the "<" being read, the attributes in either quote.
global _KEYLAYOUT_TAG_RE := "SA)<(/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[A-Za-z_:][\w:.-]*\s*=\s*(?:" . '"[^"]*"' . "|'[^']*'))*)\s*(/?)>"
global _KEYLAYOUT_ATTR_RE := "S)([A-Za-z_:][\w:.-]*)\s*=\s*(?:" . '"([^"]*)"' . "|'([^']*)')"
global _KEYLAYOUT_ENTITY_RE := "S)&(#x[0-9A-Fa-f]+|#[0-9]+|lt|gt|amp|quot|apos)" . Chr(59)





; ===========================
; ===========================
; ======= 2/ Decoding =======
; ===========================
; ===========================

/**
 * Decodes the XML character references a .keylayout attribute can hold.
 * @param {string} Value - Raw attribute value.
 * @returns {string} Decoded text.
 */
Keylayout_DecodeEntities(Value) {
	global _KEYLAYOUT_ENTITY_RE
	if !InStr(Value, "&")
		return Value
	Out := ""
	Pos := 1
	while (Found := RegExMatch(Value, _KEYLAYOUT_ENTITY_RE, &M, Pos)) {
		Out .= SubStr(Value, Pos, Found - Pos)
		Token := M[1]
		if SubStr(Token, 1, 1) == "#" {
			Raw := SubStr(Token, 1, 2) == "#x" ? "0x" . SubStr(Token, 3) : SubStr(Token, 2)
			if !NumberTryParseInputInteger(Raw, &Code) || Code < 0 || Code > 0x10FFFF || (Code >= 0xD800 && Code <= 0xDFFF)
				throw ValueError("A .keylayout numeric character reference is outside the supported Unicode scalar domain.", -1, Token)
			Out .= Chr(Code)
		} else
			Out .= Map("lt", "<", "gt", ">", "amp", "&", "quot", '"', "apos", "'")[Token]
		Pos := Found + M.Len
	}
	return Out . SubStr(Value, Pos)
}

/**
 * Whether a text types something visible: not empty and free of C0/C1
 * control characters (Kalamine marks unused keys with U+0010).
 * @param {string} Text - Candidate output.
 * @returns {boolean}
 */
Keylayout_IsPrintable(Text) {
	if (Text == "")
		return false
	Loop Parse, Text {
		Code := Ord(A_LoopField)
		if (Code < 0x20 || (Code >= 0x7F && Code <= 0x9F))
			return false
	}
	return true
}

_Keylayout_Attributes(Raw) {
	global _KEYLAYOUT_ATTR_RE
	Attrs := Map()
	Pos := 1
	while (Found := RegExMatch(Raw, _KEYLAYOUT_ATTR_RE, &M, Pos)) {
		; An unmatched group reads as "": the other quote spelled this value.
		Attrs[M[1]] := Keylayout_DecodeEntities(M.Len[2] || !M.Pos[3] ? M[2] : M[3])
		Pos := Found + M.Len
	}
	return Attrs
}

_Keylayout_ParseModifierKeys(Keys) {
	global KEYLAYOUT_MODIFIER_TOKENS
	Required := Map()
	Optional := Map()
	Loop Parse, Keys, " `t`r`n" {
		Token := A_LoopField
		if (Token == "")
			continue
		IsOptional := (SubStr(Token, -1) == "?")
		Name := IsOptional ? SubStr(Token, 1, -1) : Token
		if !KEYLAYOUT_MODIFIER_TOKENS.Has(Name)
			throw ValueError("Unknown .keylayout modifier token.", -1, Token)
		if IsOptional
			Optional[KEYLAYOUT_MODIFIER_TOKENS[Name]] := true
		else
			Required[KEYLAYOUT_MODIFIER_TOKENS[Name]] := true
	}
	for Name in Required
		if Optional.Has(Name)
			Optional.Delete(Name)
	return Map("Required", Required, "Optional", Optional)
}





; ==========================
; ==========================
; ======= 3/ Parsing =======
; ==========================
; ==========================

; A required integer attribute, or a refusal naming the element that lacks it.
_Keylayout_IntegerAttribute(Attrs, Name, Element) {
	Value := Attrs.Get(Name, "")
	if !NumberTryParseInputInteger(Value, &Parsed)
		throw ValueError("A .keylayout " . Element . " has no valid " . Name . ".", -1, Value)
	return Parsed
}

; A required text attribute, or a refusal naming the element that lacks it.
_Keylayout_RequiredAttribute(Attrs, Name, Element) {
	if !Attrs.Has(Name)
		throw ValueError("A .keylayout " . Element . " has no " . Name . ".")
	return Attrs[Name]
}

; A tag of an element the walk reads that the grammar cannot: keys or whole
; keyMaps would vanish silently. Any other "<" is not ours to judge.
_Keylayout_RefuseUnreadableTag(Body, Open) {
	static Known := Map("keyboard", 1, "layouts", 1, "layout", 1, "modifierMap", 1, "keyMapSelect", 1,
		"modifier", 1, "keyMapSet", 1, "keyMap", 1, "key", 1, "actions", 1, "action", 1, "when", 1,
		"terminators", 1)
	if RegExMatch(Body, "SA)</?([A-Za-z][A-Za-z0-9]*)[\s/>]", &M, Open) && Known.Has(M[1]) {
		StrReplace(SubStr(Body, 1, Open), "`n", , , &Newlines)
		throw ValueError("Malformed .keylayout tag on line " . (Newlines + 1) . " of the comment-free text.", -1, M[1])
	}
}

/**
 * Reads the text of a .keylayout into the canonical form (schema 1).
 * @param {string} Text - Full file content.
 * @returns {Map} schema, name, map_set, default_index, selects, key_map_sets,
 *   actions and terminators, as _shared/layouts/engine/composer/keylayout.lua documents them.
 * @throws {ValueError} When the file cannot be read completely.
 */
Keylayout_ParseCanonical(Text) {
	global _KEYLAYOUT_TAG_RE, KEYLAYOUT_NEUTRAL_STATE
	if !(Text is String)
		throw TypeError("The .keylayout text must be a string.")
	Body := RegExReplace(Text, "s)<!--.*?-->", "")
	Name := ""
	Layouts := []
	ModifierMaps := Map()
	Sets := Map(), SetOrder := []
	Actions := Map(), ActionOrder := []
	TerminatorOutputs := Map(), TerminatorOrder := []
	CurModifierMap := "", CurSelect := 0, CurSet := 0, CurKeyMap := 0, CurAction := 0
	InTerminators := false

	Pos := 1
	while (Open := InStr(Body, "<", true, Pos)) {
		if !RegExMatch(Body, _KEYLAYOUT_TAG_RE, &M, Open) {
			_Keylayout_RefuseUnreadableTag(Body, Open)
			Pos := Open + 1
			continue
		}
		Pos := Open + M.Len
		Tag := M[2]
		if (M[1] == "/") {
			switch Tag, true {
				case "modifierMap": CurModifierMap := ""
				case "keyMapSelect": CurSelect := 0
				case "keyMapSet": CurSet := 0
				case "keyMap": CurKeyMap := 0
				case "action": CurAction := 0
				case "terminators": InTerminators := false
			}
			continue
		}
		SelfClosing := (M[4] == "/")
		Attrs := _Keylayout_Attributes(M[3])
		switch Tag, true {
			case "keyboard":
				Name := Attrs.Get("name", "")
			case "layout":
				Layouts.Push(Attrs)
			case "modifierMap":
				CurModifierMap := _Keylayout_RequiredAttribute(Attrs, "id", "modifierMap")
				; A repeated id replaces the earlier map, as the Lua reader does.
				ModifierMaps[CurModifierMap] := Map(
					"default_index", Attrs.Has("defaultIndex")
						? _Keylayout_IntegerAttribute(Attrs, "defaultIndex", "modifierMap") : 0,
					"selects", [])
			case "keyMapSelect":
				if (CurModifierMap != "") {
					CurSelect := Map("index", _Keylayout_IntegerAttribute(Attrs, "mapIndex", "keyMapSelect"), "modifiers", [])
					ModifierMaps[CurModifierMap]["selects"].Push(CurSelect)
				}
			case "modifier":
				if IsObject(CurSelect) {
					Parsed := _Keylayout_ParseModifierKeys(Attrs.Get("keys", ""))
					Required := [], Optional := []
					; A Map enumerates string keys sorted, the order the form requires.
					for Token in Parsed["Required"]
						Required.Push(Token)
					for Token in Parsed["Optional"]
						Optional.Push(Token)
					CurSelect["modifiers"].Push(Map("required", Required, "optional", Optional))
				}
			case "keyMapSet":
				Id := _Keylayout_RequiredAttribute(Attrs, "id", "keyMapSet")
				if !Sets.Has(Id) {
					Sets[Id] := Map("Id", Id, "Maps", Map(), "Order", [])
					SetOrder.Push(Id)
				}
				CurSet := Sets[Id]
			case "keyMap":
				if IsObject(CurSet) {
					Index := _Keylayout_IntegerAttribute(Attrs, "index", "keyMap")
					if !CurSet["Maps"].Has(Index) {
						CurSet["Maps"][Index] := Map("Keys", Map(), "Order", [], "Base", 0)
						CurSet["Order"].Push(Index)
					}
					CurKeyMap := CurSet["Maps"][Index]
					; A repeated baseIndex replaces the earlier one, as the Lua reader does.
					if Attrs.Has("baseIndex")
						CurKeyMap["Base"] := Map("set", Attrs.Get("baseMapSet", CurSet["Id"]),
							"index", _Keylayout_IntegerAttribute(Attrs, "baseIndex", "keyMap"))
					if SelfClosing
						CurKeyMap := 0
				}
			case "key":
				if IsObject(CurSet) && IsObject(CurKeyMap) {
					Code := _Keylayout_IntegerAttribute(Attrs, "code", "key")
					if !CurKeyMap["Keys"].Has(Code) {
						if Attrs.Has("output")
							CurKeyMap["Keys"][Code] := Map("code", Code, "output", Attrs["output"])
						else if Attrs.Has("action")
							CurKeyMap["Keys"][Code] := Map("code", Code, "action", Attrs["action"])
						if CurKeyMap["Keys"].Has(Code)
							CurKeyMap["Order"].Push(Code)
					}
				}
			case "action":
				Id := _Keylayout_RequiredAttribute(Attrs, "id", "action")
				; A repeated id keeps the first: the later one reads into nowhere.
				CurAction := Map("Whens", Map(), "Order", [])
				if !Actions.Has(Id) {
					Actions[Id] := CurAction
					ActionOrder.Push(Id)
				}
				if SelfClosing
					CurAction := 0
			case "when":
				if IsObject(CurAction) {
					State := Attrs.Get("state", KEYLAYOUT_NEUTRAL_STATE)
					if !CurAction["Whens"].Has(State) {
						When := Map("state", State)
						if (Attrs.Get("output", "") != "")
							When["output"] := Attrs["output"]
						if Attrs.Has("next")
							When["next"] := Attrs["next"]
						CurAction["Whens"][State] := When
						CurAction["Order"].Push(State)
					}
				} else if (InTerminators && Attrs.Has("state") && !TerminatorOutputs.Has(Attrs["state"])) {
					TerminatorOutputs[Attrs["state"]] := Attrs.Get("output", "")
					TerminatorOrder.Push(Attrs["state"])
				}
			case "terminators":
				InTerminators := true
		}
	}

	Default := 0
	for Candidate in Layouts {
		if (Candidate.Get("first", "") == "0") {
			Default := Candidate
			break
		}
	}
	if !IsObject(Default)
		throw ValueError('The .keylayout has no <layout first="0"> element.')
	MapSet := Default.Get("mapSet", "")
	ModifiersId := Default.Get("modifiers", "")
	if !Sets.Has(MapSet)
		throw ValueError("The .keylayout keyMapSet is not defined.", -1, MapSet)
	if !ModifierMaps.Has(ModifiersId)
		throw ValueError("The .keylayout modifierMap is not defined.", -1, ModifiersId)

	Canonical := Map("schema", 1, "name", Name, "map_set", MapSet,
		"default_index", ModifierMaps[ModifiersId]["default_index"],
		"selects", ModifierMaps[ModifiersId]["selects"],
		"key_map_sets", [], "actions", [], "terminators", [])
	for Id in SetOrder {
		KeyMaps := []
		for Index in Sets[Id]["Order"] {
			Source := Sets[Id]["Maps"][Index]
			Keys := []
			for Code in Source["Order"]
				Keys.Push(Source["Keys"][Code])
			Entry := Map("index", Index, "keys", Keys)
			if IsObject(Source["Base"])
				Entry["base"] := Source["Base"]
			KeyMaps.Push(Entry)
		}
		Canonical["key_map_sets"].Push(Map("id", Id, "key_maps", KeyMaps))
	}
	for Id in ActionOrder {
		Whens := []
		for State in Actions[Id]["Order"]
			Whens.Push(Actions[Id]["Whens"][State])
		Canonical["actions"].Push(Map("id", Id, "whens", Whens))
	}
	for State in TerminatorOrder
		Canonical["terminators"].Push(Map("state", State, "output", TerminatorOutputs[State]))
	return Canonical
}

/**
 * Parses the text of a .keylayout and indexes it for the keystroke path.
 * @param {string} Text - Full file content.
 * @returns {Map} Model with Name, MapSet, DefaultIndex, Selects, KeyMapSets,
 *   Bases, Actions and Terminators: the canonical form as lookup Maps.
 * @throws {ValueError} When the file cannot be read completely.
 */
Keylayout_Parse(Text) {
	Canonical := Keylayout_ParseCanonical(Text)
	Model := Map(
		"Name", Canonical["name"],
		"MapSet", Canonical["map_set"],
		"DefaultIndex", Canonical["default_index"],
		"Selects", [],
		"KeyMapSets", Map(),
		"Bases", Map(),
		"Actions", Map(),
		"Terminators", Map()
	)
	for Select in Canonical["selects"] {
		Modifiers := []
		for Modifier in Select["modifiers"] {
			Required := Map(), Optional := Map()
			for Token in Modifier["required"]
				Required[Token] := true
			for Token in Modifier["optional"]
				Optional[Token] := true
			Modifiers.Push(Map("Required", Required, "Optional", Optional))
		}
		Model["Selects"].Push(Map("Index", Select["index"], "Modifiers", Modifiers))
	}
	for KeyMapSet in Canonical["key_map_sets"] {
		SetId := KeyMapSet["id"]
		Levels := Map()
		Model["KeyMapSets"][SetId] := Levels
		for KeyMap in KeyMapSet["key_maps"] {
			Keys := Map()
			Levels[KeyMap["index"]] := Keys
			for Key in KeyMap["keys"]
				Keys[Key["code"]] := Key.Has("output")
					? Map("Kind", "output", "Value", Key["output"])
					: Map("Kind", "action", "Value", Key["action"])
			if KeyMap.Has("base") {
				if !Model["Bases"].Has(SetId)
					Model["Bases"][SetId] := Map()
				Model["Bases"][SetId][KeyMap["index"]] := [KeyMap["base"]["set"], KeyMap["base"]["index"]]
			}
		}
	}
	for Action in Canonical["actions"] {
		States := Map()
		Model["Actions"][Action["id"]] := States
		for When in Action["whens"]
			States[When["state"]] := Map("Output", When.Get("output", ""), "Next", When.Get("next", ""))
	}
	for Terminator in Canonical["terminators"]
		Model["Terminators"][Terminator["state"]] := Terminator["output"]
	return Model
}





; =============================
; =============================
; ======= 4/ Resolution =======
; =============================
; =============================

/**
 * keyMap index the layout selects when exactly ``Pressed`` modifiers are down.
 * @param {Map} Model - Parsed layout.
 * @param {Map} Pressed - Modifier name → true (shift, caps, option, command, control).
 * @returns {Integer}
 */
Keylayout_KeyMapIndex(Model, Pressed) {
	for Select in Model["Selects"] {
		for Modifier in Select["Modifiers"] {
			Matches := true
			for Name in Modifier["Required"] {
				if !Pressed.Has(Name) {
					Matches := false
					break
				}
			}
			if Matches {
				for Name in Pressed {
					if !Modifier["Required"].Has(Name) && !Modifier["Optional"].Has(Name) {
						Matches := false
						break
					}
				}
			}
			if Matches
				return Select["Index"]
		}
	}
	return Model["DefaultIndex"]
}

/**
 * The <key> element of ``Code`` in keyMap ``Index``, following baseMapSet.
 * @returns {Map|String} Map("Kind", "output"|"action", "Value", ...) or "".
 */
Keylayout_KeyEntry(Model, Index, Code) {
	global KEYLAYOUT_MAX_BASE_DEPTH
	MapSet := Model["MapSet"]
	Loop KEYLAYOUT_MAX_BASE_DEPTH {
		Sets := Model["KeyMapSets"].Get(MapSet, "")
		if !IsObject(Sets)
			throw ValueError("The .keylayout keyMapSet is not defined.", -1, MapSet)
		Keys := Sets.Get(Index, "")
		if IsObject(Keys) && Keys.Has(Code)
			return Keys[Code]
		Bases := Model["Bases"].Get(MapSet, "")
		if !IsObject(Bases) || !Bases.Has(Index)
			return ""
		MapSet := Bases[Index][1]
		Index := Bases[Index][2]
	}
	throw ValueError("The .keylayout keyMap base chain is too deep.")
}

/**
 * What ``Code`` types in keyMap ``Index`` from the neutral state.
 * @returns {Map} Kind ("none" | "text" | "dead"), Text (output, or what a dead
 *   key types on its own), State (dead-key state entered) and Action (id or "").
 */
Keylayout_Resolve(Model, Index, Code) {
	global KEYLAYOUT_NEUTRAL_STATE
	Entry := Keylayout_KeyEntry(Model, Index, Code)
	if !IsObject(Entry)
		return Map("Kind", "none", "Text", "", "State", "", "Action", "")
	if (Entry["Kind"] == "output") {
		Value := Entry["Value"]
		return Keylayout_IsPrintable(Value)
			? Map("Kind", "text", "Text", Value, "State", "", "Action", "")
			: Map("Kind", "none", "Text", "", "State", "", "Action", "")
	}
	Id := Entry["Value"]
	if !Model["Actions"].Has(Id)
		throw ValueError("A .keylayout key uses an undefined action.", -1, Id)
	When := Model["Actions"][Id].Get(KEYLAYOUT_NEUTRAL_STATE, "")
	if !IsObject(When)
		return Map("Kind", "none", "Text", "", "State", "", "Action", Id)
	if (When["Next"] != "") {
		Alone := Model["Terminators"].Get(When["Next"], "")
		return Map("Kind", "dead", "Text", Alone != "" ? Alone : Id, "State", When["Next"], "Action", Id)
	}
	if Keylayout_IsPrintable(When["Output"])
		return Map("Kind", "text", "Text", When["Output"], "State", "", "Action", Id)
	return Map("Kind", "none", "Text", "", "State", "", "Action", Id)
}

/**
 * One keystroke of the dead-key state machine, as macOS runs it.
 *
 * From the neutral state a key types its output or enters a dead-key state.
 * Inside state S, an action with a <when state="S"> types that output and/or
 * moves to its next state; any other key first types S's terminator (what the
 * dead key types on its own), then behaves as from the neutral state.
 * @param {Map} Model - Parsed layout.
 * @param {string} State - Current state ("none" when neutral).
 * @param {Integer} Index - keyMap index of the pressed modifiers.
 * @param {Integer} Code - macOS key code.
 * @returns {Map} Output (text to type, possibly "") and Next (state after).
 */
Keylayout_Step(Model, State, Index, Code) {
	global KEYLAYOUT_NEUTRAL_STATE
	Pending := ""
	Entry := Keylayout_KeyEntry(Model, Index, Code)
	if (State !== KEYLAYOUT_NEUTRAL_STATE) {
		if (IsObject(Entry) && Entry["Kind"] == "action") {
			Action := Model["Actions"].Get(Entry["Value"], "")
			if (IsObject(Action) && Action.Has(State)) {
				When := Action[State]
				Output := Keylayout_IsPrintable(When["Output"]) ? When["Output"] : ""
				Next := (When["Next"] != "") ? When["Next"] : KEYLAYOUT_NEUTRAL_STATE
				return Map("Output", Output, "Next", Next)
			}
		}
		Terminator := Model["Terminators"].Get(State, "")
		Pending := Keylayout_IsPrintable(Terminator) ? Terminator : ""
	}
	Resolved := Keylayout_Resolve(Model, Index, Code)
	if (Resolved["Kind"] == "dead")
		return Map("Output", Pending, "Next", Resolved["State"])
	return Map("Output", Pending . Resolved["Text"], "Next", KEYLAYOUT_NEUTRAL_STATE)
}
