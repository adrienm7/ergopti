; modules/llm/agent.ahk

; ==============================================================================
; MODULE: AI Agent (AHK)
; DESCRIPTION:
; AutoHotkey port of _shared/lua/llm/agent.lua: the pure logic of the AI
; agent. System 1 (fast) tells whether a text implies an action, System 2
; (slow, smart) turns a text into actions of a closed schema, and the
; connectors (modules/llm/agent_connectors.ahk) carry out the one the user
; accepts.
;
; FEATURES & RATIONALE:
; 1. Nothing a model writes is executed as is: every action is validated field
;    by field against _shared/modules/llm/agent.json, dates must be real local
;    times, addresses real addresses, and a shortcut must name one of the
;    user's own tools.
; 2. The file formats the connectors hand to the system (an iCalendar event or
;    task, a mailto: link) are built here, so the three drivers write the same
;    bytes.
; 3. agent.json is read once and validated whole: a malformed file fails
;    loudly instead of sending a half-configured request.
;
; Lengths follow the Lua module: text limits count code points, an address
; limit counts UTF-8 bytes, whitespace is the Lua %s class and the tag compares
; case-insensitively on ASCII letters only.
;
; Pinned with the Lua module by _shared/tests/corpus/llm/agent_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Module Constants =======
; ===================================
; ===================================

; The Lua %s class, as a PCRE character class
global LLM_AGENT_SPACE_CLASS := "[ \t\n\x0B\f\r]"

; Characters an address part may not hold, as in the Lua pattern
global LLM_AGENT_EMAIL_PART := '[^@ \t\n\x0B\f\r,;<>"]+'

; Longest address, in UTF-8 bytes
global LLM_AGENT_EMAIL_MAX_BYTES := 254

; Longest topic, in code points, a mail label shows before an ellipsis
global LLM_AGENT_LABEL_TOPIC_MAX := 60

; Days from the OLE automation epoch (1899-12-30) to 1970-01-01: the
; connectors hand Outlook its dates as OLE automation dates
global LLM_AGENT_OLE_EPOCH_DAYS := 25569

; The unreserved characters of RFC 3986, which a mailto: value keeps literal
global LLM_AGENT_MAILTO_LITERAL := "^[A-Za-z0-9\-._~]\z"





; =======================================
; =======================================
; ======= 2/ Shared Configuration =======
; =======================================
; =======================================

/**
 * Returns the decoded, validated agent.json, read on first use.
 * @returns {Map}
 */
LLM_Agent_Config() {
	global _SharedDir
	static Config := ""
	if (Config is Map)
		return Config
	Path := _SharedDir . "\modules\llm\agent.json"
	Candidate := JsonParse(FSReadStrict(Path))
	_LLM_Agent_ValidateConfig(Candidate, Path)
	Config := Candidate
	return Config
}

; Throws unless Candidate holds every field the agent reads.
; @param {Map} Candidate The decoded file.
; @param {String} Path Its path, for the error.
_LLM_Agent_ValidateConfig(Candidate, Path) {
	if !(Candidate is Map)
		throw ValueError(Path . ": the root must be an object.")
	Intents := Candidate.Get("intents", "")
	if !(Intents is Array) || Intents.Length == 0
		throw ValueError(Path . ": intents must be a non-empty array.")
	for Intent in Intents {
		if !(Intent is String) || Intent == ""
			throw ValueError(Path . ": every intent must be a non-empty string.")
	}
	Defaults := Candidate.Get("default_models", "")
	if !(Defaults is Map) || !(Defaults.Get("local", "") is String) || Defaults["local"] == ""
		throw ValueError(Path . ": default_models.local must be a non-empty string.")
	System1 := Candidate.Get("system1", "")
	if !(System1 is Map)
		throw ValueError(Path . ": system1 must be an object.")
	for Key in ["pause_ms", "min_chars", "max_tokens"]
		_LLM_Agent_RequirePositive(System1, Key, Path . ": system1")
	if !_LLM_Agent_IsProbability(System1.Get("threshold", ""))
		throw ValueError(Path . ": system1.threshold must be a number from 0 to 1.")
	_LLM_Agent_RequireText(System1, "prompt", Path . ": system1")
	Jev := System1.Get("jev", "")
	if !(Jev is Map)
		throw ValueError(Path . ": system1.jev must be an object.")
	for Key in ["question_id", "instructions"]
		_LLM_Agent_RequireText(Jev, Key, Path . ": system1.jev")
	if !(Jev.Get("criteria", "") is Map)
		throw ValueError(Path . ": system1.jev.criteria must be an object.")
	for Intent in Intents
		_LLM_Agent_RequireText(Jev["criteria"], Intent, Path . ": system1.jev.criteria")
	System2 := Candidate.Get("system2", "")
	if !(System2 is Map)
		throw ValueError(Path . ": system2 must be an object.")
	for Key in ["max_actions", "max_tokens"]
		_LLM_Agent_RequirePositive(System2, Key, Path . ": system2")
	for Key in ["tag", "user_prefix", "prompt"]
		_LLM_Agent_RequireText(System2, Key, Path . ": system2")
	Actions := Candidate.Get("actions", "")
	if !(Actions is Map) || Actions.Count == 0
		throw ValueError(Path . ": actions must be a non-empty object.")
	for ActionType, Schema in Actions {
		if !(Schema is Map)
			throw ValueError(Path . ": the schema of " . ActionType . " must be an object.")
		for Field, Rule in Schema
			_LLM_Agent_ValidateRule(Rule, Path . ": " . ActionType . "." . Field)
	}
	Kinds := Candidate.Get("source_kinds", "")
	if !(Kinds is Map)
		throw ValueError(Path . ": source_kinds must be an object.")
	for Source in ["selection", "command", "typing"]
		_LLM_Agent_RequireText(Kinds, Source, Path . ": source_kinds")
	for Key in ["default_duration_minutes", "max_tools"]
		_LLM_Agent_RequirePositive(Candidate, Key, Path)
	Learning := Candidate.Get("learning", "")
	if !(Learning is Map)
		throw ValueError(Path . ": learning must be an object.")
	for Key in ["step", "min_threshold", "max_threshold"] {
		if !_LLM_Agent_IsProbability(Learning.Get(Key, ""))
			throw ValueError(Path . ": learning." . Key . " must be a number from 0 to 1.")
	}
	if (Learning["min_threshold"] > Learning["max_threshold"])
		throw ValueError(Path . ": learning.min_threshold must not exceed max_threshold.")
	Ics := Candidate.Get("ics", "")
	if !(Ics is Map)
		throw ValueError(Path . ": ics must be an object.")
	_LLM_Agent_RequireText(Ics, "prodid", Path . ": ics")
}

; Throws unless Owner[Key] is a positive integer.
_LLM_Agent_RequirePositive(Owner, Key, Where) {
	Value := Owner.Get(Key, "")
	if !(Value is Integer) || Value <= 0
		throw ValueError(Where . "." . Key . " must be a positive integer.")
}

; Throws unless Owner[Key] is a non-empty string.
_LLM_Agent_RequireText(Owner, Key, Where) {
	Value := Owner.Get(Key, "")
	if !(Value is String) || Value == ""
		throw ValueError(Where . "." . Key . " must be a non-empty string.")
}

; Throws unless Rule is a field rule the validator knows.
_LLM_Agent_ValidateRule(Rule, Where) {
	static Types := Map("text", true, "datetime", true, "emails", true, "tool", true)
	if !(Rule is Map) || !(Rule.Get("type", "") is String) || !Types.Has(Rule["type"])
		throw ValueError(Where . " must name a known field type.")
	if (Rule["type"] == "text" || Rule["type"] == "emails")
		_LLM_Agent_RequirePositive(Rule, "max", Where)
}

; @returns {Boolean} True for a number from 0 to 1.
_LLM_Agent_IsProbability(Value) {
	return ((Value is Integer) || (Value is Float)) && Value >= 0 && Value <= 1
}





; ==========================
; ==========================
; ======= 3/ Prompts =======
; ==========================
; ==========================

/**
 * Returns the System 1 triage prompt.
 * @param {Map} Config The decoded agent.json.
 * @param {Map} Ctx Map("app", Name, "tools", Array).
 * @returns {String}
 */
LLM_Agent_System1Prompt(Config, Ctx) {
	return _LLM_Agent_Fill(Config["system1"]["prompt"], Map(
		"app", Ctx.Get("app", ""),
		"tools", _LLM_Agent_ToolsText(Ctx.Get("tools", ""))))
}

/**
 * Returns the System 2 prompt.
 * @param {Map} Config The decoded agent.json.
 * @param {Map} Ctx Map("source" ("selection"|"command"|"typing"), "app",
 *     "window", "now", "weekday", "timezone", "language", "tools").
 * @returns {String}
 */
LLM_Agent_System2Prompt(Config, Ctx) {
	Source := Ctx.Get("source", "")
	if !(Source is String) || !Config["source_kinds"].Has(Source)
		throw ValueError("LLM_Agent_System2Prompt: unknown source " . String(Source) . ".")
	Values := Map(
		"source_kind", Config["source_kinds"][Source],
		"app", Ctx.Get("app", ""),
		"window", Ctx.Get("window", ""),
		"max_actions", Config["system2"]["max_actions"],
		"tools", _LLM_Agent_ToolsText(Ctx.Get("tools", "")))
	; An absent value leaves its placeholder, like the Lua nil
	for Key in ["now", "weekday", "timezone", "language"] {
		if Ctx.Has(Key)
			Values[Key] := Ctx[Key]
	}
	return _LLM_Agent_Fill(Config["system2"]["prompt"], Values)
}

/**
 * Returns the user turn of a System 2 request.
 * @param {Map} Config The decoded agent.json.
 * @param {String} Text The source text.
 * @returns {String}
 */
LLM_Agent_System2UserText(Config, Text) {
	return Config["system2"]["user_prefix"] . Text
}

/**
 * Returns the model a parsed backend setting runs: the model it names, else
 * the local default of agent.json for the local backend, else the provider's
 * default_model in api_providers.json.
 * @param {Map|String} Parsed LLM_Vision_Parse's output ("" when invalid).
 * @param {Map} Config The decoded agent.json.
 * @param {Map} Providers Provider id -> Map("DefaultModel", ...), as
 *     api_remote.ahk loads api_providers.json.
 * @returns {String} The model, "" when the setting is off, unknown or has none.
 */
LLM_Agent_ResolveModel(Parsed, Config, Providers) {
	global LLM_VISION_LOCAL_BACKEND
	if !(Parsed is Map)
		return ""
	if Parsed.Has("model")
		return Parsed["model"]
	if (Parsed["backend"] == LLM_VISION_LOCAL_BACKEND)
		return Config["default_models"]["local"]
	if !(Providers is Map) || !Providers.Has(Parsed["backend"])
		return ""
	Provider := Providers[Parsed["backend"]]
	Model := (Provider is Map) ? Provider.Get("DefaultModel", "") : ""
	return (Model is String) ? Model : ""
}

; Replaces every {name} of a template by its value, literally, in one pass:
; a value that holds braces is never read as a placeholder.
; @param {String} Template The template.
; @param {Map} Values Name -> value; a missing name keeps its placeholder.
; @returns {String}
_LLM_Agent_Fill(Template, Values) {
	Out := ""
	Position := 1
	while RegExMatch(Template, "\{([A-Za-z0-9_]+)\}", &Match, Position) {
		Out .= SubStr(Template, Position, Match.Pos - Position)
		Out .= Values.Has(Match[1]) ? String(Values[Match[1]]) : Match[0]
		Position := Match.Pos + Match.Len
	}
	return Out . SubStr(Template, Position)
}

; Returns the tools list as the prompts name it.
; @param {Array} Tools Tool names.
; @returns {String}
_LLM_Agent_ToolsText(Tools) {
	if !(Tools is Array) || Tools.Length == 0
		return "(none)"
	Text := ""
	for Tool in Tools
		Text .= (A_Index == 1 ? "" : ", ") . Tool
	return Text
}





; ===========================
; ===========================
; ======= 4/ System 1 =======
; ===========================
; ===========================

/**
 * Reads the triage a chat model wrote.
 * @param {Map} Config The decoded agent.json.
 * @param {String} Raw The raw answer.
 * @returns {Map|String} Map("intent", "probability"), "" when unreadable.
 */
LLM_Agent_ParseSystem1(Config, Raw) {
	global LLM_AGENT_SPACE_CLASS
	if !(Raw is String)
		return ""
	Space := LLM_AGENT_SPACE_CLASS . "*"
	if !RegExMatch(Raw, "[Ii][Nn][Tt][Ee][Nn][Tt]" . Space . ":" . Space . "([A-Za-z]+)", &IntentMatch)
		return ""
	if !RegExMatch(Raw, "[Pp][Rr][Oo][Bb][Aa][Bb][Ii][Ll][Ii][Tt][Yy]" . Space . ":" . Space . "([0-9.]+)",
			&ProbabilityMatch)
		return ""
	; tonumber() of the capture: a number, or nothing at all ("1.2.3", ".")
	if !RegExMatch(ProbabilityMatch[1], "^(?:[0-9]+\.?[0-9]*|\.[0-9]+)\z")
		return ""
	Probability := Number(ProbabilityMatch[1])
	Intent := StrLower(IntentMatch[1])
	if !_LLM_Agent_IsIntent(Config, Intent) || Probability < 0 || Probability > 1
		return ""
	return Map("intent", Intent, "probability", Probability)
}

/**
 * Returns the Jev choice question of the triage, in the TypeSafe decisions
 * shape.
 * @param {Map} Config The decoded agent.json.
 * @returns {Map} question_id -> Map("type", "choice", "instructions",
 *     "criteria", Map(Intent -> description)).
 */
LLM_Agent_JevQuestions(Config) {
	Jev := Config["system1"]["jev"]
	Criteria := Map()
	for Intent in Config["intents"]
		Criteria[Intent] := Jev["criteria"][Intent]
	return Map(Jev["question_id"], Map(
		"type", "choice",
		"instructions", Jev["instructions"],
		"criteria", Criteria))
}

/**
 * Reads the triage out of the decoded answers of a Jev decision. The chosen
 * label is the answer's choice when present, else the most probable one (ties
 * go to the earlier intent).
 * @param {Map} Config The decoded agent.json.
 * @param {Map} Answers The answers object of the decision.
 * @returns {Map|String} Map("intent", "probability"), "" when unreadable.
 */
LLM_Agent_ParseJevAnswers(Config, Answers) {
	QuestionId := Config["system1"]["jev"]["question_id"]
	Answer := (Answers is Map) ? Answers.Get(QuestionId, "") : ""
	if !(Answer is Map)
		return ""
	if Answer.Has("type") && !((Answer["type"] is String) && Answer["type"] == "choice")
		return ""
	Probabilities := Answer.Get("probabilities", "")
	if !(Probabilities is Map)
		return ""
	if Answer.Has("choice") {
		Choice := Answer["choice"]
	} else {
		Choice := ""
		Best := -1
		for Intent in Config["intents"] {
			Probability := Probabilities.Get(Intent, "")
			if ((Probability is Integer) || (Probability is Float)) && Probability > Best {
				Choice := Intent
				Best := Probability
			}
		}
	}
	if !(Choice is String) || !_LLM_Agent_IsIntent(Config, Choice)
		return ""
	Probability := Probabilities.Get(Choice, "")
	if !_LLM_Agent_IsProbability(Probability)
		return ""
	return Map("intent", Choice, "probability", Probability)
}

/**
 * Reads the triage out of a decoded Jev decision response.
 * @param {Map} Config The decoded agent.json.
 * @param {Map} Response The decoded response body.
 * @returns {Map|String} Map("intent", "probability"), "" when unreadable.
 */
LLM_Agent_ParseJev(Config, Response) {
	return LLM_Agent_ParseJevAnswers(Config, (Response is Map) ? Response.Get("answers", "") : "")
}

/**
 * Reports whether a triage should wake System 2.
 * @param {Map|String} Triage Map("intent", "probability"), or "".
 * @param {Number} Threshold
 * @returns {Boolean}
 */
LLM_Agent_ShouldAct(Triage, Threshold) {
	return (Triage is Map) && Triage["intent"] != "none" && Triage["probability"] >= Threshold
}

; @returns {Boolean} True when Intent is one of agent.json's intents.
_LLM_Agent_IsIntent(Config, Intent) {
	for Known in Config["intents"] {
		if (Known == Intent)
			return true
	}
	return false
}





; ======================================
; ======================================
; ======= 5/ Local Date and Time =======
; ======================================
; ======================================

/**
 * Parses a local wall-clock time "YYYY-MM-DDTHH:MM".
 * @param {String} Text
 * @returns {Integer|String} Minutes since 1970-01-01T00:00, "" when invalid.
 */
LLM_Agent_ParseDatetime(Text) {
	if !(Text is String)
		return ""
	if !RegExMatch(Text, "^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})\z", &Match)
		return ""
	Y := Integer(Match[1])
	Mo := Integer(Match[2])
	D := Integer(Match[3])
	H := Integer(Match[4])
	Mi := Integer(Match[5])
	if (Mo < 1 || Mo > 12 || H > 23 || Mi > 59 || D < 1)
		return ""
	NextY := (Mo == 12) ? Y + 1 : Y
	NextM := (Mo == 12) ? 1 : Mo + 1
	if (D > _LLM_Agent_DaysFromCivil(NextY, NextM, 1) - _LLM_Agent_DaysFromCivil(Y, Mo, 1))
		return ""
	return _LLM_Agent_DaysFromCivil(Y, Mo, D) * 1440 + H * 60 + Mi
}

/**
 * Formats minutes since the epoch as "YYYY-MM-DDTHH:MM".
 * @param {Integer} Minutes
 * @returns {String}
 */
LLM_Agent_FormatDatetime(Minutes) {
	Days := _LLM_Agent_IDiv(Minutes, 1440)
	Rest := Minutes - Days * 1440
	Civil := _LLM_Agent_CivilFromDays(Days)
	return Format("{:04d}-{:02d}-{:02d}T{:02d}:{:02d}", Civil[1], Civil[2], Civil[3],
		_LLM_Agent_IDiv(Rest, 60), Mod(Rest, 60))
}

/**
 * Converts a local wall-clock time into an OLE automation date, the VT_DATE
 * value COM servers such as Outlook take: built from the components, never
 * from a localized date string.
 * @param {String} Text "YYYY-MM-DDTHH:MM".
 * @returns {Float} Days since 1899-12-30, the time as the fraction.
 */
LLM_Agent_OleDate(Text) {
	global LLM_AGENT_OLE_EPOCH_DAYS
	Minutes := LLM_Agent_ParseDatetime(Text)
	if (Minutes == "")
		throw ValueError("LLM_Agent_OleDate: not a local time.")
	return Minutes / 1440.0 + LLM_AGENT_OLE_EPOCH_DAYS
}

; Floor division, as the Lua module computes it.
_LLM_Agent_IDiv(A, B) {
	return Floor(A / B)
}

; Days since 1970-01-01 of a civil date (proleptic Gregorian).
_LLM_Agent_DaysFromCivil(Y, M, D) {
	Y := (M <= 2) ? Y - 1 : Y
	Era := _LLM_Agent_IDiv(Y, 400)
	Yoe := Y - Era * 400
	Doy := _LLM_Agent_IDiv(153 * (M + ((M > 2) ? -3 : 9)) + 2, 5) + D - 1
	Doe := Yoe * 365 + _LLM_Agent_IDiv(Yoe, 4) - _LLM_Agent_IDiv(Yoe, 100) + Doy
	return Era * 146097 + Doe - 719468
}

; Civil date of a day count since 1970-01-01.
; @returns {Array} [Year, Month, Day].
_LLM_Agent_CivilFromDays(Z) {
	Z := Z + 719468
	Era := _LLM_Agent_IDiv(Z, 146097)
	Doe := Z - Era * 146097
	Yoe := _LLM_Agent_IDiv(Doe - _LLM_Agent_IDiv(Doe, 1460) + _LLM_Agent_IDiv(Doe, 36524)
		- _LLM_Agent_IDiv(Doe, 146096), 365)
	Y := Yoe + Era * 400
	Doy := Doe - (365 * Yoe + _LLM_Agent_IDiv(Yoe, 4) - _LLM_Agent_IDiv(Yoe, 100))
	Mp := _LLM_Agent_IDiv(5 * Doy + 2, 153)
	D := Doy - _LLM_Agent_IDiv(153 * Mp + 2, 5) + 1
	M := Mp + ((Mp < 10) ? 3 : -9)
	return [(M <= 2) ? Y + 1 : Y, M, D]
}





; ===================================
; ===================================
; ======= 6/ System 2 Actions =======
; ===================================
; ===================================

/**
 * Validates and normalizes one action a model proposed.
 * @param {Map} Config The decoded agent.json.
 * @param {Map} Action The decoded action.
 * @param {Array} Tools The user's tool names.
 * @param {VarRef} Reason Receives why the action is refused.
 * @returns {Map|String} The normalized action, "" when refused.
 */
LLM_Agent_ValidateAction(Config, Action, Tools, &Reason := "") {
	Reason := ""
	if !(Action is Map) {
		Reason := "not an object"
		return ""
	}
	ActionType := Action.Get("type", "")
	if !(ActionType is String) || !Config["actions"].Has(ActionType) {
		Reason := "unknown type " . ((ActionType is String) ? ActionType : Type(ActionType))
		return ""
	}
	Schema := Config["actions"][ActionType]
	for Name in Action {
		if (Name != "type" && !Schema.Has(Name)) {
			Reason := "unknown field " . Name
			return ""
		}
	}
	Out := Map("type", ActionType)
	for Name, Rule in Schema {
		Value := Action.Has(Name) ? Action[Name] : ""
		Present := Action.Has(Name) && !_LLM_Agent_IsNull(Value)
		if !Present {
			if Rule.Get("required", false) {
				Reason := Name . " is missing"
				return ""
			}
			continue
		}
		Normalized := _LLM_Agent_CheckField(Name, Rule, Value, Tools, &Reason)
		if (Reason != "")
			return ""
		Out[Name] := Normalized
	}
	if (ActionType == "calendar") {
		Start := LLM_Agent_ParseDatetime(Out["start"])
		if !Out.Has("end")
			Out["end"] := LLM_Agent_FormatDatetime(Start + Config["default_duration_minutes"])
		else if (LLM_Agent_ParseDatetime(Out["end"]) <= Start) {
			Reason := "end is not after start"
			return ""
		}
	}
	return Out
}

/**
 * Reads the actions System 2 wrote.
 * @param {Map} Config The decoded agent.json.
 * @param {String} Raw The raw answer.
 * @param {Array} Tools The user's tool names.
 * @param {VarRef} Rejected Receives the reasons of the refused actions.
 * @returns {Array|String} The valid actions, most likely first; "" when unreadable.
 */
LLM_Agent_ParseActions(Config, Raw, Tools, &Rejected := "") {
	Rejected := []
	if !(Raw is String)
		return ""
	Tag := Config["system2"]["tag"]
	; CaseSense off folds A-Z only, like the Lua upper() in the C locale
	At := InStr(Raw, Tag, false)
	if !At
		return ""
	Body := SubStr(Raw, At + StrLen(Tag))
	First := InStr(Body, "[")
	Last := InStr(Body, "]", true, -1)
	if (!First || !Last || Last < First)
		return ""
	try List := JsonParse(SubStr(Body, First, Last - First + 1))
	catch
		return ""
	if !(List is Array)
		return ""
	Actions := []
	for Item in List {
		Action := LLM_Agent_ValidateAction(Config, Item, Tools, &Reason)
		if (Action is Map) {
			if (Actions.Length < Config["system2"]["max_actions"])
				Actions.Push(Action)
		} else {
			Rejected.Push(Reason)
		}
	}
	return Actions
}

/**
 * Returns the locale key and arguments of an action's tooltip label.
 * @param {Map} Action A validated action.
 * @returns {Map} Map("key", LocaleKey, "args", Array).
 */
LLM_Agent_Label(Action) {
	global LLM_AGENT_LABEL_TOPIC_MAX
	switch Action["type"] {
		case "calendar":
			return Map("key", "llm.agent.label.calendar",
				"args", [Action["title"], StrReplace(Action["start"], "T", " ")])
		case "reminder":
			if Action.Has("due")
				return Map("key", "llm.agent.label.reminder_due",
					"args", [Action["title"], StrReplace(Action["due"], "T", " ")])
			return Map("key", "llm.agent.label.reminder", "args", [Action["title"]])
		case "mail":
			; A draft without a subject is named by the start of its body
			Topic := Action.Has("subject") ? Action["subject"] : _LLM_Agent_FirstLine(Action["body"])
			if (LLM_Rewrite_CodepointLength(Topic) > LLM_AGENT_LABEL_TOPIC_MAX)
				Topic := _LLM_Agent_CodepointPrefix(Topic, LLM_AGENT_LABEL_TOPIC_MAX) . "…"
			if (Action.Has("to") && Action["to"].Length > 0)
				return Map("key", "llm.agent.label.mail_to", "args", [Topic, _LLM_Agent_Join(Action["to"], ", ")])
			return Map("key", "llm.agent.label.mail", "args", [Topic])
	}
	return Map("key", "llm.agent.label.shortcut", "args", [Action["name"]])
}

; Validates one field value against its rule.
; @param {VarRef} Reason Receives why it is refused, "" when it is valid.
; @returns {Any} The normalized value.
_LLM_Agent_CheckField(Name, Rule, Value, Tools, &Reason) {
	global LLM_AGENT_SPACE_CLASS
	Reason := ""
	switch Rule["type"] {
		case "text":
			if !(Value is String) {
				Reason := Name . " is not text"
				return ""
			}
			Value := RegExReplace(Value, "^" . LLM_AGENT_SPACE_CLASS . "+|" . LLM_AGENT_SPACE_CLASS . "+\z", "")
			if (Value == "") {
				Reason := Name . " is empty"
				return ""
			}
			if (LLM_Rewrite_CodepointLength(Value) > Rule["max"]) {
				Reason := Name . " is too long"
				return ""
			}
			return Value
		case "datetime":
			if (LLM_Agent_ParseDatetime(Value) == "") {
				Reason := Name . " is not a local time"
				return ""
			}
			return Value
		case "emails":
			if !(Value is Array) || Value.Length > Rule["max"] {
				Reason := Name . " is not a short list"
				return ""
			}
			List := []
			for Item in Value {
				if !_LLM_Agent_IsEmail(Item) {
					Reason := Name . " holds a non-address"
					return ""
				}
				List.Push(Item)
			}
			return List
		case "tool":
			if !(Value is String) {
				Reason := Name . " is not text"
				return ""
			}
			if (Tools is Array) {
				for Tool in Tools {
					if (Tool == Value)
						return Value
				}
			}
			Reason := Name . " is not one of the user's tools"
			return ""
	}
	throw ValueError("LLM_Agent: unknown field rule " . String(Rule["type"]) . ".")
}

; @returns {Boolean} True when Value is an email address.
_LLM_Agent_IsEmail(Value) {
	global LLM_AGENT_EMAIL_PART, LLM_AGENT_EMAIL_MAX_BYTES
	if !(Value is String) || _LLM_Agent_Utf8Length(Value) > LLM_AGENT_EMAIL_MAX_BYTES
		return false
	return RegExMatch(Value, "^" . LLM_AGENT_EMAIL_PART . "@" . LLM_AGENT_EMAIL_PART . "\."
		. LLM_AGENT_EMAIL_PART . "\z") ? true : false
}

; @returns {Boolean} True for the decoder's JSON null.
_LLM_Agent_IsNull(Value) {
	global JSON_NULL
	return IsObject(Value) && ObjPtr(Value) == ObjPtr(JSON_NULL)
}

; @returns {Integer} The UTF-8 length of a text, in bytes.
_LLM_Agent_Utf8Length(Text) {
	return StrPut(Text, "UTF-8") - 1
}

; Returns the first Count code points of a text, never half a surrogate pair.
_LLM_Agent_CodepointPrefix(Text, Count) {
	Units := StrLen(Text)
	Position := 1
	Taken := 0
	while (Position <= Units && Taken < Count) {
		Unit := Ord(SubStr(Text, Position, 1))
		Position += (Unit >= 0xD800 && Unit <= 0xDBFF && Position < Units) ? 2 : 1
		Taken += 1
	}
	return SubStr(Text, 1, Position - 1)
}

; The text before the first line break.
_LLM_Agent_FirstLine(Text) {
	RegExMatch(Text, "^[^\r\n]*", &Match)
	return Match[0]
}

; Joins the items of an array with a separator.
_LLM_Agent_Join(Items, Separator) {
	Text := ""
	for Item in Items
		Text .= (A_Index == 1 ? "" : Separator) . Item
	return Text
}





; =====================================
; =====================================
; ======= 7/ Connector Payloads =======
; =====================================
; =====================================

/**
 * Builds the iCalendar file of a calendar or reminder action.
 * @param {Map} Config The decoded agent.json.
 * @param {Map} Action A validated calendar or reminder action.
 * @param {String} Uid Unique id of the entry.
 * @param {String} Stamp Creation time, UTC, "YYYYMMDDTHHMMSSZ".
 * @returns {String} CRLF-terminated content.
 */
LLM_Agent_Ics(Config, Action, Uid, Stamp) {
	Lines := ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:" . Config["ics"]["prodid"]]
	Component := (Action["type"] == "calendar") ? "VEVENT" : "VTODO"
	Lines.Push("BEGIN:" . Component)
	Lines.Push("UID:" . Uid)
	Lines.Push("DTSTAMP:" . Stamp)
	if (Action["type"] == "calendar") {
		Lines.Push("DTSTART:" . _LLM_Agent_IcsTime(Action["start"]))
		Lines.Push("DTEND:" . _LLM_Agent_IcsTime(Action["end"]))
	} else if Action.Has("due") {
		Lines.Push("DUE:" . _LLM_Agent_IcsTime(Action["due"]))
	}
	Lines.Push("SUMMARY:" . _LLM_Agent_IcsText(Action["title"]))
	if Action.Has("location")
		Lines.Push("LOCATION:" . _LLM_Agent_IcsText(Action["location"]))
	if Action.Has("notes")
		Lines.Push("DESCRIPTION:" . _LLM_Agent_IcsText(Action["notes"]))
	if Action.Has("attendees") {
		for Address in Action["attendees"]
			Lines.Push("ATTENDEE:mailto:" . Address)
	}
	Lines.Push("END:" . Component)
	Lines.Push("END:VCALENDAR")
	Text := ""
	for Line in Lines
		Text .= _LLM_Agent_IcsFold(Line) . "`r`n"
	return Text
}

/**
 * Builds the mailto: link of a mail action. The "@" of an address stays
 * literal, as RFC 6068 writes addr-spec; everything else is encoded.
 * @param {Map} Action A validated mail action.
 * @returns {String}
 */
LLM_Agent_Mailto(Action) {
	To := ""
	if Action.Has("to") {
		for Address in Action["to"]
			To .= (A_Index == 1 ? "" : ",") . StrReplace(_LLM_Agent_MailtoEncode(Address), "%40", "@")
	}
	Query := ""
	if Action.Has("subject")
		Query := "subject=" . _LLM_Agent_MailtoEncode(Action["subject"]) . "&"
	Query .= "body=" . _LLM_Agent_MailtoEncode(Action["body"])
	return "mailto:" . To . "?" . Query
}

/**
 * Quotes a text as an AppleScript string literal (the macOS connectors' quoting,
 * ported so the shared corpus replays whole).
 * @param {String} Text
 * @returns {String}
 */
LLM_Agent_AppleScriptString(Text) {
	return '"' . StrReplace(StrReplace(Text, "\", "\\"), '"', '\"') . '"'
}

; Escapes an iCalendar TEXT value.
_LLM_Agent_IcsText(Text) {
	Text := StrReplace(Text, "\", "\\")
	Text := StrReplace(Text, ";", "\;")
	Text := StrReplace(Text, ",", "\,")
	Text := StrReplace(Text, "`r`n", "`n")
	return StrReplace(Text, "`n", "\n")
}

; Folds one content line at 75 octets without splitting a UTF-8 sequence.
_LLM_Agent_IcsFold(Line) {
	Parts := []
	Current := ""
	CurrentBytes := 0
	Units := StrLen(Line)
	Position := 1
	while (Position <= Units) {
		Unit := Ord(SubStr(Line, Position, 1))
		Width := 1
		if (Unit >= 0xD800 && Unit <= 0xDBFF && Position < Units) {
			Width := 2
			Bytes := 4
		} else {
			Bytes := (Unit < 0x80) ? 1 : (Unit < 0x800) ? 2 : 3
		}
		Limit := (Parts.Length == 0) ? 75 : 74
		if (CurrentBytes + Bytes > Limit) {
			Parts.Push(Current)
			Current := ""
			CurrentBytes := 0
		}
		Current .= SubStr(Line, Position, Width)
		CurrentBytes += Bytes
		Position += Width
	}
	Parts.Push(Current)
	return _LLM_Agent_Join(Parts, "`r`n ")
}

; Formats a local time as an iCalendar floating DATE-TIME.
_LLM_Agent_IcsTime(Value) {
	return RegExReplace(Value, "[-:]", "") . "00"
}

; Percent-encodes a mailto: header value (RFC 6068): only unreserved
; characters stay literal, and a line break is CRLF.
_LLM_Agent_MailtoEncode(Text) {
	global LLM_AGENT_MAILTO_LITERAL
	Text := StrReplace(StrReplace(Text, "`r`n", "`n"), "`n", "`r`n")
	Size := StrPut(Text, "UTF-8")
	Bytes := Buffer(Size)
	StrPut(Text, Bytes, "UTF-8")
	Out := ""
	loop Size - 1 {
		Byte := NumGet(Bytes, A_Index - 1, "UChar")
		Char := Chr(Byte)
		Out .= (Byte < 0x80 && RegExMatch(Char, LLM_AGENT_MAILTO_LITERAL)) ? Char : Format("%{:02X}", Byte)
	}
	return Out
}





; ===========================
; ===========================
; ======= 8/ Learning =======
; ===========================
; ===========================

/**
 * Moves an intent's threshold after the user accepted or dismissed a suggestion.
 * @param {Map} Config The decoded agent.json.
 * @param {Number} Threshold The current threshold.
 * @param {Boolean} Accepted
 * @returns {Number} The next threshold.
 */
LLM_Agent_Learn(Config, Threshold, Accepted) {
	Learning := Config["learning"]
	Next := Accepted ? Threshold - Learning["step"] : Threshold + Learning["step"]
	Next := Floor(Next * 1000 + 0.5) / 1000
	if (Next < Learning["min_threshold"])
		return Learning["min_threshold"]
	if (Next > Learning["max_threshold"])
		return Learning["max_threshold"]
	return Next
}
