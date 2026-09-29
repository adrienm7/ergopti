--- modules/llm/vision_request.lua

--- ==============================================================================
--- MODULE: Screen Reading Requests (Linux)
--- DESCRIPTION:
--- Sends a screenshot to the vision model an llm_screen_region, llm_screen_full
--- or llm_screen_error binding names and returns the model's answer text. The
--- request bodies come from the shared _shared/lua/llm/vision.lua; this module
--- adds the address and the credentials.
---
--- FEATURES & RATIONALE:
--- 1. "local" is the local Ollama server's /api/chat, whatever backend the AI
---    menu uses for text: a vision model runs there even when the predictions
---    go to a remote API.
--- 2. Any other backend is a provider of api_providers.json, reached through
---    api_remote.endpoint() with the key the user stored for that provider, so
---    the URL rules, headers and key handling are the predictions' own.
--- 3. The request has its own HTTP owner: it never cancels, and is never
---    cancelled by, a prediction in flight.
--- 4. Neither the image nor the model's transcription is ever logged.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Json = require("json")
local Vision = require("llm.vision")

local LOG = "modules.llm.vision_request"

-- The HTTP owner of the vision request, apart from the predictions' owners
local OWNER = "llm_vision"

-- The request format of the local backend (vision.lua)
local LOCAL_FORMAT = "ollama"

-- The decoded vision.json, loaded once
local _config = nil




-- =========================================
-- =========================================
-- ======= 1/ Configuration ================
-- =========================================
-- =========================================

--- Parses vision.json. Exposed for tests.
--- @param text string|nil The file's content.
--- @return table|nil config, string|nil reason
function M.parse_config(text)
	local root = type(text) == "string" and Json.decode(text) or nil
	if type(root) ~= "table" then return nil, "vision.json is missing or not JSON" end
	for _, key in ipairs({ "screen_tag", "answer_tag", "image_mime", "read_prompt" }) do
		if type(root[key]) ~= "string" or root[key] == "" then return nil, "vision.json has no " .. key end
	end
	for _, key in ipairs({ "max_image_edge", "read_max_tokens", "answer_max_tokens" }) do
		local value = root[key]
		if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
			return nil, "vision.json " .. key .. " is not a positive integer"
		end
	end
	if type(root.default_models) ~= "table" then return nil, "vision.json has no default_models" end
	-- answers are the region and full-screen actions', error_answers
	-- llm_screen_error's: each list is offered in its order.
	for _, list in ipairs({ "answers", "error_answers" }) do
		if type(root[list]) ~= "table" or #root[list] == 0 then return nil, "vision.json has no " .. list end
		for index, answer in ipairs(root[list]) do
			if type(answer) ~= "table" or type(answer.id) ~= "string" or type(answer.prompt) ~= "string"
				or answer.prompt == "" then
				return nil, "vision.json " .. list .. " entry " .. index .. " is invalid"
			end
		end
	end
	return root, nil
end

--- The shipped vision.json. A missing or malformed file is an installation
--- fault: the screen actions refuse to run, and the reason is logged once.
--- @return table|nil config
function M.config()
	if _config then return _config end
	local path = require("infra.paths").shared("modules/llm/vision.json")
	local fh = path and io.open(path, "r")
	local text = fh and fh:read("*a") or nil
	if fh then fh:close() end
	local config, reason = M.parse_config(text)
	if not config then
		Logger.error(LOG, "Screen reading unavailable: %s.", tostring(reason))
		return nil
	end
	_config = config
	return _config
end

--- The vision backends a binding may name, for the binding editors: the local
--- server first, then the API providers in catalogue order.
--- @return table Array of { value, label, defaultModel } ("" when the backend has no default).
function M.backend_choices()
	local config = M.config()
	local defaults = config and config.default_models or {}
	local choices = { {
		value = Vision.LOCAL_BACKEND,
		label = require("infra.i18n").get("llm.vision.local_backend"),
		defaultModel = defaults[Vision.LOCAL_BACKEND] or "",
	} }
	for _, provider in ipairs(require("modules.llm.api_remote").providers()) do
		choices[#choices + 1] = { value = provider.id, label = provider.label, defaultModel = defaults[provider.id] or "" }
	end
	return choices
end




-- =========================================
-- =========================================
-- ======= 2/ Target =======================
-- =========================================
-- =========================================

--- The API entry holding the user's key for a provider: the active entry when
--- it is that provider's, else the first one added.
--- @param provider_id string
--- @return table|nil entry
local function entry_for(provider_id)
	local Entries = require("modules.llm.api_entries")
	local active = Entries.active()
	if type(active) == "table" and active.provider == provider_id then return active end
	for _, entry in ipairs(Entries.list()) do
		if entry.provider == provider_id then return entry end
	end
	return nil
end

--- Where a vision request for a backend goes.
--- @param backend string The binding's backend id.
--- @param model string The resolved vision model.
--- @return table|nil target { url, headers, format }, string|nil reason
function M.resolve_target(backend, model)
	if backend == Vision.LOCAL_BACKEND then
		local profiles = require("modules.llm.profiles")
		local Bridge = require("infra.llm_bridge")
		local base_url = profiles.get_base_url() or Bridge.resolve_base_url()
		local url = Bridge.ollama_endpoint(base_url, "chat")
		if not url then return nil, "invalid Ollama origin" end
		return { url = url, headers = { ["Content-Type"] = "application/json" }, format = LOCAL_FORMAT }, nil
	end
	local Remote = require("modules.llm.api_remote")
	if not Remote.provider(backend) then return nil, "unknown provider " .. backend end
	local entry = entry_for(backend)
	if not entry then return nil, "no API key is stored for " .. backend end
	return Remote.endpoint(entry, model)
end




-- =========================================
-- =========================================
-- ======= 3/ Transport ====================
-- =========================================
-- =========================================

--- The answer text of a response body, or nil.
--- @param format string
--- @param body string
--- @return string|nil
local function extract_text(format, body)
	if format ~= LOCAL_FORMAT then return require("modules.llm.api_remote").extract_text(format, body) end
	local root = type(body) == "string" and Json.decode(body) or nil
	local message = type(root) == "table" and root.message or nil
	return type(message) == "table" and type(message.content) == "string" and message.content or nil
end

--- Sends one vision request. on_done(text, err) is called exactly once unless
--- cancel() withdraws the request first.
--- @param target table resolve_target() output.
--- @param body table vision.build_request() output.
--- @param on_done function
--- @return boolean dispatched
function M.send(target, body, on_done)
	local encoded = Json.encode(body)
	if type(encoded) ~= "string" then
		Logger.error(LOG, "Vision request could not be encoded.")
		on_done(nil, "request could not be encoded")
		return false
	end
	local HttpClient = require("adapters.http_client")
	local Timings = require("infra.timings")
	-- The body holds the image: only its size is logged, and the URL is
	-- redacted (a Gemini key travels in it).
	Logger.info(LOG, "Vision request → %s (format=%s, %d byte(s)).",
		require("modules.llm.api_remote").redact_url(target.url), target.format, #encoded)
	local dispatched = HttpClient.post(target.url, target.headers, encoded, function(result)
		if type(result) ~= "table" or result.ok ~= true then
			local status = type(result) == "table" and result.status or 0
			local server = type(result) == "table" and require("modules.llm.api_remote").server_message(result.error_body)
			local detail = status ~= 0 and string.format("HTTP %d%s", status, server and (": " .. server) or "")
				or tostring(type(result) == "table" and result.error or "transport failed")
			on_done(nil, detail)
			return
		end
		local text = extract_text(target.format, result.body)
		if not text or text == "" then
			on_done(nil, "the response holds no answer text")
			return
		end
		on_done(text, nil)
	end, { owner = OWNER, timeout_ms = Timings.sec("llm", "request_timeout_ms") * 1000 })
	return dispatched == true
end

--- Withdraws the vision request in flight; its callback is not called.
--- @return boolean cancelled
function M.cancel()
	return require("adapters.http_client").cancel(OWNER) == true
end

--- Forgets the loaded configuration (tests).
function M._reset_for_test()
	_config = nil
end

return M
