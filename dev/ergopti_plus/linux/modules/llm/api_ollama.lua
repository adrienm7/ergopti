--- modules/llm/api_ollama.lua

--- ==============================================================================
--- MODULE: Ollama API (Linux)
--- DESCRIPTION:
--- Wraps the Ollama HTTP API (/api/chat and /api/generate) for the Linux
--- prediction engine. Handles streaming NDJSON responses through the asynchronous
--- HttpClient adapter, with callback dispatch, cancellation, and timeout ownership.
---
--- FEATURES & RATIONALE:
--- 1. Async transport: the adapter owns a detached curl process and libuv pipes;
---    no network or process wait runs on the grabbed-keyboard call stack.
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
local HttpClient = require("adapters.http_client")


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _active_request = nil
local _request_epoch = 0


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
		-- Arrays first. The payload now carries the stop-sequence list, and
		-- encoding an array as an object gives Ollama {"1":"…","2":"…"} — which it
		-- rejects, so the whole request fails on a machine where only the primary
		-- encoder was missing. A fallback that turns one absent module into a
		-- dead feature is worse than no fallback.
		local count = #tbl
		if count > 0 then
			local items = {}
			for index = 1, count do items[index] = json_encode(tbl[index]) end
			return "[" .. table.concat(items, ",") .. "]"
		end
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
-- ======= 2.1) Shared inference constants =
-- =========================================

--- Reads a shared JSON file from the cross-driver tree.
--- @param relative string Path under _shared/.
--- @return table|nil
local function read_shared_json(relative)
	local ok_paths, Paths = pcall(require, "infra.paths")
	if not ok_paths or not Paths then return nil end
	local root = Paths.shared_root()
	if not root then return nil end
	local handle = io.open(root .. "/" .. relative, "r")
	if not handle then return nil end
	local body = handle:read("*a")
	handle:close()
	local ok_bridge, Bridge = pcall(require, "infra.llm_bridge")
	if not ok_bridge or not Bridge or not Bridge.json_decode then return nil end
	local ok, parsed = pcall(Bridge.json_decode, body)
	if not ok or type(parsed) ~= "table" then return nil end
	return parsed
end

-- How long Ollama keeps the model resident after a request. Without it Ollama
-- applies its own default of five minutes, so a user who pauses for longer pays
-- the full model load on their next keystroke — several seconds on a prediction
-- path budgeted in hundreds of milliseconds. The other two drivers have always
-- sent it; this one did not, and the difference was invisible except as "the
-- Linux predictions are sometimes very slow".
local OLLAMA_KEEP_ALIVE = (function()
	local defaults = read_shared_json("modules/llm/defaults.json")
	local value = defaults and defaults.llm_ollama_keep_alive
	if type(value) == "string" and value ~= "" then return value end
	Logger.warn(LOG, "defaults.json llm_ollama_keep_alive unreadable — Ollama will apply its own default.")
	return nil
end)()

-- Where a completion must stop. Shared with every other backend through
-- inference.json, which exists precisely so the per-file literals cannot drift.
-- Sending none of them lets the model run past the answer into the next turn of
-- the prompt template, and the user sees the scaffolding of their own prompt
-- offered back as a prediction.
local STOP_SEQUENCES = (function()
	local inference = read_shared_json("modules/llm/inference.json")
	local sequences = inference and inference.stop_sequences
	if type(sequences) ~= "table" then
		Logger.warn(LOG, "inference.json stop_sequences unreadable — completions will not be cut short.")
		return {}
	end
	return sequences
end)()

--- The stop list for one request mode.
--- @param line_mode boolean|nil True for single-line completion.
--- @return table|nil
local function stop_for(line_mode)
	local key = line_mode and "line" or "batch"
	local list = STOP_SEQUENCES[key]
	if type(list) == "table" and #list > 0 then return list end
	return nil
end

--- Delivers one terminal callback for a request epoch.
--- @param request table
--- @param err string|nil
local function finish_request(request, err)
	if request.terminal then return end
	request.terminal = true
	if _active_request == request then _active_request = nil end
	if type(request.on_done) == "function" then
		local ok, callback_err = pcall(request.on_done, request.full_text, err)
		if not ok then Logger.error(LOG, "chat(): terminal callback raised — %s", tostring(callback_err)) end
	end
end

--- Parses every complete NDJSON line in one arbitrarily split transport chunk.
--- @param request table
--- @param chunk string
--- @param flush boolean Whether this is the final transport callback.
local function consume_chunk(request, chunk, flush)
	request.pending = request.pending .. (chunk or "")
	while true do
		local newline = request.pending:find("\n", 1, true)
		if not newline then break end
		local line = request.pending:sub(1, newline - 1):gsub("\r$", "")
		request.pending = request.pending:sub(newline + 1)
		local content = bridge_mod and bridge_mod.parse_stream_line(line)
		if content then
			request.full_text = request.full_text .. content
			if type(request.on_chunk) == "function" then pcall(request.on_chunk, content) end
		end
	end
	if flush and request.pending ~= "" then
		local content = bridge_mod and bridge_mod.parse_stream_line(request.pending:gsub("\r$", ""))
		request.pending = ""
		if content then
			request.full_text = request.full_text .. content
			if type(request.on_chunk) == "function" then pcall(request.on_chunk, content) end
		end
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
	if _active_request then M.cancel() end
	_request_epoch = _request_epoch + 1

	local options = type(opts) == "table" and opts or {}
	local stream = options.stream ~= false  -- default: streaming on

	-- Build the JSON payload.
	local payload = {
		model = model,
		messages = messages,
		stream = stream,
		keep_alive = OLLAMA_KEEP_ALIVE,
	}
	if type(options.temperature) == "number" then
		payload.options = payload.options or {}
		payload.options.temperature = options.temperature
	end
	if type(options.max_tokens) == "number" then
		payload.options = payload.options or {}
		payload.options.num_predict = options.max_tokens
	end
	local stop = stop_for(options.line_mode)
	if stop then
		payload.options = payload.options or {}
		payload.options.stop = stop
	end

	local json_body = json_encode(payload)
	local url = bridge_mod and bridge_mod.ollama_endpoint(base_url, "chat") or nil
	if not url then
		Logger.error(LOG, "chat(): invalid Ollama origin — cannot build the chat endpoint.")
		if on_done then pcall(on_done, "", "invalid Ollama origin") end
		return
	end

	local request = {
		epoch = _request_epoch,
		on_chunk = on_chunk,
		on_done = on_done,
		pending = "",
		full_text = "",
		terminal = false,
	}
	_active_request = request

	Logger.debug(LOG, "chat() → %s (model=%s stream=%s)", url, model, tostring(stream))
	HttpClient.postStream(url, { ["Content-Type"] = "application/json" }, json_body, {
		timeout_ms = Timings.sec("llm", "request_timeout_ms") * 1000,
	}, function(chunk)
		if _active_request ~= request or request.terminal or request.epoch ~= _request_epoch then return end
		consume_chunk(request, chunk, false)
	end, function(result)
		if _active_request ~= request or request.terminal or request.epoch ~= _request_epoch then return end
		consume_chunk(request, "", true)
		if type(result) ~= "table" or result.ok ~= true then
			finish_request(request, type(result) == "table" and result.error or "HTTP transport failed")
		elseif request.full_text == "" then
			finish_request(request, "no response from Ollama")
		else
			finish_request(request, nil)
		end
	end)
end

--- Cancels the in-flight request and publishes one terminal cancellation.
--- @return boolean Whether transport termination committed.
function M.cancel()
	if not _active_request then return true end
	local request = _active_request
	_request_epoch = _request_epoch + 1
	local cancelled = HttpClient.cancel()
	finish_request(request, cancelled and "cancelled" or "cancellation failed")
	Logger.debug(LOG, "Request cancellation %s.", cancelled and "committed" or "failed")
	return cancelled
end

--- Returns true if a request is currently in flight.
--- @return boolean
function M.is_active()
	return _active_request ~= nil
end

return M
