; modules/llm/api_ollama/ollama_payload.ahk

; ==============================================================================
; MODULE: Ollama API — Payload Helpers
; DESCRIPTION:
; JSON serialization and deserialization helpers for the Ollama API. Builds
; /api/chat request payloads, parses streaming JSONL lines and full responses,
; and provides the JSON escape/unescape utilities shared by all request paths.
; ==============================================================================

; =====================================
; =====================================
; ======= 6/ Payload Helpers ==========
; =====================================
; =====================================

/**
 * Escapes a string for embedding in a JSON value. Written via ``FSWrite``
 * (UTF-8-RAW) into the curl payload file — accents pass through as UTF-8.
 */
_LLM_Ollama_EscapeJSON(s) {
	out := ""
	loop parse s {
		ch := A_LoopField
		code := Ord(ch)
		if (ch = "\") {
			out .= "\\"
		} else if (ch = '"') {
			out .= '\"'
		} else if (ch = "`n") {
			out .= "\n"
		} else if (ch = "`r") {
			out .= "\r"
		} else if (ch = "`t") {
			out .= "\t"
		} else if (code < 0x20) {
			out .= Format("\u{:04X}", code)
		} else {
			out .= ch
		}
	}
	return out
}

_LLM_Ollama_IsLineMode(system_prompt, is_batch) {
	if is_batch
		return false
	if (InStr(system_prompt, "TAIL_CORRECTED") or InStr(system_prompt, "NEXT_WORDS"))
		return false
	return true
}

_LLM_Ollama_StopsArray(stop_sequences, line_mode, is_batch) {
	if (stop_sequences != "" and Type(stop_sequences) == "Array" and stop_sequences.Length > 0)
		return stop_sequences
	return (line_mode && !is_batch) ? LLM_ApiCommon_GetStopSequences("line") : LLM_ApiCommon_GetStopSequences("batch")
}

_LLM_Ollama_StopsJson(stop_sequences, line_mode, is_batch) {
	stops := _LLM_Ollama_StopsArray(stop_sequences, line_mode, is_batch)
	out := ""
	for _, s in stops {
		escaped := _LLM_Ollama_EscapeJSON(s)
		if (escaped = "")
			continue
		if (out != "")
			out .= ","
		out .= '"' escaped '"'
	}
	return out
}

/**
 * Builds the ``messages`` array for /api/chat — mirrors macOS ``build_request_context``.
 */
_LLM_Ollama_BuildMessages(system_prompt, full_text, tail_text, model) {
	messages := []
	sys := system_prompt
	user := full_text
	tail := (tail_text != "") ? tail_text : full_text
	if (InStr(sys, "PREFIX") and InStr(sys, "TAIL")) {
		user := Format('PREFIX: "{1}"`nTAIL: "{2}"', full_text, tail)
	} else if (sys != "" and InStr(sys, "{context}")) {
		sys := StrReplace(sys, "{context}", full_text)
		user := sys
		sys := ""
	}
	if RegExMatch(model, "i)qwen3|deepseek|(?:^|:)r1|think|reasoning") {
		if !InStr(user, "/no_think")
			user .= "`n`n/no_think"
	}
	if (sys != "")
		messages.Push(Map("role", "system", "content", sys))
	messages.Push(Map("role", "user", "content", user))
	return messages
}

/**
 * Serialises parameters into an Ollama /api/chat JSON payload (macOS parity).
 */
LLM_BuildOllamaPayload(model, system_prompt, full_text, temperature, streaming := false, stop_sequences := "", max_tokens := "", is_batch := false, tail_text := "") {
	line_mode := _LLM_Ollama_IsLineMode(system_prompt, is_batch)
	; Output-token cap = the shared PromptBuilder budget threaded from the engine
	; (single cross-driver source). No local re-derivation and no literal: an unset
	; ("") or out-of-range value resolves to PB_DEFAULT_MAX_TOKENS, the one shared
	; constant codegen'd from the domain DEFAULT_MAX_TOKENS.
	num_predict := (max_tokens is Number and max_tokens > 0) ? Integer(max_tokens) : PB_DEFAULT_MAX_TOKENS
	msgs := _LLM_Ollama_BuildMessages(system_prompt, full_text, tail_text, model)
	msgs_json := ""
	for _, m in msgs {
		if (msgs_json != "")
			msgs_json .= ","
		msgs_json .= '{"role":"' m["role"] '","content":"' _LLM_Ollama_EscapeJSON(m["content"]) '"}'
	}
	stream_field := streaming ? "true" : "false"
	return '{"model":"' _LLM_Ollama_EscapeJSON(model) '",'
		. '"messages":[' msgs_json '],'
		. '"stream":' stream_field ','
		. '"think":false,'
		. '"keep_alive":"' (LLM_OLLAMA_KEEP_ALIVE != "" ? LLM_OLLAMA_KEEP_ALIVE : "30m") '",'
		. '"options":{"temperature":' Format("{:g}", temperature)
		. ',"num_predict":' num_predict
		. ',"thinking_budget":0'
		. ',"stop":[' _LLM_Ollama_StopsJson(stop_sequences, line_mode, is_batch) . ']}}'
}

/**
 * Parses one NDJSON line from a /api/chat stream (``message.content`` tokens).
 */
_LLM_Ollama_ParseStreamLine(line) {
	Result := Map("ok", false, "token", "", "done", false, "error", "")
	if (line == "") {
		Result["error"] := "Empty stream envelope."
		return Result
	}
	try {
		obj := JsonParse(line)
		if !(obj is Map) {
			Result["error"] := "Stream envelope is not a JSON object."
			return Result
		}
		if obj.Has("error") {
			ProviderError := obj["error"]
			Result["error"] := Type(ProviderError) = "String" && ProviderError != ""
				? "Ollama stream error: " . SubStr(ProviderError, 1, 200)
				: "Ollama reported a stream error."
			return Result
		}
		if !obj.Has("message") or !(obj["message"] is Map) {
			Result["error"] := "Stream envelope is missing message."
			return Result
		}
		msg := obj["message"]
		if !msg.Has("content") or Type(msg["content"]) != "String" {
			Result["error"] := "Stream message is missing string content."
			return Result
		}
		content := msg["content"]
		Result["ok"] := true
		Result["token"] := content
		Result["done"] := obj.Has("done") && obj["done"] = true
		return Result
	} catch as e {
		Result["error"] := "Malformed stream JSON: " . e.Message
		return Result
	}
}

/**
 * Extracts assistant text from a /api/chat JSON reply (non-streaming).
 */
LLM_ParseOllamaChatResponse(raw) {
	if (raw == "")
		return ""
	try {
		obj := JsonParse(raw)
		if (obj is Map) and obj.Has("message") {
			msg := obj["message"]
			if (msg is Map) and msg.Has("content") and Type(msg["content"]) = "String" {
				text := Trim(msg["content"])
				if (text != "")
					return text
				if msg.Has("thinking") and Type(msg["thinking"]) = "String" {
					thinking := Trim(msg["thinking"])
					if (thinking != "") {
						try LoggerInfo("LLM.ollama", "Using thinking field as fallback ({1} chars).", StrLen(thinking))
						return (IsSet(LLM_Parser_StripThinking))
							? LLM_Parser_StripThinking(thinking) : thinking
					}
				}
			}
		}
	} catch as e {
		err_substr := SubStr(raw, 1, 200)
		try LoggerError("LLM.ollama", "JSON parse failed in ChatResponse: {1}. Raw (200c): {2}", e.Message, err_substr)
		return Map("error", true, "message", "JSON parse failed: " . e.Message)
	}
	; Legacy /api/generate bodies (tests + old logs).
	return LLM_ParseOllamaResponse(raw)
}

/**
 * Extracts the "response" field from a legacy Ollama /api/generate JSON reply.
 */
LLM_ParseOllamaResponse(raw) {
	if RegExMatch(raw, '"response"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
		return LLM_UnescapeJSON(m[1])
	return ""
}

/**
 * Decodes captured contents from a valid JSON string token.
 * @param {string} s - Escaped JSON string value.
 * @returns {string} Unescaped string.
 */
LLM_UnescapeJSON(s) {
	return JsonStringDecodeContents(s)
}
