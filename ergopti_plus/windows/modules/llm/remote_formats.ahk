; modules/llm/remote_formats.ahk

; ==============================================================================
; MODULE: Remote API Formats Beyond Chat Completions (AHK)
; DESCRIPTION:
; AutoHotkey port of _shared/lua/llm/remote_formats.lua: the request and answer
; shapes of the two provider formats of _shared/modules/llm/api_providers.json
; that are not an OpenAI, Anthropic or Gemini chat call.
; - "backboard": Backboard's assistant/thread API. One assistant is created
;   once per key; each request is a message on a new thread naming its
;   provider and model ("<llm_provider>/<model_name>"), and the answer comes
;   back in `content`.
; - "decisions": TypeSafe's System One protocol: typed questions in, answers
;   with probabilities out. Jev, the model it serves, is not a chat model.
;
; FEATURES & RATIONALE:
; 1. Every function is pure: it builds a request as a Map (url, body) or reads
;    a decoded answer. The transport (curl child, credentials in its config
;    file) stays in api_remote.ahk.
; 2. Where Backboard returns Jev's answers is not documented:
;    LLM_RemoteFormats_BackboardDecisionAnswers reads each known location in a
;    fixed order and names the one it used, so the driver logs it and a wrong
;    guess shows up at the first real request.
; 3. Credentials never enter a body: the key goes in the header the format
;    names.
; 4. JSON false has no AHK value of its own (false is 0), so a body holds the
;    LLM_REMOTE_JSON_FALSE sentinel and LLM_RemoteFormats_Encode writes it as
;    false.
;
; Pinned with the Lua module by _shared/tests/corpus/llm/remote_formats_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Module Constants =======
; ===================================
; ===================================

; Header carrying a Backboard key
global LLM_BACKBOARD_KEY_HEADER := "X-API-Key"

; Name of the one assistant the driver creates per key
global LLM_BACKBOARD_ASSISTANT_NAME := "Ergopti+"

; Header carrying a decisions key
global LLM_DECISIONS_KEY_HEADER := "Authorization"

; Stands for JSON false in a body Map; LLM_RemoteFormats_Encode writes false
global LLM_REMOTE_JSON_FALSE := Object()

; The Lua %s class, as a PCRE character class
global LLM_REMOTE_FORMATS_SPACE_CLASS := "[ \t\n\x0B\f\r]"





; ============================
; ============================
; ======= 2/ Backboard =======
; ============================
; ============================

/**
 * Splits a Backboard model id into the provider and the model it names.
 * @param {String} Model "<llm_provider>/<model_name>".
 * @returns {Map|String} Map("provider", "name"), "" when the id names no provider.
 */
LLM_RemoteFormats_BackboardSplitModel(Model) {
	global LLM_REMOTE_FORMATS_SPACE_CLASS
	if !(Model is String)
		return ""
	; s): the Lua (.+) takes line breaks too
	if !RegExMatch(Model, "s)^([A-Za-z0-9][A-Za-z0-9\-_.]*)/(.+)\z", &Match)
		return ""
	Name := Match[2]
	if RegExMatch(Name, "^" . LLM_REMOTE_FORMATS_SPACE_CLASS)
			|| RegExMatch(Name, LLM_REMOTE_FORMATS_SPACE_CLASS . "\z")
		return ""
	return Map("provider", Match[1], "name", Name)
}

/**
 * Returns the request that creates the driver's assistant.
 * @param {String} BaseUrl The provider's base_url.
 * @returns {Map} Map("url", "body").
 */
LLM_RemoteFormats_BackboardAssistantRequest(BaseUrl) {
	global LLM_BACKBOARD_ASSISTANT_NAME
	return Map(
		"url", BaseUrl . "/assistants",
		"body", Map("name", LLM_BACKBOARD_ASSISTANT_NAME, "system_prompt", ""))
}

/**
 * Reads the assistant id out of a decoded creation answer.
 * @param {Map} Response The decoded answer.
 * @returns {String} The id, "" when there is none.
 */
LLM_RemoteFormats_BackboardAssistantId(Response) {
	Id := (Response is Map) ? Response.Get("assistant_id", "") : ""
	return (Id is String) ? Id : ""
}

/**
 * Returns the request that sends one message on a new thread.
 * @param {String} BaseUrl The provider's base_url.
 * @param {Map} Spec Map("assistant_id", "model", "system", "text"[, "questions"]).
 * @returns {Map|String} Map("url", "body"), "" when the model names no provider.
 */
LLM_RemoteFormats_BackboardMessageRequest(BaseUrl, Spec) {
	global LLM_REMOTE_JSON_FALSE
	Split := LLM_RemoteFormats_BackboardSplitModel(Spec.Get("model", ""))
	if !(Split is Map)
		return ""
	Body := Map(
		"content", Spec["text"],
		"assistant_id", Spec["assistant_id"],
		"llm_provider", Split["provider"],
		"model_name", Split["name"],
		"system_prompt", Spec["system"],
		"memory", "off",
		"stream", LLM_REMOTE_JSON_FALSE)
	if Spec.Has("questions")
		Body["system_one"] := Map("questions", Spec["questions"])
	return Map("url", BaseUrl . "/threads/messages", "body", Body)
}

/**
 * Reads the answer text of a decoded message answer.
 * @param {Map} Response The decoded answer.
 * @param {VarRef} Text Receives the text, "" when there is none.
 * @returns {Boolean} True when the answer carries a text.
 */
LLM_RemoteFormats_BackboardText(Response, &Text) {
	Text := ""
	Content := (Response is Map) ? Response.Get("content", 0) : 0
	if !(Content is String)
		return false
	Text := Content
	return true
}

/**
 * Finds Jev's answers in a decoded Backboard message answer.
 * @param {Map} Response The decoded answer.
 * @param {VarRef} Where Receives "system_one", "answers" or "content", "" when
 *     none holds them.
 * @returns {Map|Array|String} The answers, "" when none is found.
 */
LLM_RemoteFormats_BackboardDecisionAnswers(Response, &Where) {
	Where := ""
	if !(Response is Map)
		return ""
	SystemOne := Response.Get("system_one", "")
	if (SystemOne is Map) && _LLM_RemoteFormats_IsTable(SystemOne.Get("answers", "")) {
		Where := "system_one"
		return SystemOne["answers"]
	}
	if _LLM_RemoteFormats_IsTable(Response.Get("answers", "")) {
		Where := "answers"
		return Response["answers"]
	}
	Content := Response.Get("content", 0)
	if (Content is String) {
		Decoded := ""
		; Prose is the expected case here, not an error: the content is JSON
		; only when Backboard puts Jev's decision in it
		try Decoded := JsonParse(Content)
		catch
			Decoded := ""
		if (Decoded is Map) && _LLM_RemoteFormats_IsTable(Decoded.Get("answers", "")) {
			Where := "content"
			return Decoded["answers"]
		}
	}
	return ""
}





; ============================
; ============================
; ======= 3/ Decisions =======
; ============================
; ============================

/**
 * Returns the header value carrying a decisions key.
 * @param {String} Key The key.
 * @returns {String}
 */
LLM_RemoteFormats_DecisionsKeyValue(Key) {
	return "Bearer " . Key
}

/**
 * Returns the body of a decisions request.
 * @param {String} Model e.g. "jev-latest" or "typesafe/jev-1.13".
 * @param {String|Map} State What the questions are about.
 * @param {Map} Questions question_id -> Map("type", "instructions"[, "criteria"]).
 * @returns {Map}
 */
LLM_RemoteFormats_DecisionsBody(Model, State, Questions) {
	return Map("model", Model, "state", State, "questions", Questions)
}

/**
 * Reads the answers of a decoded decisions answer.
 * @param {Map} Response The decoded answer.
 * @returns {Map|Array|String} The answers, "" when there are none.
 */
LLM_RemoteFormats_DecisionsAnswers(Response) {
	Answers := (Response is Map) ? Response.Get("answers", "") : ""
	return _LLM_RemoteFormats_IsTable(Answers) ? Answers : ""
}





; ==============================
; ==============================
; ======= 4/ JSON Bodies =======
; ==============================
; ==============================

/**
 * Writes a body Map as JSON.
 * @param {Any} Value A Map, an Array, a String, a number, JSON_NULL or
 *     LLM_REMOTE_JSON_FALSE.
 * @returns {String}
 */
LLM_RemoteFormats_Encode(Value) {
	global LLM_REMOTE_JSON_FALSE, JSON_NULL
	if (Value is Map) {
		Out := ""
		for Key, Item in Value
			Out .= (Out == "" ? "" : ",") . JsonStringLiteral(String(Key)) . ":" . LLM_RemoteFormats_Encode(Item)
		return "{" . Out . "}"
	}
	if (Value is Array) {
		Out := ""
		for Item in Value
			Out .= (A_Index == 1 ? "" : ",") . LLM_RemoteFormats_Encode(Item)
		return "[" . Out . "]"
	}
	if (Value is String)
		return JsonStringLiteral(Value)
	if (Value is Integer) || (Value is Float)
		return String(Value)
	if IsObject(Value) && ObjPtr(Value) == ObjPtr(LLM_REMOTE_JSON_FALSE)
		return "false"
	if IsObject(Value) && ObjPtr(Value) == ObjPtr(JSON_NULL)
		return "null"
	throw TypeError("LLM_RemoteFormats_Encode: cannot write a " . Type(Value) . " as JSON.")
}

; The Lua type(x) == "table" of a decoded value: an object or an array.
_LLM_RemoteFormats_IsTable(Value) {
	return (Value is Map) || (Value is Array)
}
