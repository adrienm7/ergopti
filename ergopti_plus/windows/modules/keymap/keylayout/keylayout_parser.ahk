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
; 2. Same reading rules as the Linux converter
;    (static/ergopti/linux/xkb_generation/keylayout_to_xkb.py): comments
;    stripped, XML character references decoded, control-character outputs
;    type nothing, modifierMap tokens folded onto shift/caps/option/command/
;    control, baseMapSet inheritance followed. The shared resolution vectors in
;    _shared/tests/layouts pin both readers to the same answers.
; 3. Fail fast: a missing <layout first="0">, an undefined modifierMap or
;    keyMapSet, an unknown modifier token or an undefined action throws
;    instead of producing a half-read layout.
; ==============================================================================

#Requires AutoHotkey v2.0





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

global _KEYLAYOUT_TAG_RE := 'S)<(/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[A-Za-z_:][\w:.-]*\s*=\s*"[^"]*")*)\s*(/?)>'
global _KEYLAYOUT_ATTR_RE := 'S)([A-Za-z_:][\w:.-]*)\s*=\s*"([^"]*)"'
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
		if (SubStr(Token, 1, 2) == "#x")
			Out .= Chr(Integer("0x" . SubStr(Token, 3)))
		else if (SubStr(Token, 1, 1) == "#")
			Out .= Chr(Integer(SubStr(Token, 2)))
		else
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
		Attrs[M[1]] := Keylayout_DecodeEntities(M[2])
		Pos := Found + M.Len
	}
	return Attrs
}

_Keylayout_ParseModifierKeys(Keys) {
	global KEYLAYOUT_MODIFIER_TOKENS
	Required := Map()
	Optional := Map()
	Loop Parse, Keys, " `t" {
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

/**
 * Parses the text of a .keylayout.
 * @param {string} Text - Full file content.
 * @returns {Map} Model with Name, MapSet, DefaultIndex, Selects, KeyMapSets,
 *   Bases, Actions and Terminators.
 * @throws {ValueError} When a part every emulation needs is missing.
 */
Keylayout_Parse(Text) {
	global _KEYLAYOUT_TAG_RE
	Body := RegExReplace(Text, "s)<!--.*?-->", "")
	Model := Map(
		"Name", "",
		"MapSet", "",
		"DefaultIndex", 0,
		"Selects", [],
		"KeyMapSets", Map(),
		"Bases", Map(),
		"Actions", Map(),
		"Terminators", Map()
	)
	Layouts := []
	ModifierMaps := Map()
	CurModifierMap := ""
	CurSelect := 0
	CurMapSet := ""
	CurKeyMap := ""
	CurAction := 0
	InTerminators := false

	Pos := 1
	while (Found := RegExMatch(Body, _KEYLAYOUT_TAG_RE, &M, Pos)) {
		Pos := Found + M.Len
		Closing := (M[1] == "/")
		Tag := M[2]
		if Closing {
			switch Tag, true {
				case "modifierMap": CurModifierMap := ""
				case "keyMapSelect": CurSelect := 0
				case "keyMapSet": CurMapSet := ""
				case "keyMap": CurKeyMap := ""
				case "action": CurAction := 0
				case "terminators": InTerminators := false
			}
			continue
		}
		SelfClosing := (M[4] == "/")
		Attrs := _Keylayout_Attributes(M[3])
		switch Tag, true {
			case "keyboard":
				Model["Name"] := Attrs.Get("name", "")
			case "layout":
				Layouts.Push(Attrs)
			case "modifierMap":
				CurModifierMap := Attrs["id"]
				ModifierMaps[CurModifierMap] := Map(
					"DefaultIndex", Integer(Attrs.Get("defaultIndex", "0")),
					"Selects", [])
			case "keyMapSelect":
				if (CurModifierMap != "") {
					CurSelect := Map("Index", Integer(Attrs["mapIndex"]), "Modifiers", [])
					ModifierMaps[CurModifierMap]["Selects"].Push(CurSelect)
				}
			case "modifier":
				if IsObject(CurSelect)
					CurSelect["Modifiers"].Push(_Keylayout_ParseModifierKeys(Attrs.Get("keys", "")))
			case "keyMapSet":
				CurMapSet := Attrs["id"]
				if !Model["KeyMapSets"].Has(CurMapSet)
					Model["KeyMapSets"][CurMapSet] := Map()
			case "keyMap":
				if (CurMapSet != "") {
					CurKeyMap := Integer(Attrs["index"])
					Sets := Model["KeyMapSets"][CurMapSet]
					if !Sets.Has(CurKeyMap)
						Sets[CurKeyMap] := Map()
					if Attrs.Has("baseIndex") {
						if !Model["Bases"].Has(CurMapSet)
							Model["Bases"][CurMapSet] := Map()
						Model["Bases"][CurMapSet][CurKeyMap] := [
							Attrs.Get("baseMapSet", CurMapSet), Integer(Attrs["baseIndex"])]
					}
					if SelfClosing
						CurKeyMap := ""
				}
			case "key":
				if (CurMapSet != "" && CurKeyMap != "") {
					Keys := Model["KeyMapSets"][CurMapSet][CurKeyMap]
					Code := Integer(Attrs["code"])
					if Keys.Has(Code)
						continue
					if Attrs.Has("output")
						Keys[Code] := Map("Kind", "output", "Value", Attrs["output"])
					else if Attrs.Has("action")
						Keys[Code] := Map("Kind", "action", "Value", Attrs["action"])
				}
			case "action":
				Id := Attrs["id"]
				if !Model["Actions"].Has(Id)
					Model["Actions"][Id] := Map()
				CurAction := SelfClosing ? 0 : Model["Actions"][Id]
			case "when":
				State := Attrs.Get("state", KEYLAYOUT_NEUTRAL_STATE)
				if IsObject(CurAction) {
					if !CurAction.Has(State)
						CurAction[State] := Map("Output", Attrs.Get("output", ""),
							"Next", Attrs.Get("next", ""))
				} else if (InTerminators && Attrs.Has("state")) {
					if !Model["Terminators"].Has(State)
						Model["Terminators"][State] := Attrs.Get("output", "")
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
	Model["MapSet"] := Default.Get("mapSet", "")
	ModifiersId := Default.Get("modifiers", "")
	if !Model["KeyMapSets"].Has(Model["MapSet"])
		throw ValueError("The .keylayout keyMapSet is not defined.", -1, Model["MapSet"])
	if !ModifierMaps.Has(ModifiersId)
		throw ValueError("The .keylayout modifierMap is not defined.", -1, ModifiersId)
	Model["DefaultIndex"] := ModifierMaps[ModifiersId]["DefaultIndex"]
	Model["Selects"] := ModifierMaps[ModifiersId]["Selects"]
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
