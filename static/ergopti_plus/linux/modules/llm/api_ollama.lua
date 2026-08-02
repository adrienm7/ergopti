--- modules/llm/api_ollama.lua

--- ==============================================================================
--- MODULE: Ollama API (Linux)
--- DESCRIPTION:
--- Wraps the Ollama HTTP API (/api/chat and /api/generate) for the Linux
--- prediction engine. Handles streaming SSE responses via curl subprocess,
--- callback dispatch, cancellation, and timeout enforcement. Mirrors the macOS
--- api_ollama.lua module but uses curl (blocking with io.popen) instead of
--- luv async HTTP.
---
--- FEATURES & RATIONALE:
--- 1. curl subprocess: io.popen to curl -s is the simplest HTTP client on
---    Linux. Blocking but simple; adequate for prediction (response times
---    are < 2s for small models on localhost).
--- 2. SSE streaming: Ollama returns ndjson (one JSON object per line) or SSE.
---    The parser splits on newlines and extracts the "message.content" field.
--- 3. Cancel: cancel() kills the curl subprocess and suppresses callbacks.
--- 4. Timeout: curl's --max-time provides a hard timeout; the Lua side also
---    tracks cancellation state.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.llm.api_ollama"

-- HTTP request hard timeout comes from the shared timings registry so every
-- driver's LLM call times out identically (no magic seconds literal here).
local Timings = require("infra.timings")


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _active_pipe = nil   -- io.popen handle during a streaming request.
local _cancelled   = false -- Set by cancel() to suppress callbacks.


-- =========================================
-- =========================================
-- ======= 2/ JSON Encoding ================
-- =========================================
-- =========================================

-- JSON encoder: delegates to the shared linux_bridge module (single source of truth).
local json_encode = nil
local ok_encode, bridge_mod = pcall(require, "infra.llm_bridge")
if ok_encode and bridge_mod and bridge_mod.json_encode then
	json_encode = bridge_mod.json_encode
else
	-- Fallback: minimal encoder for Ollama payloads.
	json_encode = function(tbl)
		if type(tbl) ~= "table" then return tostring(tbl) end
		local parts = {}
		for k, v in pairs(tbl) do
			local val
			if type(v) == "string" then
				val = string.format('"%s"', v:gsub('"', '\\"'):gsub("\n", "\\n"))
			elseif type(v) == "number" or type(v) == "boolean" then
				val = tostring(v)
			elseif type(v) == "table" then
				val = json_encode(v)
			else
				val = "null"
			end
			parts[#parts + 1] = string.format('"%s":%s', tostring(k):gsub('"', '\\"'), val)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
end


-- =========================================
-- =========================================
-- ======= 3/ Request ======================
-- =========================================
-- =========================================

--- Sends a chat completion request to the Ollama /api/chat endpoint.
--- @param base_url string   Ollama base URL (e.g. "http://localhost:11434").
--- @param model    string   Model name.
--- @param messages table    Array of { role, content } message objects.
--- @param opts     table|nil  { stream?, temperature?, max_tokens? }
--- @param on_chunk function  Called with (delta_text) for each streaming chunk.
--- @param on_done  function  Called with (full_text, error) on completion.
function M.chat(base_url, model, messages, opts, on_chunk, on_done)
	if _active_pipe then
		M.cancel()
	end
	_cancelled = false

	local options = type(opts) == "table" and opts or {}
	local stream = options.stream ~= false  -- default: streaming on

	-- Build the JSON payload.
	local payload = {
		model = model,
		messages = messages,
		stream = stream,
	}
	if type(options.temperature) == "number" then
		payload.options = payload.options or {}
		payload.options.temperature = options.temperature
	end
	if type(options.max_tokens) == "number" then
		payload.options = payload.options or {}
		payload.options.num_predict = options.max_tokens
	end

	local json_body = json_encode(payload)
	local url = base_url .. "/api/chat"

	-- Escape for shell.
	local safe_body = json_body:gsub("'", "'\\''")
	-- Hard timeout (seconds) from Timings [llm] request_timeout_ms — the single
	-- cross-driver source for the LLM HTTP timeout, not a re-typed literal.
	local timeout_s = math.floor(Timings.sec("llm", "request_timeout_ms"))
	local cmd = string.format(
		"curl -s --max-time %d -X POST '%s' -H 'Content-Type: application/json' -d '%s' 2>/dev/null",
		timeout_s, url:gsub("'", "'\\''"), safe_body)

	Logger.debug(LOG, "chat() → %s (model=%s stream=%s)", url, model, tostring(stream))

	local ok, err = pcall(function()
		local pipe = io.popen(cmd, "r")
		if not pipe then
			if on_done then pcall(on_done, "", "io.popen failed") end
			return
		end
		_active_pipe = pipe

		local full_text = ""
		local line_count = 0

		for line in pipe:lines() do
			line_count = line_count + 1
			if _cancelled then break end

			-- Ollama returns ndjson: one JSON object per line. Delegate extraction
			-- to the shared bridge, which JSON-decodes the line properly. The former
			-- inline pattern used PCRE alternation ('|') — a literal in a Lua
			-- pattern — so it matched nothing and streaming produced no text at all.
			-- Ollama returns ndjson: one JSON object per line. Delegate extraction
			-- to the shared bridge, which JSON-decodes the line properly. The former
			-- inline pattern used PCRE alternation ('|') — a literal in a Lua
			-- pattern — so it matched nothing and streaming produced no text at all.
			local content = bridge_mod and bridge_mod.parse_stream_line(line)
			if content then
				full_text = full_text .. content
				if on_chunk then pcall(on_chunk, content) end
			end

			-- Check for "done":true in the last line.
			if line:find('"done"%s*:%s*true') then
				break
			end
		end

		pipe:close()
		_active_pipe = nil

		if _cancelled then
			if on_done then pcall(on_done, full_text, "cancelled") end
		elseif full_text == "" then
			if on_done then pcall(on_done, "", "no response from Ollama") end
		else
			if on_done then pcall(on_done, full_text, nil) end
		end
	end)

	if not ok then
		_active_pipe = nil
		Logger.error(LOG, "chat(): request failed — %s", tostring(err))
		if on_done then pcall(on_done, "", tostring(err)) end
	end
end

--- Cancels the in-flight request. Callbacks are NOT invoked.
function M.cancel()
	if _active_pipe then
		_cancelled = true
		pcall(function() _active_pipe:close() end)
		_active_pipe = nil
		Logger.debug(LOG, "Request cancelled.")
	end
end

--- Returns true if a request is currently in flight.
--- @return boolean
function M.is_active()
	return _active_pipe ~= nil
end

return M
