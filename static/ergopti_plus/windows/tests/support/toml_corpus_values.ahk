; tests/support/toml_corpus_values.ahk

; ==============================================================================
; MODULE: TOML Corpus Value Revival
; DESCRIPTION:
; Shared by the TOML corpus consumers. AHK has no boolean type, so JsonParse
; answers 1 for a JSON true and that row would be written and compared as the
; number 1. The typed reading keeps each JSON boolean as a TOML_Bool.
;
; FEATURES & RATIONALE:
; 1. Only the values a consumer hands to the writer or compares with its result
;    come from the typed reading; control fields ("ok", "delete") keep the plain
;    one, where a marker object would read as true whatever it held.
; 2. A section of the shared corpus names a colon segment bare, the Windows
;    callers render that segment quoted (TOML_RenderKey): both name one path.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Parses a corpus with every JSON boolean outside a string marked as {"$bool": ...}.
 * @param {String} Text Corpus source.
 * @returns {Map} Decoded corpus for _TCV_Revive.
 */
_TCV_ParseTyped(Text) {
	return JsonParse(RegExReplace(Text, '"(?:[^"\\]++|\\.)*+"(*SKIP)(*F)|\b(true|false)\b', '{"$bool":"$1"}'))
}

/**
 * Spells a marked value as the writer's native one.
 * @param Value A value of the typed reading.
 * @returns A TOML_Bool, a number, or a copy of the container.
 */
_TCV_Revive(Value) {
	if !(Value is Map || Value is Array)
		return Value
	if Value is Array {
		Out := []
		for Item in Value
			Out.Push(_TCV_Revive(Item))
		return Out
	}
	if Value.Has("$bool")
		return TOML_Bool(Value["$bool"] == "true")
	if Value.Has("$number") {
		Infinity := Float("1e999")
		switch Value["$number"] {
			case "inf": return Infinity
			case "-inf": return -Infinity
			case "nan": return Infinity - Infinity
		}
		return Number(Value["$number"])
	}
	Out := Map()
	Out.CaseSense := "On"
	for Key, Item in Value
		Out[Key] := _TCV_Revive(Item)
	return Out
}

/** Quotes each bare extension identity segment of a corpus section. */
_TCV_Section(Section) {
	return RegExReplace(Section, '(?<=^|\.)(ext:[^."]+)(?=$|\.)', '"$1"')
}

/**
 * Builds writer rows from the plain and the typed reading of one vector's rows.
 * @param {Array} Plain Rows of the plain reading.
 * @param {Array} Typed The same rows of the typed reading.
 * @returns {Array} Writer updates.
 */
_TCV_Rows(Plain, Typed) {
	Rows := []
	for Index, Row in Plain {
		Update := { Section: _TCV_Section(Row["section"]), Key: Row["key"] }
		if (Row.Has("delete") && Row["delete"])
			Update.Delete := 1
		else
			Update.Value := _TCV_Revive(Typed[Index]["value"])
		Rows.Push(Update)
	}
	return Rows
}

/**
 * Compares a candidate with the shared expectation fields.
 * @param {String} Content The candidate, without a BOM the source did not hold.
 * @param {String} Source The vector's source bytes.
 * @param {Map} Expect The plain expect block.
 * @param {Map} TypedExpect The typed expect block.
 * @returns {String} "" when they agree, else the first difference.
 */
_TCV_CandidateDifference(Content, Source, Expect, TypedExpect) {
	if (Expect.Has("content") && !(Content == Expect["content"]))
		return "candidate bytes differ: " . Content
	if (Expect.Has("unchanged") && Expect["unchanged"] && !(Content == Source))
		return "the candidate must equal the source: " . Content
	if Expect.Has("contains") {
		for Part in Expect["contains"]
			if !InStr(Content, Part, true)
				return "missing " . Part
	}
	if Expect.Has("not_contains") {
		for Part in Expect["not_contains"]
			if InStr(Content, Part, true)
				return "must not contain " . Part
	}
	if Expect.Has("decoded") {
		Document := TOML_ParseDocument(Content)
		for Index, Check in Expect["decoded"] {
			Found := _TOML_DocumentLookup(Document, Check["path"])
			Label := ""
			for Key in Check["path"]
				Label .= (Label == "" ? "" : ".") . Key
			if (Check.Has("absent") && Check["absent"]) {
				if Found["found"]
					return Label . " must be absent"
			} else if (!Found["found"] || !TOML_SameValue(Found["value"], _TCV_Revive(TypedExpect["decoded"][Index]["value"]))) {
				return Label . " decoded differently"
			}
		}
	}
	return ""
}

/** Removes the BOM the Windows config writer publishes when the source held none. */
_TCV_WithoutAddedBom(Content, Source) {
	return (SubStr(Content, 1, 1) == Chr(0xFEFF) && SubStr(Source, 1, 1) != Chr(0xFEFF)) ? SubStr(Content, 2) : Content
}
