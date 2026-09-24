--- infra/llm_bridge.lua
---
--- Pure, driver-agnostic LLM bridge logic for the Linux driver.
--- Handles context collection, prompt building, response parsing, and
--- the Ollama API contract — all without OS-specific calls.
---
--- The actual HTTP I/O is delegated to the http_client adapter so the
--- bridge can be tested on Windows (mock the adapter) and Linux (curl backend).
---
--- This file was Item 25 of the Linux port (Palier 4).

local M = {}

local PromptBuilder = require("llm.prompt_builder")
local Json = require("json")

-- ============================================================================
-- 1. Module Constants
-- ============================================================================

--- Default Ollama endpoint path for chat completions.
M.OLLAMA_CHAT_PATH = "/api/chat"

--- Ollama endpoint path for the installed-model catalogue.
M.OLLAMA_TAGS_PATH = "/api/tags"

--- Default host for Ollama (loopback). Not in defaults.json (macOS/Windows bind
--- loopback implicitly); this is the single Linux-side source, so profiles.lua
--- and prediction_engine.lua must read it here rather than re-typing "localhost".
M.OLLAMA_DEFAULT_HOST = "127.0.0.1"

--- Default port for Ollama. Mirrors the cross-driver canonical
--- _shared/modules/llm/defaults.json (llm_ollama_port) — pinned equal by
--- tools/test/test-linux-llm-defaults-single-source.cjs so it cannot drift.
M.OLLAMA_DEFAULT_PORT = 11434

--- Minimum / maximum valid port numbers.
M.OLLAMA_PORT_MIN = 1024
M.OLLAMA_PORT_MAX = 65535

--- Default generation temperature. Mirrors the cross-driver canonical
--- defaults.json (llm_temperature = 0.1); was 0.7 here, a silent divergence from
--- macOS/Windows. Pinned equal by the single-source gate.
M.DEFAULT_TEMPERATURE = 0.1

--- Default keep-alive window kept warm on the Ollama server. Mirrors the
--- canonical defaults.json (llm_ollama_keep_alive). Pinned equal by the gate.
M.DEFAULT_KEEP_ALIVE = "30m"

--- Default rolling context window (characters of typing history sent as prompt
--- context). Mirrors the canonical defaults.json (llm_context_length = 500) so the
--- Linux prediction engine sends the same window as macOS/Windows (was 2000).
M.DEFAULT_CONTEXT_LENGTH = 500

--- Privacy gates for the prediction path, mirroring the canonical defaults.json
--- (llm_disable_password_fields = true, llm_disable_url_bars = false). The posture
--- distinguishes by real risk: the text around the caret in a password field is a
--- credential, a URL is not. Pinned to the JSON by
--- tools/test/test-linux-llm-defaults-single-source.cjs, like every other scalar
--- here — never re-type these.
M.DEFAULT_DISABLE_PASSWORD_FIELDS = true
M.DEFAULT_DISABLE_URL_BARS = false

--- Number of words from the buffer tail kept as rolling context window.
--- Single-sourced from the shared PromptBuilder (already required above) — it is
--- the canonical for this value, so re-typing 5 here would let the two drift.
M.CONTEXT_TAIL_WORDS = PromptBuilder.CONTEXT_TAIL_WORDS

-- ============================================================================
-- 2. Internal helpers
-- ============================================================================

--- Resolves the Ollama origin from port and host overrides.
--- @param port_override number|nil User-configured port override.
--- @param host_override string|nil User-configured host override.
--- @return string Origin with no operation path, or empty string on invalid port.
function M.resolve_base_url(port_override, host_override)
	local port = tonumber(port_override) or M.OLLAMA_DEFAULT_PORT
	if port < M.OLLAMA_PORT_MIN or port > M.OLLAMA_PORT_MAX then return "" end
	local host = host_override or M.OLLAMA_DEFAULT_HOST
	return "http://" .. host .. ":" .. tostring(math.floor(port))
end

--- Builds one known Ollama operation URL from a path-free origin.
--- @param base_url string Origin returned by resolve_base_url().
--- @param operation string Either "chat" or "tags".
--- @return string|nil Exact endpoint, or nil for an invalid origin/operation.
function M.ollama_endpoint(base_url, operation)
	if type(base_url) ~= "string" or not base_url:match("^https?://[^/%s]+/?$") then
		return nil
	end
	local paths = {
		chat = M.OLLAMA_CHAT_PATH,
		tags = M.OLLAMA_TAGS_PATH,
	}
	local path = paths[operation]
	if not path then return nil end
	return base_url:gsub("/+$", "") .. path
end

-- ============================================================================
-- 3. JSON encoder (pure Lua, no dependencies)
-- ============================================================================

--- Encodes a Lua value as JSON. Delegates to the shared codec: this module
--- kept its own copy, which drifted (string.char on \u escapes, unescaped
--- control characters) after the shared one was fixed.
--- @param val any Lua value.
--- @return string|nil JSON string, or nil on unsupported type.
function M.json_encode(val) return Json.encode(val) end

--- Decodes JSON through the shared codec.
--- @param raw string JSON string.
--- @return any|nil Decoded Lua value, or nil on parse failure.
function M.json_decode(raw) return Json.decode(raw) end

-- ============================================================================
-- 4. Payload builder
-- ============================================================================

--- Builds the Ollama /api/chat JSON payload from a buffer and config.
--- @param buffer string The current typing context buffer.
--- @param config table Fields: model (string), system_prompt (string|nil),
---        max_tokens (number|nil), temperature (number|nil), num_predictions (number|nil),
---        stream (boolean|nil), keep_alive (string|nil).
--- @return table payload ready for JSON encoding.
function M.build_payload(buffer, config)
	config = config or {}
	local system_prompt = config.system_prompt
	local model_name    = config.model or "llama3.2"
	local max_tokens    = config.max_tokens or PromptBuilder.DEFAULT_MAX_TOKENS
	local temperature   = config.temperature or M.DEFAULT_TEMPERATURE
	local num_preds     = config.num_predictions or 1
	local stream        = config.stream or false

	local messages = {}
	-- Substitute {context} placeholder in system prompt if present,
	-- then add the system message. The buffer always goes into the
	-- user message; context substitution upstream is handled by
	-- PromptBuilder.build_params().
	if system_prompt and system_prompt:find("{context}", 1, true) then
		system_prompt = system_prompt:gsub("{context}", buffer or "", 1)
	end
	if system_prompt and system_prompt ~= "" then
		messages[#messages + 1] = { role = "system", content = system_prompt }
	end
	messages[#messages + 1] = { role = "user", content = buffer or "" }

	return {
		model      = model_name,
		messages   = messages,
		stream     = stream,
		keep_alive = config.keep_alive or M.DEFAULT_KEEP_ALIVE,
		options    = {
			temperature = temperature,
			num_predict = max_tokens * num_preds,
		},
	}
end

-- ============================================================================
-- 5. Response parser
-- ============================================================================

--- Parses an Ollama /api/chat response body and extracts the text content.
--- @param response_body string Raw JSON response body.
--- @return string|nil The assistant's message content, or nil on parse failure.
function M.parse_response(response_body)
	if type(response_body) ~= "string" or response_body == "" then return nil end
	local data = M.json_decode(response_body)
	if type(data) ~= "table" then return nil end
	if type(data.message) == "table" and type(data.message.content) == "string" then
		return data.message.content
	end
	if type(data.response) == "string" then
		return data.response
	end
	return nil
end

--- Parses a streaming NDJSON line from Ollama's /api/chat stream.
--- @param line string One line of NDJSON.
--- @return string|nil The token content, or nil if the line is empty/unparseable.
function M.parse_stream_line(line)
	if type(line) ~= "string" or line:match("^%s*$") then return nil end
	local data = M.json_decode(line)
	if type(data) ~= "table" then return nil end
	if type(data.message) == "table" and type(data.message.content) == "string" then
		if data.message.content ~= "" then
			return data.message.content
		end
	end
	return nil
end

-- ============================================================================
-- 6. Context collection
-- ============================================================================

--- Builds the request parameters from the current buffer and LLM config.
--- Delegates to the shared PromptBuilder module.
--- @param buffer string The current tracked typing buffer.
--- @param config table LLM configuration (max_words, min_words, num_predictions, temperature, etc.).
--- @return table params { context, context_tail, max_tokens, temperature, min_words, max_words, language, num_predictions }
function M.build_request_params(buffer, config)
	return PromptBuilder.build_params(buffer, config)
end

--- Extracts the last N context words from a buffer for display / debugging.
--- @param buffer string The typing buffer.
--- @param n_words number Number of words to extract (default: M.CONTEXT_TAIL_WORDS).
--- @return string The last N words joined by spaces.
function M.extract_tail(buffer, n_words)
	n_words = n_words or M.CONTEXT_TAIL_WORDS
	if type(buffer) ~= "string" or buffer:match("^%s*$") then return "" end
	local words = {}
	for w in buffer:gmatch("%S+") do
		words[#words + 1] = w
	end
	local start = math.max(1, #words - n_words + 1)
	local tail = {}
	for i = start, #words do
		tail[#tail + 1] = words[i]
	end
	return table.concat(tail, " ")
end

return M
