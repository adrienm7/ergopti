; modules/llm/vision.ahk

; ==============================================================================
; MODULE: Screen Reading (AHK)
; DESCRIPTION:
; AutoHotkey port of _shared/lua/llm/vision.lua: the pure logic behind the
; llm_screen_region, llm_screen_full and llm_screen_error actions. A vision
; model transcribes a screenshot, then the AI menu's text backend drafts the
; answers offered in the prediction tooltip.
;
; FEATURES & RATIONALE:
; 1. The binding names the vision backend: "local" (the local Ollama server)
;    or a provider of _shared/modules/llm/api_providers.json, optionally
;    followed by |model. Without a model the default of vision.json applies;
;    a backend without one needs the model in the binding, never a guess.
; 2. Each API dialect carries an image differently; LLM_Vision_BuildRequest
;    writes the request body for all four (openai, anthropic, gemini, ollama),
;    so the caller only adds the address and the credentials.
; 3. Prompts, tags, token budgets and defaults live in vision.json, read once
;    and validated whole: a malformed file fails loudly instead of sending a
;    half-configured request.
;
; Lengths follow the Lua module: the model length is counted in UTF-8 bytes,
; the control class is the C-locale one (0x00-0x1F, 0x7F), whitespace is the
; Lua %s class, and tags compare case-insensitively on ASCII letters only.
;
; Pinned with the Lua module by _shared/tests/corpus/llm/vision_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Module Constants =======
; ===================================
; ===================================

; Backend id of the local server; every other id is an API provider
global LLM_VISION_LOCAL_BACKEND := "local"

; Longest model name a binding may carry, in UTF-8 bytes
global LLM_VISION_MAX_MODEL_LENGTH := 200

; Request formats LLM_Vision_BuildRequest writes
global LLM_VISION_FORMATS := Map("openai", true, "anthropic", true, "gemini", true, "ollama", true)

; The user turn that goes with the screenshot of the reading request
global LLM_VISION_READ_USER_TEXT := "Transcribe this screenshot."

; The Lua %s class, as a PCRE character class
global LLM_VISION_SPACE_CLASS := "[ \t\n\x0B\f\r]"





; ====================================
; ====================================
; ======= 2/ Binding Parameter =======
; ====================================
; ====================================

/**
 * Parses a binding value: "<backend>" or "<backend>|<model>".
 * @param {String} Value The stored parameter.
 * @param {VarRef} Reason Receives why the value is invalid, "" when it is valid.
 * @returns {Map|String} Map("backend"[, "model"]), or "" when invalid.
 */
LLM_Vision_Parse(Value, &Reason := "") {
	global LLM_VISION_MAX_MODEL_LENGTH, LLM_VISION_SPACE_CLASS
	Reason := ""
	if !(Value is String) {
		Reason := "not a string"
		return ""
	}
	Separator := InStr(Value, "|")
	Backend := Separator ? SubStr(Value, 1, Separator - 1) : Value
	; \z, not $: PCRE's $ would accept a backend followed by a final line break
	if !RegExMatch(Backend, "^[a-z][a-z0-9_]*\z") {
		Reason := "invalid backend id"
		return ""
	}
	if !Separator
		return Map("backend", Backend)
	Model := SubStr(Value, Separator + 1)
	ByteLength := StrPut(Model, "UTF-8") - 1
	if (Model == "" || ByteLength > LLM_VISION_MAX_MODEL_LENGTH) {
		Reason := "invalid model length"
		return ""
	}
	if RegExMatch(Model, "[\x00-\x1F\x7F|]")
			|| RegExMatch(Model, "^" . LLM_VISION_SPACE_CLASS)
			|| RegExMatch(Model, LLM_VISION_SPACE_CLASS . "\z") {
		Reason := "invalid model name"
		return ""
	}
	return Map("backend", Backend, "model", Model)
}

/**
 * Tells whether a binding value is syntactically valid.
 * @param {String} Value The stored parameter.
 * @returns {Boolean}
 */
LLM_Vision_IsValid(Value) {
	return (LLM_Vision_Parse(Value) is Map) ? true : false
}

/**
 * Resolves the vision model a parsed binding runs.
 * @param {Map} Parsed LLM_Vision_Parse's output.
 * @param {Map} Config The decoded vision.json.
 * @returns {String} The model, "" when the backend has no default.
 */
LLM_Vision_ResolveModel(Parsed, Config) {
	if Parsed.Has("model")
		return Parsed["model"]
	Defaults := (Config is Map) ? Config.Get("default_models", "") : ""
	if !(Defaults is Map)
		return ""
	Model := Defaults.Get(Parsed["backend"], "")
	return (Model is String) ? Model : ""
}





; ===========================
; ===========================
; ======= 3/ Requests =======
; ===========================
; ===========================

/**
 * Builds the request body of one vision or text call.
 * @param {String} Fmt "openai", "anthropic", "gemini" or "ollama". Named Fmt,
 *     not Format, so the built-in Format() stays reachable.
 * @param {Map} Spec Map("model", "system", "text", "max_tokens"[, "image",
 *     "mime"]): image is base64 PNG data, absent for a text request.
 * @returns {String} The JSON body, without address or credentials.
 */
LLM_Vision_BuildRequest(Fmt, Spec) {
	global LLM_VISION_FORMATS
	if !(Fmt is String) || !LLM_VISION_FORMATS.Has(Fmt)
		throw ValueError("LLM_Vision_BuildRequest: unknown format " . String(Fmt) . ".")
	if !(Spec is Map)
		throw TypeError("LLM_Vision_BuildRequest: the spec must be a Map.")
	HasImage := Spec.Has("image")
	Image := Spec.Get("image", "")
	; An absent mime is refused like the Lua nil; Get's "" default would pass as a String
	Mime := Spec.Get("mime", 0)
	if HasImage && (!(Image is String) || Image == "" || !(Mime is String))
		throw ValueError("LLM_Vision_BuildRequest: an image needs base64 data and a mime type.")
	MaxTokens := Spec.Get("max_tokens", "")
	if !(MaxTokens is Integer) || MaxTokens <= 0
		throw ValueError("LLM_Vision_BuildRequest: max_tokens must be a positive integer.")
	for Key in ["model", "system", "text"] {
		if !(Spec.Get(Key, "") is String)
			throw TypeError("LLM_Vision_BuildRequest: " . Key . " must be a string.")
	}
	Model := JsonStringLiteral(Spec.Get("model", ""))
	System := JsonStringLiteral(Spec["system"])
	Text := JsonStringLiteral(Spec["text"])
	Tokens := String(MaxTokens)
	if (Fmt == "openai") {
		Content := Text
		if HasImage
			Content := '[{"type":"text","text":' . Text . '},'
				. '{"type":"image_url","image_url":{"url":'
				. JsonStringLiteral("data:" . Mime . ";base64," . Image) . '}}]'
		return '{"model":' . Model . ',"max_tokens":' . Tokens . ',"stream":false,'
			. '"messages":[{"role":"system","content":' . System . '},'
			. '{"role":"user","content":' . Content . '}]}'
	}
	if (Fmt == "anthropic") {
		Content := '{"type":"text","text":' . Text . '}'
		if HasImage
			Content := '{"type":"image","source":{"type":"base64","media_type":'
				. JsonStringLiteral(Mime) . ',"data":' . JsonStringLiteral(Image) . '}},' . Content
		return '{"model":' . Model . ',"max_tokens":' . Tokens . ',"system":' . System . ','
			. '"messages":[{"role":"user","content":[' . Content . ']}]}'
	}
	if (Fmt == "gemini") {
		Parts := '{"text":' . Text . '}'
		if HasImage
			Parts := '{"inline_data":{"mime_type":' . JsonStringLiteral(Mime)
				. ',"data":' . JsonStringLiteral(Image) . '}},' . Parts
		return '{"system_instruction":{"parts":[{"text":' . System . '}]},'
			. '"contents":[{"role":"user","parts":[' . Parts . ']}],'
			. '"generationConfig":{"maxOutputTokens":' . Tokens . '}}'
	}
	User := '{"role":"user","content":' . Text
		. (HasImage ? ',"images":[' . JsonStringLiteral(Image) . ']' : "") . '}'
	return '{"model":' . Model . ',"stream":false,'
		. '"messages":[{"role":"system","content":' . System . '},' . User . '],'
		. '"options":{"num_predict":' . Tokens . '}}'
}

/**
 * Returns an answer prompt with the interface language filled in.
 * @param {String} Prompt A prompt of vision.json.
 * @param {String} Language The interface language the prompt builder uses.
 * @returns {String}
 */
LLM_Vision_FillLanguage(Prompt, Language) {
	return StrReplace(Prompt, "{language}", Language)
}

/**
 * Returns the user turn of an answer request.
 * @param {String} Screen The transcription.
 * @returns {String}
 */
LLM_Vision_AnswerUserText(Screen) {
	return "SCREEN:`n" . Screen
}

/**
 * Extracts the text a model wrote after a tag, over any number of lines.
 * @param {String} Block The raw model answer.
 * @param {String} Tag The tag, e.g. "SCREEN:" or "ANSWER:".
 * @returns {String} The trimmed text, "" when the tag is absent or nothing follows it.
 */
LLM_Vision_Extract(Block, Tag) {
	global LLM_VISION_SPACE_CLASS
	if !(Block is String) || !(Tag is String) || Tag == ""
		return ""
	; CaseSense off folds A-Z only, like the Lua upper() in the C locale
	At := InStr(Block, Tag, false)
	if !At
		return ""
	Text := StrReplace(SubStr(Block, At + StrLen(Tag)), "**", "")
	return RegExReplace(Text, "^" . LLM_VISION_SPACE_CLASS . "+|" . LLM_VISION_SPACE_CLASS . "+\z", "")
}





; =======================================
; =======================================
; ======= 4/ Shared Configuration =======
; =======================================
; =======================================

/**
 * Returns the decoded, validated vision.json, read on first use.
 * @returns {Map}
 */
LLM_Vision_Config() {
	global _SharedDir
	static Config := ""
	if (Config is Map)
		return Config
	Path := _SharedDir . "\modules\llm\vision.json"
	Candidate := JsonParse(FSReadStrict(Path))
	_LLM_Vision_ValidateConfig(Candidate, Path)
	Config := Candidate
	return Config
}

; Throws unless Candidate holds every field the screen actions read.
; @param {Map} Candidate The decoded file.
; @param {String} Path Its path, for the error.
_LLM_Vision_ValidateConfig(Candidate, Path) {
	if !(Candidate is Map)
		throw ValueError(Path . ": the root must be an object.")
	for Key in ["screen_tag", "answer_tag", "image_mime", "read_prompt"] {
		if !(Candidate.Get(Key, "") is String) || Candidate[Key] == ""
			throw ValueError(Path . ": " . Key . " must be a non-empty string.")
	}
	for Key in ["max_image_edge", "read_max_tokens", "answer_max_tokens"] {
		if !(Candidate.Get(Key, "") is Integer) || Candidate[Key] <= 0
			throw ValueError(Path . ": " . Key . " must be a positive integer.")
	}
	if !(Candidate.Get("default_models", "") is Map)
		throw ValueError(Path . ": default_models must be an object.")
	; answers: llm_screen_region and llm_screen_full; error_answers: llm_screen_error
	for ListKey in ["answers", "error_answers"] {
		Answers := Candidate.Get(ListKey, "")
		if !(Answers is Array) || Answers.Length == 0
			throw ValueError(Path . ": " . ListKey . " must be a non-empty array.")
		for Answer in Answers {
			if !(Answer is Map) || !(Answer.Get("id", "") is String) || !(Answer.Get("prompt", "") is String)
					|| Answer["prompt"] == ""
				throw ValueError(Path . ": every entry of " . ListKey . " needs an id and a prompt.")
		}
	}
}
