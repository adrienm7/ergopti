; infra/send_input_parameter.ahk

; ==============================================================================
; MODULE: Send Input Parameters
; DESCRIPTION:
; Parses the parameters of the send_text, send_key and send_shortcut actions:
; the text to type, the key to press and the modifiers-plus-key to press. The
; vocabulary (named keys, modifiers, their AutoHotkey names, the text limit) is
; _shared/modules/actions/send_keys.json, and the grammar is pinned by the shared
; corpus _shared/tests/corpus/action_parameters/send_input_vectors.json, which
; the macOS and Linux suites replay against _shared/lua/send_input too.
;
; FEATURES & RATIONALE:
; 1. Pure parse, separate emission: the unit suite replays the corpus without a
;    keystroke, and the emitter only ever sees a value the parser accepted.
; 2. Code points, not UTF-16 units: an emoji is one character of text on every
;    driver, so a limit counted in AutoHotkey string units would refuse text the
;    two Lua drivers accept.
; 3. `primary` is the portable modifier: Control here, Command on macOS, so one
;    binding copied between machines keeps meaning "select all".
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Vocabulary ================
; ======================================
; ======================================

; Whitespace a key or shortcut value is trimmed of, as Lua's %s does on the
; other drivers.
global SEND_INPUT_TRIM := " `t`r`n`v`f"

; The decoded send_keys.json, loaded on first use.
global _SEND_INPUT_VOCABULARY := ""
global _SEND_INPUT_VOCABULARY_JSON := ""

; Returns the shared vocabulary, loading it once. A missing or malformed file is
; a broken install, not an empty vocabulary: every send_* binding would refuse
; its value with no explanation.
; @returns {Map}
SendInputVocabulary() {
	global _SEND_INPUT_VOCABULARY, _SEND_INPUT_VOCABULARY_JSON, _SharedDir
	if (_SEND_INPUT_VOCABULARY is Map)
		return _SEND_INPUT_VOCABULARY
	Path := _SharedDir . "\modules\actions\send_keys.json"
	if !FSExists(Path)
		throw Error("The send-input vocabulary is missing: " . Path)
	Text := FSRead(Path)
	if !(Text is String)
		throw Error("The send-input vocabulary could not be read: " . Path)
	Root := JsonParse(Text)
	if !(Root is Map) || !Root.Has("modifiers") || !(Root["modifiers"] is Array)
			|| !Root.Has("keys") || !(Root["keys"] is Array)
			|| !Root.Has("text_max_code_points") || !(Root["text_max_code_points"] is Integer)
		throw Error("The send-input vocabulary is malformed: " . Path)
	_SEND_INPUT_VOCABULARY := Root
	_SEND_INPUT_VOCABULARY_JSON := Text
	return Root
}

; The vocabulary as the JSON text of the shared file, for the action picker's
; editor, which validates with the same rules in the page.
; @returns {String}
SendInputVocabularyJson() {
	global _SEND_INPUT_VOCABULARY_JSON
	SendInputVocabulary()
	return _SEND_INPUT_VOCABULARY_JSON
}

; Lowers A to Z only. StrLower would also lower É, which the Lua drivers cannot
; do byte by byte, so the three drivers would read one value three ways.
; @param {String} Text
; @returns {String}
_SendInputAsciiLower(Text) {
	Out := ""
	loop parse Text {
		Code := Ord(A_LoopField)
		Out .= (Code >= 65 && Code <= 90) ? Chr(Code + 32) : A_LoopField
	}
	return Out
}

; Splits a string into code points, joining each UTF-16 surrogate pair.
; @param {String} Text
; @returns {Array} One string per code point.
_SendInputCodePoints(Text) {
	Points := []
	Index := 1
	Length := StrLen(Text)
	while (Index <= Length) {
		Unit := Ord(SubStr(Text, Index, 1))
		Width := (Unit >= 0xD800 && Unit <= 0xDBFF && Index < Length) ? 2 : 1
		Points.Push(SubStr(Text, Index, Width))
		Index += Width
	}
	return Points
}

; @param {String} Point One code point.
; @returns {Boolean} True for C0 and C1 control characters.
_SendInputIsControl(Point) {
	Code := Ord(Point)
	return Code <= 0x1F || (Code >= 0x7F && Code <= 0x9F)
}

; Finds the vocabulary entry an id or alias names.
; @param {Array} Entries send_keys.json "keys" or "modifiers".
; @param {String} Wanted A lowered token.
; @returns {Map|String} The entry, or "" when none matches.
_SendInputFindEntry(Entries, Wanted) {
	for _, Entry in Entries {
		if (Entry["id"] == Wanted)
			return Entry
		for _, Alias in Entry["aliases"] {
			if (Alias == Wanted)
				return Entry
		}
	}
	return ""
}

; The named keys as one line for a prompt, a run of function keys collapsed to
; its bounds ("f1…f20") so the list stays readable.
; @returns {String}
SendInputDescribeKeys() {
	Names := []
	RunFirst := ""
	RunLast := ""
	for _, Entry in SendInputVocabulary()["keys"] {
		if RegExMatch(Entry["id"], "^f\d+$") {
			if (RunFirst = "")
				RunFirst := Entry["id"]
			RunLast := Entry["id"]
			continue
		}
		Names.Push(Entry["id"])
	}
	if (RunFirst != "")
		Names.Push(RunFirst . "…" . RunLast)
	Text := ""
	for _, Name in Names
		Text .= (Text = "" ? "" : ", ") . Name
	return Text
}





; ==================================
; ==================================
; ======= 2/ Parsing ===============
; ==================================
; ==================================

; Parses a send_text value.
; @param {String} Value
; @returns {Map|String} Map("text", ..., "canonical", ...), or "" when invalid.
SendInputParseText(Value) {
	if !(Value is String)
		return ""
	Points := _SendInputCodePoints(Value)
	if (Points.Length == 0 || Points.Length > SendInputVocabulary()["text_max_code_points"])
		return ""
	for _, Point in Points {
		if _SendInputIsControl(Point)
			return ""
	}
	return Map("text", Value, "canonical", Value)
}

; Parses a send_key value, or the key part of a shortcut.
; @param {String} Value
; @param {Boolean} LowerLetter True inside a shortcut, where A names the key.
; @returns {Map|String} Map("named", id) or Map("char", ...), with "canonical";
;   "" when invalid.
SendInputParseKey(Value, LowerLetter := false) {
	global SEND_INPUT_TRIM
	if !(Value is String)
		return ""
	Wanted := Trim(Value, SEND_INPUT_TRIM)
	if (Wanted == "")
		return ""
	Entry := _SendInputFindEntry(SendInputVocabulary()["keys"], _SendInputAsciiLower(Wanted))
	if (Entry is Map)
		return Map("named", Entry["id"], "canonical", Entry["id"])
	Points := _SendInputCodePoints(Wanted)
	if (Points.Length != 1 || _SendInputIsControl(Wanted))
		return ""
	Char := LowerLetter ? _SendInputAsciiLower(Wanted) : Wanted
	return Map("char", Char, "canonical", Char)
}

; Parses a send_shortcut value.
; @param {String} Value
; @returns {Map|String} Map("mods", [ids in vocabulary order], "named"/"char",
;   "canonical"), or "" when invalid.
SendInputParseShortcut(Value) {
	global SEND_INPUT_TRIM
	if !(Value is String)
		return ""
	Wanted := Trim(Value, SEND_INPUT_TRIM)
	if (Wanted == "")
		return ""
	if (StrLen(Wanted) >= 2 && SubStr(Wanted, -2) == "++") {
		KeyToken := "+"
		ModTokens := StrSplit(SubStr(Wanted, 1, StrLen(Wanted) - 2), "+")
	} else {
		ModTokens := StrSplit(Wanted, "+")
		KeyToken := ModTokens.Pop()
	}
	if (ModTokens.Length == 0)
		return ""
	Vocabulary := SendInputVocabulary()
	Held := Map()
	for _, Token in ModTokens {
		Entry := _SendInputFindEntry(Vocabulary["modifiers"],
			_SendInputAsciiLower(Trim(Token, SEND_INPUT_TRIM)))
		if !(Entry is Map) || Held.Has(Entry["id"])
			return ""
		Held[Entry["id"]] := true
	}
	Key := SendInputParseKey(KeyToken, true)
	if !(Key is Map)
		return ""
	Mods := []
	Canonical := ""
	for _, Entry in Vocabulary["modifiers"] {
		if Held.Has(Entry["id"]) {
			Mods.Push(Entry["id"])
			Canonical .= Entry["id"] . "+"
		}
	}
	Key["mods"] := Mods
	Key["canonical"] := Canonical . Key["canonical"]
	return Key
}

; Reads the inside of one {group} of a hotstring output.
; @param {String} Inner The text between the braces.
; @param {String} Text Set to the code point a {U+XXXX} names.
; @param {Map|String} Entry Set to the key a {name} or {name N} names.
; @param {Integer} Count Set to how many times to press it.
; @returns {Boolean} False when the group is not a token.
_SendInputReadOutputGroup(Inner, &Text, &Entry, &Count) {
	Text := ""
	Entry := ""
	Count := 1
	Vocabulary := SendInputVocabulary()
	if RegExMatch(Inner, "^[Uu]\+([0-9A-Fa-f]+)$", &Hex) {
		if (StrLen(Hex[1]) > 6)
			return false
		Code := Integer("0x" . Hex[1])
		if (Code > 0x10FFFF || (Code >= 0xD800 && Code <= 0xDFFF)
				|| Code <= 0x1F || (Code >= 0x7F && Code <= 0x9F))
			return false
		Text := Chr(Code)
		return true
	}
	if !RegExMatch(Inner, "^([0-9A-Za-z][0-9A-Za-z_]*)(?: ([1-9][0-9]*))?$", &Group)
		return false
	if (Group[2] != "") {
		; More digits than any bound: Integer() would wrap, and the text stays text.
		if (StrLen(Group[2]) > 9)
			return false
		Count := Integer(Group[2])
		if (Count > Vocabulary["output_key_max_repeat"])
			return false
	}
	Entry := _SendInputFindEntry(Vocabulary["keys"], _SendInputAsciiLower(Group[1]))
	return Entry is Map
}

; Parses a hotstring output into what it types and what it presses. The grammar is
; the rule of _shared/tests/corpus/hotstrings/output_token_vectors.json; the macOS
; and Linux drivers replay the same vectors against _shared/lua/send_input.
; @param {String} Value The output as the TOML holds it.
; @returns {Map} "tokens", an ordered Array of Map("kind", "text", "value", ...)
;   and Map("kind", "key", "id", ..., "entry", ..., "count", ...); "text", the typed
;   text alone; "has_keys".
SendInputParseOutput(Value) {
	if !(Value is String)
		throw TypeError("A hotstring output must be a string.")
	Vocabulary := SendInputVocabulary()
	if !Vocabulary.Has("output_key_max_repeat")
		throw Error("The send-input vocabulary has no output_key_max_repeat.")
	Tokens := []
	Typed := ""
	HasKeys := false
	PushText(Text) {
		Typed .= Text
		if (Tokens.Length > 0 && Tokens[Tokens.Length]["kind"] == "text")
			Tokens[Tokens.Length]["value"] .= Text
		else
			Tokens.Push(Map("kind", "text", "value", Text))
	}
	PushKey(Entry, Count) {
		HasKeys := true
		Tokens.Push(Map("kind", "key", "id", Entry["id"], "entry", Entry, "count", Count))
	}
	Index := 1
	Size := StrLen(Value)
	while (Index <= Size) {
		At := RegExMatch(Value, "[{`r`n`t]", , Index)
		if (At == 0) {
			PushText(SubStr(Value, Index))
			break
		}
		if (At > Index)
			PushText(SubStr(Value, Index, At - Index))
		Char := SubStr(Value, At, 1)
		Index := At + 1
		if (Char == "`t") {
			PushKey(_SendInputFindEntry(Vocabulary["keys"], "tab"), 1)
		} else if (Char == "`r" || Char == "`n") {
			if (Char == "`r" && SubStr(Value, Index, 1) == "`n")
				Index += 1
			PushKey(_SendInputFindEntry(Vocabulary["keys"], "enter"), 1)
		} else if (SubStr(Value, At, 3) == "{{}") {
			PushText("{")
			Index := At + 3
		} else if (SubStr(Value, At, 3) == "{}}") {
			PushText("}")
			Index := At + 3
		} else {
			Close := InStr(Value, "}", true, Index)
			if (Close > 0 && _SendInputReadOutputGroup(SubStr(Value, Index, Close - Index),
					&Text, &Entry, &Count)) {
				if (Entry is Map)
					PushKey(Entry, Count)
				else
					PushText(Text)
				Index := Close + 1
			} else {
				; Only the brace: what follows may still hold a real token.
				PushText("{")
			}
		}
	}
	return Map("tokens", Tokens, "text", Typed, "has_keys", HasKeys)
}

; The Send string of a parsed output. {Text} covers the whole rest of a Send, so
; text and keys cannot alternate under it: the text goes out escaped instead.
; @param {Map} Parsed A result of SendInputParseOutput.
; @returns {String}
SendInputOutputPayload(Parsed) {
	Payload := ""
	for _, Token in Parsed["tokens"] {
		if (Token["kind"] == "text")
			Payload .= SendEscapeLiteral(Token["value"])
		else
			Payload .= "{" . Token["entry"]["ahk"]
				. (Token["count"] > 1 ? " " . Token["count"] : "") . "}"
	}
	return Payload
}

; Parses a value of one of the three send parameter kinds.
; @param {String} Kind "text", "key" or "shortcut".
; @param {String} Value
; @returns {Map|String} The parse, or "" when invalid.
SendInputParse(Kind, Value) {
	switch Kind {
		case "text":
			return SendInputParseText(Value)
		case "key":
			return SendInputParseKey(Value)
		case "shortcut":
			return SendInputParseShortcut(Value)
	}
	throw ValueError("No send-input parameter kind '" . Kind . "'.")
}





; ==================================
; ==================================
; ======= 3/ Emission ==============
; ==================================
; ==================================

; The AutoHotkey name of a parsed key: the vocabulary's name for a named key,
; the character itself otherwise (TextPressKey braces it, so { and } are safe).
; @param {Map} Parsed A key or shortcut parse.
; @returns {String}
_SendInputAhkKey(Parsed) {
	if Parsed.Has("char")
		return Parsed["char"]
	return _SendInputFindEntry(SendInputVocabulary()["keys"], Parsed["named"])["ahk"]
}

; Types or presses a parsed value through the driver's synthetic-input choke
; points: text goes through SendFinalResult inside the hotstring buffers'
; synthetic transaction, keys through TextPressKey, which declares the same
; transaction. Both run at SendLevel 0, so the prefix watcher's I1 InputHook
; never reads them back as typing.
; @param {String} Kind "text", "key" or "shortcut".
; @param {Map} Parsed The parse SendInputParse returned for the value.
; @returns {Boolean} True when the OS accepted the input.
SendInputEmit(Kind, Parsed) {
	if !(Parsed is Map)
		throw ValueError("SendInputEmit needs a parsed value.")
	if (Kind == "text")
		return SendFinalResult(Parsed["text"], true, true)
	if (Kind == "key")
		return TextPressKey(_SendInputAhkKey(Parsed), [])
	if (Kind != "shortcut")
		throw ValueError("No send-input parameter kind '" . Kind . "'.")
	; primary and ctrl are both Control here; naming it twice would send ^^.
	Names := []
	Seen := Map()
	for _, Id in Parsed["mods"] {
		Name := _SendInputFindEntry(SendInputVocabulary()["modifiers"], Id)["ahk"]
		if !Seen.Has(Name) {
			Seen[Name] := true
			Names.Push(Name)
		}
	}
	return TextPressKey(_SendInputAhkKey(Parsed), Names)
}
