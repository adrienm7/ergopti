; modules/shortcuts/workflows/model.ahk

; ==============================================================================
; MODULE: User Workflow Model (Windows)
; DESCRIPTION:
; The AutoHotkey port of _shared/shortcuts/engine/workflows/model.lua: the
; check of a user workflow file against
; _shared/shortcuts/data/workflows/steps.json, the placeholder expansion of
; step texts, the digest a shell approval is bound to and the JSON writer of a
; checked document. The canonical JS check (_shared/ui/workflow_model.js) and
; the Lua model replay the same _shared/tests/corpus/workflows/ vectors.
;
; FEATURES & RATIONALE:
; 1. One deterministic order: a Map enumerates its string keys in ordinal
;    order, which is the sorted order the Lua and JS checks visit, so the
;    first refusal and its JSON Pointer are theirs.
; 2. A document is decoded with JsonParseLossless: a boolean is never read as
;    the integer 1, and null stays apart from an absent key.
; 3. Byte bounds count UTF-8 bytes (NativeTextUtf8Length), as the Lua model's
;    string lengths do, never UTF-16 units.
; 4. A key combination uses the send_shortcut grammar of send_keys.json
;    (SendKeysParseShortcut), never a second vocabulary.
; 5. Pure: no logger, no i18n, no I/O; callers report and localize.
; ==============================================================================

#Requires AutoHotkey v2.0

; The patterns this port spells by hand, held to the catalogue's text.
global WORKFLOW_EXPECTED_PATTERNS := Map(
	"identifier_pattern", "^[A-Za-z_][A-Za-z0-9_]{0,31}$",
	"workflow_id_pattern", "^[A-Za-z0-9_-]{1,64}$")

; The same patterns as PCRE: D makes $ the true end, never before a final newline.
global WORKFLOW_IDENTIFIER_REGEX := "D)^[A-Za-z_][A-Za-z0-9_]{0,31}$"
global WORKFLOW_ID_REGEX := "D)^[A-Za-z0-9_-]{1,64}$"

; An action name of a run_action step: a catalogue id of at most 64 bytes.
global WORKFLOW_ACTION_REGEX := "D)^[a-z][a-z0-9_]{0,63}$"
global WORKFLOW_BASE64_REGEX := "D)^[A-Za-z0-9+/]+=?=?$"
global WORKFLOW_BASE64_QUANTUM := 4

; The control code units a field refuses, and the ones a multiline text keeps.
global WORKFLOW_LAST_CONTROL_UNIT := 31
global WORKFLOW_DELETE_UNIT := 127
global WORKFLOW_MULTILINE_UNITS := Map(9, true, 10, true, 13, true)

/**
 * A refusal of the checker: its closed reason and the JSON Pointer it names.
 */
class WorkflowRefusal extends Error {
	__New(Reason, Path) {
		super.__New("workflow refused: " . Reason . " at " . Path)
		this.Reason := Reason
		this.Path := Path
	}
}




; ===================================
; ===================================
; ======= 1/ Value shapes ===========
; ===================================
; ===================================

; @returns {String} Where the catalogue lives under _shared/.
WorkflowCataloguePath() {
	return "shortcuts\data\workflows\steps.json"
}

; @returns {Boolean} Whether Value is a decoded JSON object.
_WorkflowIsObject(Value) {
	return Value is Map
}

; @returns {Boolean} Whether Value is an integral finite number (never a boolean sentinel).
_WorkflowIsInteger(Value) {
	if Value is Integer
		return true
	if !(Value is Float)
		return false
	; The JSON decoder refuses NaN and the infinities: only the fraction is left to check.
	return Value == Floor(Value)
}

; @returns {Integer} The UTF-8 size of a string, embedded NULs included.
WorkflowUtf8Bytes(Text) {
	return NativeTextUtf8Length(StrPtr(Text), StrLen(Text))
}

; @returns {Boolean} Whether a string holds a control code unit a field refuses.
_WorkflowHasForbiddenControl(Text, Multiline) {
	global WORKFLOW_LAST_CONTROL_UNIT, WORKFLOW_DELETE_UNIT, WORKFLOW_MULTILINE_UNITS
	Address := StrPtr(Text)
	loop StrLen(Text) {
		Unit := NumGet(Address, (A_Index - 1) * 2, "UShort")
		if Unit == WORKFLOW_DELETE_UNIT
			return true
		if Unit <= WORKFLOW_LAST_CONTROL_UNIT && !(Multiline && WORKFLOW_MULTILINE_UNITS.Has(Unit))
			return true
	}
	return false
}

; Escapes one JSON Pointer segment (RFC 6901).
_WorkflowPointerSegment(Segment) {
	return StrReplace(StrReplace(String(Segment), "~", "~0"), "/", "~1")
}

; @returns {Boolean} Whether Value is a string matching the variable name pattern.
WorkflowIsIdentifier(Value) {
	global WORKFLOW_IDENTIFIER_REGEX
	return (Value is String) && RegExMatch(Value, WORKFLOW_IDENTIFIER_REGEX) > 0
}

; @returns {Boolean} Whether Value is a string matching the workflow id pattern.
WorkflowIsId(Value) {
	global WORKFLOW_ID_REGEX
	return (Value is String) && RegExMatch(Value, WORKFLOW_ID_REGEX) > 0
}

; @returns {Boolean} Whether a catalogue Map holds a true flag (a plain decode reads true as 1).
_WorkflowFlag(Spec, Name) {
	return Spec.Has(Name) && (Spec[Name] is Integer) && Spec[Name] == 1
}




; ===================================
; ===================================
; ======= 2/ Checker ================
; ===================================
; ===================================

; Raises unless the catalogue is the decoded steps.json this port reads.
_WorkflowRequireCatalogue(Catalogue) {
	global WORKFLOW_EXPECTED_PATTERNS
	if !(Catalogue is Map) || !Catalogue.Has("kinds") || !(Catalogue["kinds"] is Map)
			|| !Catalogue.Has("limits") || !(Catalogue["limits"] is Map)
		throw ValueError("The workflow catalogue is not the decoded steps.json.", -2)
	for Name, Pattern in WORKFLOW_EXPECTED_PATTERNS
		if Catalogue.Get(Name, "") !== Pattern
			throw ValueError("steps.json changed " . Name . "; port the new pattern.", -2)
}

/**
 * The check of one catalogue and context, as model.lua's new_checker builds it.
 */
class WorkflowChecker {
	/**
	 * @param {Map} Catalogue Decoded steps.json (JsonParse).
	 * @param {Map} Timings The registry bounds a field may name ("wait_max_ms").
	 */
	__New(Catalogue, Timings) {
		_WorkflowRequireCatalogue(Catalogue)
		if !(Timings is Map)
			throw TypeError("A workflow check needs the registry timings.", -1)
		this.Catalogue := Catalogue
		this.Limits := Catalogue["limits"]
		this.Timings := Timings
		this.Reasons := Map()
		for Reason in Catalogue["reasons"]
			this.Reasons[Reason] := true
	}

	Refuse(Reason, Path) {
		if !this.Reasons.Has(Reason)
			throw ValueError("Undeclared workflow refusal " . Reason . ".", -1)
		throw WorkflowRefusal(Reason, Path)
	}

	Bound(Name) {
		if this.Limits.Has(Name)
			return this.Limits[Name]
		if this.Timings.Has(Name)
			return this.Timings[Name]
		throw ValueError("No workflow bound named " . Name . ".", -1)
	}

	CheckKeys(Value, Allowed, Path) {
		for Key in Value
			if !Allowed.Has(Key)
				this.Refuse("unknown_key", Path . "/" . _WorkflowPointerSegment(Key))
	}

	CheckText(Value, Spec, Path, Maximum) {
		if !(Value is String)
			this.Refuse("bad_type", Path)
		if !NativeTextIsWellFormedUtf16(StrPtr(Value), StrLen(Value))
			this.Refuse("bad_text", Path)
		if WorkflowUtf8Bytes(Value) > Maximum
			this.Refuse("too_long", Path)
		if Value == "" && !_WorkflowFlag(Spec, "allow_empty")
			this.Refuse("bad_text", Path)
		if _WorkflowHasForbiddenControl(Value, _WorkflowFlag(Spec, "multiline"))
			this.Refuse("bad_text", Path)
	}

	CheckFields(Value, Fields, Path, State) {
		for Name, Spec in Fields {
			FieldPath := Path . "/" . _WorkflowPointerSegment(Name)
			if !Value.Has(Name) {
				if _WorkflowFlag(Spec, "required")
					this.Refuse("missing_field", FieldPath)
			} else
				this.CheckValue(Value[Name], Spec, FieldPath, State)
		}
	}

	CheckTyped(Value, TableOfTypes, Path, State) {
		if !_WorkflowIsObject(Value)
			this.Refuse("not_object", Path)
		if !Value.Has("type")
			this.Refuse("missing_field", Path . "/type")
		if !(Value["type"] is String)
			this.Refuse("bad_type", Path . "/type")
		if !TableOfTypes.Has(Value["type"])
			this.Refuse("bad_enum", Path . "/type")
		Declared := TableOfTypes[Value["type"]]
		Fields := Declared.Has("fields") ? Declared["fields"] : Declared
		Allowed := Map("type", true)
		for Name in Fields
			Allowed[Name] := true
		this.CheckKeys(Value, Allowed, Path)
		this.CheckFields(Value, Fields, Path, State)
		if Value["type"] == "matches" {
			if Value["source"] == "variable" && !Value.Has("variable")
				this.Refuse("variable_required", Path . "/variable")
			if Value["op"] !== "empty" && !Value.Has("value")
				this.Refuse("value_required", Path . "/value")
		}
	}

	CheckValue(Value, Spec, Path, State) {
		global WORKFLOW_ACTION_REGEX
		Kind := Spec["type"]
		switch Kind, true {
			case "text":
				this.CheckText(Value, Spec, Path, this.Limits["text_bytes"])
			case "shortcut":
				if !(Value is String)
					this.Refuse("bad_type", Path)
				if !(SendKeysParseShortcut(Value) is Map)
					this.Refuse("bad_shortcut", Path)
			case "integer":
				if !_WorkflowIsInteger(Value)
					this.Refuse("bad_type", Path)
				Maximum := Spec.Has("max_limit") ? this.Bound(Spec["max_limit"]) : Spec["max"]
				if Value < Spec["min"] || Value > Maximum
					this.Refuse("out_of_range", Path)
			case "enum":
				if !(Value is String)
					this.Refuse("bad_type", Path)
				Found := false
				for Allowed in Spec["values"]
					Found := Found || Allowed == Value
				if !Found
					this.Refuse("bad_enum", Path)
			case "variable":
				if !(Value is String)
					this.Refuse("bad_type", Path)
				if !WorkflowIsIdentifier(Value)
					this.Refuse("bad_identifier", Path)
				if !State["variables"].Has(Value)
					State["variables"][Value] := true
				if State["variables"].Count > this.Limits["variables_max"]
					this.Refuse("too_many_variables", Path)
			case "action":
				if !(Value is String)
					this.Refuse("bad_type", Path)
				if !RegExMatch(Value, WORKFLOW_ACTION_REGEX)
					this.Refuse("bad_identifier", Path)
			case "image":
				if !(Value is String)
					this.Refuse("bad_type", Path)
				if !WorkflowIsIdentifier(Value)
					this.Refuse("bad_identifier", Path)
				if !State["images"].Has(Value)
					this.Refuse("unknown_image", Path)
			case "target":
				this.CheckTyped(Value, this.Catalogue["targets"], Path, State)
			case "condition":
				this.CheckTyped(Value, this.Catalogue["conditions"], Path, State)
			case "steps":
				this.CheckSteps(Value, Path, State["depth"] + 1, State)
			default:
				throw ValueError("No workflow field type " . Kind . ".", -1)
		}
	}

	CheckStep(Step, Path, Depth, State) {
		if !_WorkflowIsObject(Step)
			this.Refuse("not_object", Path)
		if Depth > this.Limits["depth_max"]
			this.Refuse("too_deep", Path)
		State["count"] += 1
		if State["count"] > this.Limits["steps_max"]
			this.Refuse("too_many_steps", State["steps_path"])
		if !Step.Has("kind")
			this.Refuse("missing_field", Path . "/kind")
		if !(Step["kind"] is String)
			this.Refuse("bad_type", Path . "/kind")
		if !this.Catalogue["kinds"].Has(Step["kind"])
			this.Refuse("unknown_kind", Path . "/kind")
		Declared := this.Catalogue["kinds"][Step["kind"]]
		Allowed := Map()
		for Name in this.Catalogue["common_step_keys"]
			Allowed[Name] := true
		for Name in Declared["fields"]
			Allowed[Name] := true
		this.CheckKeys(Step, Allowed, Path)
		if Step.Has("note")
			this.CheckText(Step["note"], Map(), Path . "/note", this.Limits["name_bytes"])
		Outer := State["depth"]
		State["depth"] := Depth
		this.CheckFields(Step, Declared["fields"], Path, State)
		State["depth"] := Outer
	}

	CheckSteps(List, Path, Depth, State) {
		if !(List is Array)
			this.Refuse("bad_type", Path)
		for Index, Step in List
			this.CheckStep(Step, Path . "/" . (Index - 1), Depth, State)
	}

	CheckImages(Images, Path) {
		global WORKFLOW_BASE64_REGEX, WORKFLOW_BASE64_QUANTUM
		if !_WorkflowIsObject(Images)
			this.Refuse("not_object", Path)
		if Images.Count > this.Limits["images_max"]
			this.Refuse("too_many_images", Path)
		Prefix := this.Catalogue["png_base64_prefix"]
		for Name, Data in Images {
			ImagePath := Path . "/" . _WorkflowPointerSegment(Name)
			if !WorkflowIsIdentifier(Name)
				this.Refuse("bad_identifier", ImagePath)
			if !(Data is String)
				this.Refuse("bad_type", ImagePath)
			if WorkflowUtf8Bytes(Data) > this.Limits["image_base64_bytes"]
				this.Refuse("too_long", ImagePath)
			if !RegExMatch(Data, WORKFLOW_BASE64_REGEX) || Mod(StrLen(Data), WORKFLOW_BASE64_QUANTUM) != 0
					|| SubStr(Data, 1, StrLen(Prefix)) !== Prefix
				this.Refuse("bad_image", ImagePath)
		}
	}

	CheckWorkflow(Workflow, Path) {
		if !_WorkflowIsObject(Workflow)
			this.Refuse("not_object", Path)
		Allowed := Map()
		for Name in this.Catalogue["workflow_keys"]
			Allowed[Name] := true
		this.CheckKeys(Workflow, Allowed, Path)
		for Name in ["id", "name", "origin", "steps"]
			if !Workflow.Has(Name)
				this.Refuse("missing_field", Path . "/" . Name)
		if !(Workflow["id"] is String)
			this.Refuse("bad_type", Path . "/id")
		if !WorkflowIsId(Workflow["id"])
			this.Refuse("bad_identifier", Path . "/id")
		this.CheckText(Workflow["name"], Map(), Path . "/name", this.Limits["name_bytes"])
		if !(Workflow["origin"] is String)
			this.Refuse("bad_type", Path . "/origin")
		Known := false
		for Origin in this.Catalogue["origins"]
			Known := Known || Origin == Workflow["origin"]
		if !Known
			this.Refuse("bad_enum", Path . "/origin")
		Images := Workflow.Has("images") ? Workflow["images"] : Map()
		if Workflow.Has("images")
			this.CheckImages(Images, Path . "/images")
		State := Map("count", 0, "depth", 0, "images", Images, "variables", Map(), "steps_path", Path . "/steps")
		this.CheckSteps(Workflow["steps"], Path . "/steps", 1, State)
	}

	CheckFile(Doc) {
		if !_WorkflowIsObject(Doc)
			this.Refuse("not_object", "")
		this.CheckKeys(Doc, Map("schema_version", true, "workflows", true), "")
		Version := Doc.Get("schema_version", "")
		if !(Version is Number) || Version != this.Catalogue["schema_version"]
			this.Refuse("schema_version", "/schema_version")
		if !Doc.Has("workflows")
			this.Refuse("missing_field", "/workflows")
		if !(Doc["workflows"] is Array)
			this.Refuse("bad_type", "/workflows")
		if Doc["workflows"].Length > this.Limits["workflows_max"]
			this.Refuse("too_many_workflows", "/workflows")
		Seen := Map()
		for Index, Workflow in Doc["workflows"] {
			Path := "/workflows/" . (Index - 1)
			this.CheckWorkflow(Workflow, Path)
			if Seen.Has(Workflow["id"])
				this.Refuse("duplicate_id", Path . "/id")
			Seen[Workflow["id"]] := true
		}
	}

	; Runs one check and turns a refusal into a result; any other error propagates.
	Outcome(Method, Args*) {
		try Method.Call(this, Args*)
		catch WorkflowRefusal as Refusal
			return Map("ok", false, "reason", Refusal.Reason, "path", Refusal.Path)
		return Map("ok", true)
	}
}




; ===================================
; ===================================
; ======= 3/ Public API =============
; ===================================
; ===================================

/**
 * Checks a whole workflow file, decoded with JsonParseLossless.
 * @param {Any} Doc
 * @param {Map} Catalogue Decoded steps.json.
 * @param {Map} Timings The registry bounds ("wait_max_ms").
 * @returns {Map} "ok", and "reason" and "path" of the first refusal.
 */
WorkflowValidateFile(Doc, Catalogue, Timings) {
	Checker := WorkflowChecker(Catalogue, Timings)
	return Checker.Outcome(WorkflowChecker.Prototype.CheckFile, Doc)
}

/**
 * Checks one workflow, its refusal path rooted at the workflow.
 * @param {Any} Workflow
 * @param {Map} Catalogue Decoded steps.json.
 * @param {Map} Timings The registry bounds ("wait_max_ms").
 * @returns {Map} "ok", and "reason" and "path" of the first refusal.
 */
WorkflowValidate(Workflow, Catalogue, Timings) {
	Checker := WorkflowChecker(Catalogue, Timings)
	return Checker.Outcome(WorkflowChecker.Prototype.CheckWorkflow, Workflow, "")
}

/**
 * Expands the {{name}} placeholders of a step text. A {{ that does not open
 * an identifier closed by }} stays text; a value is never expanded again.
 * @param {String} Text
 * @param {Map} Variables Name -> string.
 * @param {String} Missing Set to the first unknown variable name.
 * @returns {String|Integer} The expanded text, or 0 when a variable is unknown.
 */
WorkflowExpand(Text, Variables, &Missing := "") {
	Missing := ""
	Out := ""
	Index := 1
	loop {
		Open := InStr(Text, "{{", true, Index)
		if !Open {
			Out .= SubStr(Text, Index)
			break
		}
		Close := InStr(Text, "}}", true, Open + 2)
		Name := Close ? SubStr(Text, Open + 2, Close - Open - 2) : ""
		if Close && WorkflowIsIdentifier(Name) {
			if !Variables.Has(Name) {
				Missing := Name
				return 0
			}
			Out .= SubStr(Text, Index, Open - Index) . Variables[Name]
			Index := Close + 2
		} else {
			Out .= SubStr(Text, Index, Open + 2 - Index)
			Index := Open + 2
		}
	}
	return Out
}

/**
 * The shell commands of some steps, in document order (then before else).
 * @param {Array} Steps
 * @param {Array} Out Accumulator.
 * @returns {Array}
 */
WorkflowShellCommands(Steps, Out := 0) {
	if !(Out is Array)
		Out := []
	for Step in Steps {
		if Step["kind"] == "shell"
			Out.Push(Step["command"])
		if Step["kind"] == "if" {
			WorkflowShellCommands(Step["then"], Out)
			if Step.Has("else")
				WorkflowShellCommands(Step["else"], Out)
		} else if Step["kind"] == "repeat"
			WorkflowShellCommands(Step["steps"], Out)
	}
	return Out
}

/**
 * The digest a shell approval is bound to: SHA-256 of the workflow id, then
 * each shell command after a NUL byte, in document order. Any edit of a
 * command, or another id, changes it.
 * @param {Map} Workflow A valid workflow.
 * @returns {String} 64 lowercase hex characters, "" without a shell step.
 */
WorkflowShellDigest(Workflow) {
	Commands := WorkflowShellCommands(Workflow["steps"])
	if Commands.Length == 0
		return ""
	Parts := [Workflow["id"]]
	Parts.Push(Commands*)
	Size := Parts.Length - 1
	for Part in Parts
		Size += WorkflowUtf8Bytes(Part)
	Bytes := Buffer(Max(Size, 1), 0)
	Offset := 0
	for Index, Part in Parts {
		if Index > 1
			Offset += 1  ; the NUL separator, already zero
		; An id or a checked command holds no NUL, so StrPut converts it whole.
		Length := WorkflowUtf8Bytes(Part)
		if Length > 0
			StrPut(Part, Bytes.Ptr + Offset, Length, "UTF-8")
		Offset += Length
	}
	Digest := CryptoSha256Bytes(Bytes)
	if !RegExMatch(Digest, "D)^[0-9a-f]{64}$")
		throw OSError("The shell digest of a workflow could not be computed.", -1)
	return Digest
}

/**
 * Encodes a checked workflow document, or an editor payload, as JSON: Map,
 * Array, String, Integer, Float, JSON_NULL, JSON_TRUE and JSON_FALSE.
 * @param {Any} Value
 * @returns {String}
 */
WorkflowJsonEncode(Value) {
	global JSON_NULL, JSON_TRUE, JSON_FALSE
	if Value is String
		return JsonStringLiteral(Value)
	if (Value is Integer) || (Value is Float)
		return String(Value)
	if Value is Map {
		Out := ""
		for Key, Item in Value
			Out .= (Out == "" ? "" : ",") . JsonStringLiteral(String(Key)) . ":" . WorkflowJsonEncode(Item)
		return "{" . Out . "}"
	}
	if Value is Array {
		Out := ""
		for Item in Value
			Out .= (A_Index == 1 ? "" : ",") . WorkflowJsonEncode(Item)
		return "[" . Out . "]"
	}
	if Value == JSON_TRUE
		return "true"
	if Value == JSON_FALSE
		return "false"
	if Value == JSON_NULL
		return "null"
	throw TypeError("A workflow document holds an unsupported value.", -1, Type(Value))
}
