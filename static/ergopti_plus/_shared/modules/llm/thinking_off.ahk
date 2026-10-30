; _shared/modules/llm/thinking_off.ahk

; ==============================================================================
; MODULE: Thinking Off
; DESCRIPTION:
; Every request Ergopti sends to a model turns its reasoning off, or down to
; the lowest level the model accepts. What a model needs depends on its FAMILY
; (_shared/modules/llm/thinking_off.json); how a request carries it depends on
; the PROVIDER (thinking_dialect of api_providers.json). This module crosses
; the two into body fields and deep-merges them.
;
; FEATURES & RATIONALE:
; 1. A model id is normalized (lowercase, last path segment, an Ollama :tag
;    dropped), so a qwen3 model gets the same family on every provider.
; 2. The first family whose glob (* its only wildcard) matches wins; its first
;    control kind the dialect carries applies, "$level" replaced by the
;    control's level. No family, no control or no kind: nothing is sent.
; 3. The merge works on the JSON text: the drivers write their bodies as
;    text, and JsonParse decodes booleans as 0/1, so the fields travel as
;    their exact source. It is deep, the body wins at every level, and it
;    reports the paths it added, so a provider refusing one of them (HTTP 400
;    naming it) can be asked once more without it.
; 4. A malformed table is refused whole, never half-applied.
; 5. Refused fields persist (LLM_ThinkingOffRefusalsParse / RecordRefusal): a
;    model a provider refused once is not sent that field again, even after
;    a restart, until the refusal expires (refusal_expiry_days), so a later
;    provider fix is picked up. The store is bounded; the driver owns where
;    it lives.
; 6. A family may say its models accept only the default sampling
;    (default_sampling_only): the driver then sends no temperature.
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

; The reasoning control kinds; a toggle carries no level
global LLM_THINKING_OFF_KINDS := Map("toggle", 1, "effort", 1, "anthropic_thinking", 1,
	"anthropic_effort", 1, "gemini_budget", 1, "gemini_level", 1)

; Most (provider, model) pairs whose refusals persist
global LLM_THINKING_OFF_MAX_REFUSALS := 200

; Added keys too generic to name a refusal alone: matched with their parent
global LLM_THINKING_OFF_GENERIC_KEYS := Map("type", 1, "effort", 1, "enabled", 1)





; ======================================
; ======================================
; ======= 2/ Validation ================
; ======================================
; ======================================

/**
 * Validates thinking_off.json.
 * @param {String} Text The file's JSON source.
 * @returns {Array} Families, each Map("models", Array of globs, "controls",
 *     Array of Map("kind", "intent", "level")).
 * @throws {Error} A malformed table, refused whole.
 */
LLM_ThinkingOffParseFamilies(Text) {
	global LLM_THINKING_OFF_GLOB_PATTERN, LLM_THINKING_OFF_KINDS
	Root := JsonParse(Text)
	if !(Root is Map) || !(Root.Get("families", 0) is Array) || Root["families"].Length == 0
		throw ValueError("thinking_off.json holds no families array.")
	Days := Root.Get("refusal_expiry_days", 0)
	if !(Days is Integer) || Days <= 0
		throw ValueError("thinking_off.json refusal_expiry_days must be a positive integer.")
	Families := []
	Families.ExpirySec := Days * 86400
	for Index, Family in Root["families"] {
		Where := "family " . Index
		if !(Family is Map)
			throw ValueError(Where . " is not an object.")
		for Key in Family {
			if (Key != "models" && Key != "controls" && Key != "default_sampling_only" && SubStr(Key, 1, 1) != "_")
				throw ValueError(Where . " has an unknown key " . Key . ".")
		}
		if !(Family.Get("models", 0) is Array) || Family["models"].Length == 0
			throw ValueError(Where . " names no model.")
		for Glob in Family["models"] {
			if !(Glob is String) || !RegExMatch(Glob, LLM_THINKING_OFF_GLOB_PATTERN)
				throw ValueError(Where . " has an invalid glob.")
		}
		if !(Family.Get("controls", 0) is Array)
			throw ValueError(Where . " has no controls array.")
		for Control in Family["controls"] {
			if !(Control is Map) || !LLM_THINKING_OFF_KINDS.Has(Control.Get("kind", ""))
					|| !(Control.Get("intent", "") == "off" || Control.Get("intent", "") == "lowest")
				throw ValueError(Where . " has an invalid control.")
			if (Control["kind"] == "toggle") {
				if Control.Has("level") || Control["intent"] != "off"
					throw ValueError(Where . ": a toggle only turns off.")
			} else if !Control.Has("level") || !(Control["level"] is Number || Control["level"] is String) {
				throw ValueError(Where . ": a " . Control["kind"] . " control needs a level.")
			}
		}
		; JsonParse decodes true as 1: the source table is checked by the JS guard
		Families.Push(Map("models", Family["models"], "controls", Family["controls"],
			"default_sampling_only", Family.Get("default_sampling_only", 0) ? true : false))
	}
	return Families
}

/**
 * Validates a provider's thinking_dialect.
 * @param {String} Text The dialect's JSON source, "" when the provider has none.
 * @returns {Map} Kind -> exact JSON source of its fields template.
 * @throws {Error} A malformed dialect, refused whole.
 */
LLM_ThinkingOffParseDialect(Text) {
	global LLM_THINKING_OFF_KINDS
	Dialect := Map()
	if (Text == "")
		return Dialect
	for Kind, Span in JsonObjectMemberSpans(Text) {
		if (SubStr(Kind, 1, 1) == "_")
			continue
		if !LLM_THINKING_OFF_KINDS.Has(Kind)
			throw ValueError("thinking_dialect has an unknown kind " . Kind . ".")
		if (Span["kind"] != "object") || !_LLM_ThinkingOffFieldsValid(Span["text"])
			throw ValueError("thinking_dialect." . Kind . " has invalid fields.")
		if ((Kind == "toggle") == (InStr(Span["text"], '"$level"', true) > 0))
			throw ValueError("thinking_dialect." . Kind . (Kind == "toggle" ? " cannot hold a level." : " needs a level."))
		Dialect[Kind] := Span["text"]
	}
	return Dialect
}

; Checks body fields: identifier names holding strings, numbers, booleans or
; non-empty objects of the same.
; @param {String} Text The object's JSON source.
; @returns {Boolean}
_LLM_ThinkingOffFieldsValid(Text) {
	global LLM_THINKING_OFF_FIELD_PATTERN
	Members := JsonObjectMemberSpans(Text)
	if (Members.Count == 0)
		return false
	for Name, Span in Members {
		if !RegExMatch(Name, LLM_THINKING_OFF_FIELD_PATTERN)
			return false
		Kind := Span["kind"]
		if (Kind == "object") {
			if !_LLM_ThinkingOffFieldsValid(Span["text"])
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
 * Normalizes a model id for matching: lowercase, its last path segment, an
 * Ollama :tag dropped.
 * @param {String} Model
 * @returns {String}
 */
LLM_ThinkingOffNormalize(Model) {
	Parts := StrSplit(StrLower(String(Model)), "/")
	return StrSplit(Parts[Parts.Length], ":")[1]
}

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
 * Resolves the fields a model needs on a provider.
 * @param {Array} Families LLM_ThinkingOffParseFamilies's output.
 * @param {Map} Dialect LLM_ThinkingOffParseDialect's output.
 * @param {String} Model The model id as the request names it.
 * @param {Map} Refused Top-level field names refused for this provider and model.
 * @param {VarRef} Kind Receives the control kind applied, "" when none.
 * @returns {Map} Map("family", 1-based index or 0, "fields", JSON source or "").
 */
LLM_ThinkingOffResolve(Families, Dialect, Model, Refused := "", &Kind := "") {
	Kind := ""
	Index := _LLM_ThinkingOffFamilyOf(Families, Model)
	if !Index
		return Map("family", 0, "fields", "")
	for Control in Families[Index]["controls"] {
		if !Dialect.Has(Control["kind"])
			continue
		Kind := Control["kind"]
		Fields := Dialect[Kind]
		if Control.Has("level")
			Fields := StrReplace(Fields, '"$level"', Control["level"] is String
				? JsonStringLiteral(Control["level"]) : String(Control["level"]))
		Kept := ""
		for Field, Span in JsonObjectMemberSpans(Fields) {
			if !(Refused is Map && Refused.Has(Field))
				Kept .= (Kept == "" ? "" : ",") . Span["member_text"]
		}
		return Map("family", Index, "fields", Kept == "" ? "" : "{" . Kept . "}")
	}
	return Map("family", Index, "fields", "")
}

; The 1-based index of a model's family, 0 when none matches.
_LLM_ThinkingOffFamilyOf(Families, Model) {
	Name := LLM_ThinkingOffNormalize(Model)
	for Index, Family in Families {
		for Glob in Family["models"] {
			if LLM_ThinkingOffMatches(Glob, Name)
				return Index
		}
	}
	return 0
}

/**
 * Tells whether a model accepts only the default sampling: a request to it
 * must carry no temperature (an HTTP 400 otherwise).
 * @param {Array} Families LLM_ThinkingOffParseFamilies's output.
 * @param {String} Model The model id.
 * @returns {Boolean}
 */
LLM_ThinkingOffDefaultSamplingOnly(Families, Model) {
	Index := _LLM_ThinkingOffFamilyOf(Families, Model)
	return Index ? Families[Index]["default_sampling_only"] : false
}

/**
 * Reads a persisted refusal store: "<provider>|<model>" -> Map field -> the
 * epoch second it was refused. A refusal older than the expiry is forgotten,
 * so a later provider fix is picked up; malformed entries are dropped and
 * counted.
 * @param {Any} Raw The stored value.
 * @param {Number} Now Epoch seconds.
 * @param {Number} ExpirySec Lifetime of a refusal (the families' ExpirySec).
 * @param {VarRef} Dropped Receives how many entries were not kept.
 * @returns {Map} Key -> Map field -> epoch second.
 */
LLM_ThinkingOffRefusalsParse(Raw, Now, ExpirySec, &Dropped := 0) {
	global LLM_THINKING_OFF_FIELD_PATTERN, LLM_THINKING_OFF_MAX_REFUSALS
	Refused := Map(), Dropped := 0
	if !(Raw is Map) {
		Dropped := (Raw is String && Raw == "") ? 0 : 1
		return Refused
	}
	for Key, Fields in Raw {
		Set := Map()
		if (Key is String) && InStr(Key, "|") && (Fields is Map) && Refused.Count < LLM_THINKING_OFF_MAX_REFUSALS {
			for Field, At in Fields {
				if (Field is String) && RegExMatch(Field, LLM_THINKING_OFF_FIELD_PATTERN) && (At is Number)
						&& Now - At < ExpirySec && At <= Now
					Set[Field] := At
			}
		}
		if (Set.Count > 0)
			Refused[Key] := Set
		else
			Dropped += 1
	}
	return Refused
}

/**
 * Records a refused field at a time; a full store refuses a new pair.
 * @param {Map} Refused Key -> Map field -> epoch second, changed in place.
 * @param {Number} Now Epoch seconds.
 * @returns {Boolean} False when the store is full.
 */
LLM_ThinkingOffRecordRefusal(Refused, Provider, Model, Field, Now) {
	global LLM_THINKING_OFF_MAX_REFUSALS
	Key := Provider . "|" . Model
	if !Refused.Has(Key) {
		if (Refused.Count >= LLM_THINKING_OFF_MAX_REFUSALS)
			return false
		Refused[Key] := Map()
	}
	Refused[Key][Field] := Now
	return true
}





; ======================================
; ======================================
; ======= 4/ Merge And Refusal =========
; ======================================
; ======================================

/**
 * Deep-merges a fields object into a JSON object, on their text; the body
 * wins at every level. Also merges a local server's request_fields.
 * @param {String} BodyText The body's JSON source.
 * @param {String} FieldsText The fields object's JSON source.
 * @param {VarRef} Added Receives the paths added, each an Array of names.
 * @returns {String} The merged body.
 */
LLM_ThinkingOffMerge(BodyText, FieldsText, &Added := "") {
	Added := []
	return _LLM_ThinkingOffMergeAt(BodyText, FieldsText, [], Added)
}

_LLM_ThinkingOffMergeAt(BodyText, FieldsText, Prefix, Added) {
	Body := JsonObjectMemberSpans(BodyText)
	Edits := []
	Appended := ""
	for Name, Span in JsonObjectMemberSpans(FieldsText) {
		Path := Prefix.Clone()
		Path.Push(Name)
		if !Body.Has(Name) {
			Appended .= "," . JsonStringLiteral(Name) . ":" . Span["text"]
			Added.Push(Path)
			continue
		}
		Existing := Body[Name]
		if (Existing["kind"] == "object" && Span["kind"] == "object")
			Edits.Push(Map("start", Existing["start"], "length", Existing["length"],
				"text", _LLM_ThinkingOffMergeAt(Existing["text"], Span["text"], Path, Added)))
	}
	Result := _LLM_ThinkingOffSplice(BodyText, Edits)
	if (Appended == "")
		return Result
	if (Body.Count == 0)
		Appended := SubStr(Appended, 2)
	Close := InStr(Result, "}", true, -1)
	return SubStr(Result, 1, Close - 1) . Appended . SubStr(Result, Close)
}

; Replaces spans of a text from the last one back, so earlier offsets hold.
_LLM_ThinkingOffSplice(Text, Edits) {
	while (Edits.Length > 0) {
		Latest := 1
		for Index, Candidate in Edits {
			if (Candidate["start"] > Edits[Latest]["start"])
				Latest := Index
		}
		Splice := Edits.RemoveAt(Latest)
		Text := SubStr(Text, 1, Splice["start"] - 1) . Splice["text"]
			. SubStr(Text, Splice["start"] + Splice["length"])
	}
	return Text
}

/**
 * Applies a model's family through a provider's dialect to a body.
 * @param {Array} Families LLM_ThinkingOffParseFamilies's output.
 * @param {Map} Dialect LLM_ThinkingOffParseDialect's output.
 * @param {String} Model The model id.
 * @param {String} BodyText The body's JSON source.
 * @param {Map} Refused Refused top-level field names for this provider and model.
 * @param {VarRef} Family Receives the matching family, 0 when none.
 * @param {VarRef} Kind Receives the control kind applied, "" when none.
 * @param {VarRef} Added Receives the paths added.
 * @returns {String} The body.
 */
LLM_ThinkingOffApply(Families, Dialect, Model, BodyText, Refused := "", &Family := 0, &Kind := "", &Added := "") {
	Added := []
	Resolved := LLM_ThinkingOffResolve(Families, Dialect, Model, Refused, &Kind)
	Family := Resolved["family"]
	return Resolved["fields"] == "" ? BodyText : LLM_ThinkingOffMerge(BodyText, Resolved["fields"], &Added)
}

; Tells whether a lowercase message names a key, snake or camel case.
_LLM_ThinkingOffNames(Text, Name) {
	Snake := StrLower(RegExReplace(Name, "([a-z])([A-Z])", "$1_$2"))
	return InStr(Text, StrLower(Name), true) || InStr(Text, Snake, true)
}

/**
 * Names the top-level field a provider refused, when its HTTP 400 message
 * names a key LLM_ThinkingOffApply added (a generic leaf as parent.leaf).
 * @param {Integer} Status The HTTP status.
 * @param {String} Message The provider's error message.
 * @param {Array} Added The paths added.
 * @returns {String} The refused top-level field, "" when none.
 */
LLM_ThinkingOffRefusedField(Status, Message, Added) {
	global LLM_THINKING_OFF_GENERIC_KEYS
	if !(Status is Number) || Status != 400 || !(Message is String) || !(Added is Array)
		return ""
	Text := StrLower(Message)
	for Path in Added {
		Leaf := Path[Path.Length]
		Key := (LLM_THINKING_OFF_GENERIC_KEYS.Has(Leaf) && Path.Length > 1) ? Path[Path.Length - 1] . "." . Leaf : Leaf
		if _LLM_ThinkingOffNames(Text, Key)
			return Path[1]
	}
	return ""
}

/**
 * Removes the added paths under a refused top-level field.
 * @param {String} BodyText The body's JSON source.
 * @param {Array} Added The paths added.
 * @param {String} Field The refused top-level field.
 * @returns {String} The body without them.
 */
LLM_ThinkingOffStrip(BodyText, Added, Field) {
	for Path in Added {
		if (Path[1] == Field)
			BodyText := _LLM_ThinkingOffRemove(BodyText, Path, 1)
	}
	return BodyText
}

; Removes one path from a JSON object's text.
_LLM_ThinkingOffRemove(Text, Path, Depth) {
	Members := JsonObjectMemberSpans(Text)
	Name := Path[Depth]
	if !Members.Has(Name)
		return Text
	if (Depth < Path.Length) {
		Member := Members[Name]
		if (Member["kind"] != "object")
			return Text
		return _LLM_ThinkingOffSplice(Text, [Map("start", Member["start"], "length", Member["length"],
			"text", _LLM_ThinkingOffRemove(Member["text"], Path, Depth + 1))])
	}
	Kept := ""
	for Key, Member in Members {
		if (Key != Name)
			Kept .= (Kept == "" ? "" : ",") . Member["member_text"]
	}
	return "{" . Kept . "}"
}
