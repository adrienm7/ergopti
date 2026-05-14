; modules/llm/api_ollama.ahk

; ==============================================================================
; MODULE: LLM API — Ollama Backend
; DESCRIPTION:
; HTTP client for the local Ollama inference server (http://localhost:11434).
; Sends a synchronous POST /api/generate request and returns the generated text.
;
; FEATURES & RATIONALE:
; 1. WinHTTP: Uses the Windows-native WinHTTP COM object — no third-party deps.
; 2. Streaming disabled: requests full response at once for simplicity.
; 3. Error surfaced via return value: callers receive "" on failure, never crash.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================
; =====================================
; ======= 1/ HTTP Client =======
; =====================================
; =====================================

; Default Ollama endpoint
LLM_OLLAMA_BASE_URL := "http://localhost:11434"
LLM_OLLAMA_TIMEOUT  := 30000   ; ms — generous to accommodate cold-start inference

/**
 * Sends a prompt to Ollama and returns the generated text.
 * @param {string} model - Ollama model tag (e.g. "qwen2.5:3b").
 * @param {string} system_prompt - System instruction injected before the user context.
 * @param {string} user_text - The user context / completion seed.
 * @param {number} temperature - Sampling temperature (0.0–2.0).
 * @returns {string} The generated text, or "" on error.
 */
LLM_OllamaGenerate(model, system_prompt, user_text, temperature := 0.1) {
	payload := LLM_BuildOllamaPayload(model, system_prompt, user_text, temperature)

	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("POST", LLM_OLLAMA_BASE_URL "/api/generate", false)
		http.SetTimeouts(LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT, LLM_OLLAMA_TIMEOUT)
		http.SetRequestHeader("Content-Type", "application/json")
		http.Send(payload)

		if (http.Status != 200) {
			return ""
		}

		raw := http.ResponseText
		parsed := LLM_ParseOllamaResponse(raw)
		return parsed
	} catch as err {
		; Ollama not running or network error — fail silently
		return ""
	}
}

/**
 * Checks whether the Ollama server is reachable.
 * @returns {boolean} True if the server responds to GET /.
 */
LLM_OllamaIsRunning() {
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("GET", LLM_OLLAMA_BASE_URL, false)
		http.SetTimeouts(2000, 2000, 2000, 2000)
		http.Send()
		return (http.Status == 200)
	} catch {
		return false
	}
}

/**
 * Returns the list of locally available model tags from Ollama.
 * @returns {Array} Array of model name strings, or empty array on error.
 */
LLM_OllamaListModels() {
	models := []
	try {
		http := ComObject("WinHttp.WinHttpRequest.5.1")
		http.Open("GET", LLM_OLLAMA_BASE_URL "/api/tags", false)
		http.SetTimeouts(5000, 5000, 5000, 5000)
		http.Send()
		if (http.Status != 200)
			return models

		; Minimal JSON parse: extract all "name":"..." values
		raw := http.ResponseText
		pos := 1
		while (RegExMatch(raw, '"name"\s*:\s*"([^"]+)"', &m, pos)) {
			models.Push(m[1])
			pos := m.Pos + m.Len
		}
	} catch {
		; Server unreachable
	}
	return models
}




; =====================================
; =====================================
; ======= 2/ Payload Helpers =======
; =====================================
; =====================================

/**
 * Serialises request parameters into an Ollama /api/generate JSON payload.
 * @param {string} model - Model tag.
 * @param {string} system_prompt - System instruction.
 * @param {string} user_text - User context.
 * @param {number} temperature - Sampling temperature.
 * @returns {string} JSON string ready to send.
 */
LLM_BuildOllamaPayload(model, system_prompt, user_text, temperature) {
	; Escape backslashes and double-quotes, then newlines for JSON
	EscapeJSON(s) {
		s := StrReplace(s, "\", "\\")
		s := StrReplace(s, '"', '\"')
		s := StrReplace(s, "`n", "\n")
		s := StrReplace(s, "`r", "")
		return s
	}

	return '{"model":"' EscapeJSON(model) '",'
		. '"system":"' EscapeJSON(system_prompt) '",'
		. '"prompt":"' EscapeJSON(user_text) '",'
		. '"stream":false,'
		. '"options":{"temperature":' temperature '}}'
}

/**
 * Extracts the "response" field from an Ollama /api/generate JSON reply.
 * @param {string} raw - Raw JSON response body.
 * @returns {string} The extracted response text, trimmed.
 */
LLM_ParseOllamaResponse(raw) {
	; Fast regex extraction — avoids a full JSON parser dependency
	if RegExMatch(raw, '"response"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
		return LLM_UnescapeJSON(m[1])
	return ""
}

/**
 * Unescapes basic JSON string escape sequences.
 * @param {string} s - Escaped JSON string value.
 * @returns {string} Unescaped string.
 */
LLM_UnescapeJSON(s) {
	s := StrReplace(s, "\n",  "`n")
	s := StrReplace(s, "\r",  "`r")
	s := StrReplace(s, "\t",  "`t")
	s := StrReplace(s, '\"', '"')
	s := StrReplace(s, "\\", "\")
	return s
}
