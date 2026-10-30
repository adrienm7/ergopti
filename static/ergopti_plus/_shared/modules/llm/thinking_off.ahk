; _shared/modules/llm/thinking_off.ahk

; ==============================================================================
; MODULE: Thinking Off
; DESCRIPTION:
; Every request Ergopti sends to a cloud model turns its reasoning off, or down
; to the lowest level the model accepts. Each provider of api_providers.json
; lists, in `thinking_off`, ordered rules { models: [glob], fields: {...} };
; this module picks the rule of a model and deep-merges its fields into a
; request body.
;
; FEATURES & RATIONALE:
; 1. A glob matches the whole model id, case-insensitively; * is its only
;    wildcard. The first matching rule wins and no match adds nothing: an
;    unknown field is an HTTP 400 on a strict endpoint.
; 2. A rule with empty fields matches and adds nothing: it shields a model a
;    broader glob below would otherwise reach.
; 3. The merge works on the JSON text: the drivers write their bodies as
;    text, and JsonParse decodes booleans as 0/1, so the fields travel as
;    their exact source. It is deep and the body wins at every level.
; 4. A malformed rule list is refused whole, never half-applied.
;
; The shared Lua implementation is _shared/lua/llm/thinking_off.lua. Both
; replay _shared/tests/corpus/llm/thinking_off_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Constants =================
; ======================================
; ======================================

; Characters a glob may hold: model ids plus the * wildcard
global LLM_THINKING_OFF_GLOB_PATTERN := "^[A-Za-z0-9._:/@+*-]+$"

; A body field name: what every provider dialect uses
global LLM_THINKING_OFF_FIELD_PATTERN := "^[A-Za-z_][A-Za-z0-9_]*$"





; ======================================
; ======================================
; ======= 2/ Validation ================
; ======================================
; ======================================

/**
 * Validates a provider's thinking_off list.
 * @param {String} Text The list's JSON source, "" when the provider has none.
 * @returns {Array} Rules, each Map("models", Array of globs, "fields", the
 *     exact JSON source of its fields object).
 * @throws {Error} A malformed list, refused whole.
 */
LLM_ThinkingOffParse(Text) {
	global LLM_THINKING_OFF_GLOB_PATTERN
	Rules := []
	if (Text == "")
		return Rules
	for Index, Span in JsonArrayElementSpans(Text) {
		if !(Span["value"] is Map)
			throw ValueError("thinking_off rule " . Index . " is not an object.")
		Members := JsonObjectMemberSpans(Span["text"])
		for Key in Members {
			if (Key != "models" && Key != "fields" && SubStr(Key, 1, 1) != "_")
				throw ValueError("thinking_off rule " . Index . " has an unknown key " . Key . ".")
		}
		if !Members.Has("models") || Members["models"]["kind"] != "array"
			throw ValueError("thinking_off rule " . Index . " names no model.")
		Models := JsonParse(Members["models"]["text"])
		if (Models.Length == 0)
			throw ValueError("thinking_off rule " . Index . " names no model.")
		for Glob in Models {
			if !(Glob is String) || !RegExMatch(Glob, LLM_THINKING_OFF_GLOB_PATTERN)
				throw ValueError("thinking_off rule " . Index . " has an invalid glob.")
		}
		if !Members.Has("fields") || Members["fields"]["kind"] != "object"
				|| !_LLM_ThinkingOffFieldsValid(Members["fields"]["text"], true)
			throw ValueError("thinking_off rule " . Index . " has invalid fields.")
		Rules.Push(Map("models", Models, "fields", Members["fields"]["text"]))
	}
	return Rules
}

; Checks a fields object: identifier names holding strings, numbers, booleans
; or non-empty objects of the same.
; @param {String} Text The object's JSON source.
; @param {Boolean} AllowEmpty True at the top level only.
; @returns {Boolean}
_LLM_ThinkingOffFieldsValid(Text, AllowEmpty) {
	global LLM_THINKING_OFF_FIELD_PATTERN
	Members := JsonObjectMemberSpans(Text)
	if (!AllowEmpty && Members.Count == 0)
		return false
	for Name, Span in Members {
		if !RegExMatch(Name, LLM_THINKING_OFF_FIELD_PATTERN)
			return false
		Kind := Span["kind"]
		if (Kind == "object") {
			if !_LLM_ThinkingOffFieldsValid(Span["text"], false)
				return false
		} else if (Kind != "string" && Kind != "number" && Kind != "boolean") {
			return false
		}
	}
	return true
}





; ======================================
; ======================================
; ======= 3/ Matching ==================
; ======================================
; ======================================

/**
 * Tells whether a glob matches a whole model id, ignoring case.
 * @param {String} Glob Pattern whose only wildcard is *.
 * @param {String} Model The model id.
 * @returns {Boolean}
 */
LLM_ThinkingOffMatches(Glob, Model) {
	if !(Glob is String) || !(Model is String)
		return false
	Pattern := StrLower(Glob), Subject := StrLower(Model)
	Parts := StrSplit(Pattern, "*")
	if (Parts.Length == 1)
		return Subject == Pattern
	First := Parts[1], Last := Parts[Parts.Length]
	if (SubStr(Subject, 1, StrLen(First)) != First)
		return false
	Position := StrLen(First) + 1
	loop Parts.Length - 2 {
		Part := Parts[A_Index + 1]
		; An empty part (two stars in a row) matches where it stands
		if (Part == "")
			continue
		Found := Position <= StrLen(Subject) ? InStr(Subject, Part, true, Position) : 0
		if !Found
			return false
		Position := Found + StrLen(Part)
	}
	Tail := StrLen(Subject) - StrLen(Last) + 1
	return Tail >= Position && SubStr(Subject, Tail) == Last
}

/**
 * Finds the rule of a model.
 * @param {Array} Rules LLM_ThinkingOffParse's output.
 * @param {String} Model The model id.
 * @returns {Integer} 1-based index of the first matching rule, 0 when none.
 */
LLM_ThinkingOffResolve(Rules, Model) {
	for Index, Rule in Rules {
		for Glob in Rule["models"] {
			if LLM_ThinkingOffMatches(Glob, Model)
				return Index
		}
	}
	return 0
}





; ======================================
; ======================================
; ======= 4/ Merge =====================
; ======================================
; ======================================

/**
 * Deep-merges a fields object into a JSON object, on their text; the body
 * wins at every level. Also merges a local server's request_fields.
 * @param {String} BodyText The body's JSON source.
 * @param {String} FieldsText The fields object's JSON source.
 * @returns {String} The merged body.
 */
LLM_ThinkingOffMerge(BodyText, FieldsText) {
	Body := JsonObjectMemberSpans(BodyText)
	Edits := []
	Added := ""
	for Name, Span in JsonObjectMemberSpans(FieldsText) {
		if !Body.Has(Name) {
			Added .= "," . JsonStringLiteral(Name) . ":" . Span["text"]
			continue
		}
		Existing := Body[Name]
		if (Existing["kind"] == "object" && Span["kind"] == "object")
			Edits.Push(Map("start", Existing["start"], "length", Existing["length"],
				"text", LLM_ThinkingOffMerge(Existing["text"], Span["text"])))
	}
	; Splice the nested merges from the last one back, so earlier offsets hold
	Result := BodyText
	while (Edits.Length > 0) {
		Latest := 1
		for Index, Candidate in Edits {
			if (Candidate["start"] > Edits[Latest]["start"])
				Latest := Index
		}
		Splice := Edits.RemoveAt(Latest)
		Result := SubStr(Result, 1, Splice["start"] - 1) . Splice["text"]
			. SubStr(Result, Splice["start"] + Splice["length"])
	}
	if (Added == "")
		return Result
	if (Body.Count == 0)
		Added := SubStr(Added, 2)
	Close := InStr(Result, "}", true, -1)
	return SubStr(Result, 1, Close - 1) . Added . SubStr(Result, Close)
}

/**
 * Applies a model's rule to a body.
 * @param {Array} Rules LLM_ThinkingOffParse's output.
 * @param {String} Model The model id.
 * @param {String} BodyText The body's JSON source.
 * @param {VarRef} Index Receives the rule applied, 0 when none matched.
 * @returns {String} The body, merged when a rule matched.
 */
LLM_ThinkingOffApply(Rules, Model, BodyText, &Index := 0) {
	Index := LLM_ThinkingOffResolve(Rules, Model)
	return Index ? LLM_ThinkingOffMerge(BodyText, Rules[Index]["fields"]) : BodyText
}
