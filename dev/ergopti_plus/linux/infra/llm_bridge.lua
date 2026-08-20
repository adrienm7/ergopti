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

-- ============================================================================
-- 1. Module Constants
-- ============================================================================

--- Default Ollama endpoint path for chat completions.
M.OLLAMA_CHAT_PATH = "/api/chat"

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

--- Resolves the Ollama base URL from port and host overrides.
--- @param port_override number|nil User-configured port override.
--- @param host_override string|nil User-configured host override.
--- @return string Base URL ending with the chat path, or empty string on invalid port.
function M.resolve_base_url(port_override, host_override)
	local port = tonumber(port_override) or M.OLLAMA_DEFAULT_PORT
	if port < M.OLLAMA_PORT_MIN or port > M.OLLAMA_PORT_MAX then return "" end
	local host = host_override or M.OLLAMA_DEFAULT_HOST
	return "http://" .. host .. ":" .. tostring(math.floor(port)) .. M.OLLAMA_CHAT_PATH
end

-- ============================================================================
-- 3. JSON encoder (pure Lua, no dependencies)
-- ============================================================================

--- Encodes a Lua value to a minimal JSON string.
--- Handles nil, boolean, number, string, and table (array or object).
--- Strings are naively quoted — the caller MUST ensure no unescaped quotes
--- or control characters are present (use sanitized input only).
--- @param val any Lua value.
--- @return string|nil JSON string, or nil on unsupported type.
function M.json_encode(val)
	if val == nil then return "null" end
	local t = type(val)
	if t == "boolean" then return val and "true" or "false" end
	if t == "number" then
		if val ~= val then return "null" end -- NaN
		if val == math.huge or val == -math.huge then return "null" end
		return string.format("%.17g", val):gsub("%.%d+", function(frac)
			return (frac:gsub("0+$", ""))
		end):gsub("%.$", "")
	end
	if t == "string" then
		local escaped = val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
		return '"' .. escaped .. '"'
	end
	if t == "table" then
		local is_array = true
		local max_idx = 0
		for k in pairs(val) do
			if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then is_array = false; break end
			if k > max_idx then max_idx = k end
		end
		if is_array and max_idx > 0 then
			local parts = {}
			for i = 1, max_idx do
				parts[i] = M.json_encode(val[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		-- Object
		local parts = {}
		for k, v in pairs(val) do
			if type(k) == "string" then
				parts[#parts + 1] = M.json_encode(k) .. ":" .. M.json_encode(v)
			end
		end
		table.sort(parts) -- deterministic output for tests
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return nil
end

--- Pure-Lua JSON decoder (recursive descent).
--- Handles objects, arrays, strings, numbers, booleans, and null.
--- No external dependencies — runs on any Lua 5.1+ runtime.
--- @param raw string JSON string.
--- @return any|nil Decoded Lua value, or nil on parse failure.
function M.json_decode(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	local pos = 1

	-- Skip whitespace and return the next meaningful character, or nil.
	local function skip_ws()
		while pos <= #raw do
			local c = raw:sub(pos, pos)
			if c == " " or c == "\t" or c == "\r" or c == "\n" then
				pos = pos + 1
			else
				return c
			end
		end
		return nil
	end

	-- Sentinel to distinguish JSON null from parse failure.
	local NULL = {}

	local parse_value -- forward decl

	-- Parse a JSON string (handles escape sequences).
	local function parse_string()
		if raw:sub(pos, pos) ~= '"' then return nil end
		pos = pos + 1
		local res = {}
		while pos <= #raw do
			local ch = raw:sub(pos, pos)
			pos = pos + 1
			if ch == '"' then return table.concat(res) end
			if ch == "\\" then
				local esc = raw:sub(pos, pos)
				pos = pos + 1
				if     esc == '"'  then res[#res + 1] = '"'
				elseif esc == "\\" then res[#res + 1] = "\\"
				elseif esc == "/"  then res[#res + 1] = "/"
				elseif esc == "b"  then res[#res + 1] = "\b"
				elseif esc == "f"  then res[#res + 1] = "\f"
				elseif esc == "n"  then res[#res + 1] = "\n"
				elseif esc == "r"  then res[#res + 1] = "\r"
				elseif esc == "t"  then res[#res + 1] = "\t"
				elseif esc == "u" then
					local hex = raw:sub(pos, pos + 3)
					pos = pos + 4
					local code = tonumber(hex, 16)
					if code and code >= 32 then
						res[#res + 1] = utf8 and utf8.char(code) or string.char(code)
					end
				else
					res[#res + 1] = esc
				end
			else
				res[#res + 1] = ch
			end
		end
		return nil
	end

	parse_value = function()
		local c = skip_ws()
		if not c then return nil end

		-- Object
		if c == "{" then
			pos = pos + 1
			local obj = {}
			if skip_ws() == "}" then pos = pos + 1; return obj end
			while true do
				if skip_ws() ~= '"' then return nil end
				local key = parse_string()
				if type(key) ~= "string" then return nil end
				if skip_ws() ~= ":" then return nil end
				pos = pos + 1
				local val = parse_value()
				if val == nil then return nil end
				obj[key] = (val == NULL) and nil or val
				local sep = skip_ws()
				if sep == "}" then pos = pos + 1; return obj end
				if sep ~= "," then return nil end
				pos = pos + 1
			end
		end

		-- Array
		if c == "[" then
			pos = pos + 1
			local arr = {}
			if skip_ws() == "]" then pos = pos + 1; return arr end
			while true do
				local val = parse_value()
				if val == nil then return nil end
				table.insert(arr, val == NULL and nil or val)
				local sep = skip_ws()
				if sep == "]" then pos = pos + 1; return arr end
				if sep ~= "," then return nil end
				pos = pos + 1
			end
		end

		-- String
		if c == '"' then return parse_string() end

		-- Literals
		if c == "t" and raw:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true end
		if c == "f" and raw:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
		if c == "n" and raw:sub(pos, pos + 3) == "null"  then pos = pos + 4; return NULL end

		-- Number
		local s, e = raw:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
		if s == pos then
			pos = e + 1
			return tonumber(raw:sub(s, e))
		end

		return nil
	end

	local ok, result = pcall(parse_value)
	if not ok then return nil end
	-- Trailing junk check
	if result == nil or skip_ws() ~= nil then return nil end
	return result == NULL and nil or result
end

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
