--- modules/llm/api_remote.lua

--- ==============================================================================
--- MODULE: Remote LLM Providers (Linux)
--- DESCRIPTION:
--- Sends predictions to a hosted API (Cerebras, OpenAI, Anthropic, Gemini,
--- Mistral, any OpenAI-compatible server) described by the shared catalogue
--- _shared/modules/llm/api_providers.json, the same file macOS and Windows read.
---
--- FEATURES & RATIONALE:
--- 1. Same wire contract as macOS api_remote.lua: one non-streaming request per
---    prediction, the provider's own auth header, per-model body fields merged
---    from the catalogue's model_extras (openai format only), and the shared
---    connectivity probe for the "Test" action.
--- 2. The API key never reaches a command line or a log: it travels in a
---    header (or the Gemini URL), and the HTTP adapter hands both to curl on
---    stdin. Logged URLs are redacted.
--- 3. Same chat() surface as api_ollama, so the prediction engine only chooses
---    which backend to call.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Json = require("json")
local Paths = require("infra.paths")
local Timings = require("infra.timings")
local HttpClient = require("adapters.http_client")
local PromptBuilder = require("llm.prompt_builder")
local LlmBridge = require("infra.llm_bridge")
local Monotonic = require("infra.monotonic")

local LOG = "modules.llm.api_remote"

-- Remote requests get their own transport owner, so switching backends never
-- cancels a model download or an update check.
local OWNER = "llm_remote"
local ANTHROPIC_VERSION = "2023-06-01"
local FORMATS = { openai = true, anthropic = true, gemini = true }
local EXTRA_FIELD = "^[A-Za-z_][A-Za-z0-9_]*$"
-- How much of a provider's refusal is shown: enough for "invalid API key",
-- never a whole HTML error page.
local MAX_SERVER_MESSAGE = 200




-- =========================================
-- =========================================
-- ======= 1/ Provider catalogue ===========
-- =========================================
-- =========================================

local _catalogue = nil

--- Whether one provider descriptor is usable.
--- @param id string
--- @param desc any
--- @return boolean
local function descriptor_is_valid(id, desc)
	if type(desc) ~= "table" then return false end
	for _, key in ipairs({ "label", "base_url", "default_model", "format" }) do
		if type(desc[key]) ~= "string" then return false end
	end
	if desc.label:match("^%s*$") or not FORMATS[desc.format] then return false end
	-- Only the generic OpenAI-compatible entry leaves its URL and model to the user.
	if id ~= "openai_compat" and (desc.base_url:match("^%s*$") or desc.default_model:match("^%s*$")) then
		return false
	end
	if desc.base_url ~= "" and not desc.base_url:match("^https?://%S+$") then return false end
	return true
end

--- Keeps the scalar, JSON-safe fields of each model's extras.
--- @param raw any
--- @return table model -> field -> value
local function normalize_model_extras(raw)
	local extras = {}
	if type(raw) ~= "table" then return extras end
	for model, fields in pairs(raw) do
		if type(model) == "string" and model ~= "" and model:sub(1, 1) ~= "_" and type(fields) == "table" then
			local kept = {}
			for field, value in pairs(fields) do
				if type(field) == "string" and field:match(EXTRA_FIELD)
					and (type(value) == "string" or type(value) == "number") then
					kept[field] = value
				end
			end
			if next(kept) then extras[model] = kept end
		end
	end
	return extras
end

--- Validates the shared connectivity probe.
--- @param node any
--- @return table|nil
local function parse_test_request(node)
	if type(node) ~= "table" then return nil end
	local sys, user, temp, tokens = node.system_prompt, node.user_text, node.temperature, node.max_tokens
	if type(sys) ~= "string" or sys == "" or type(user) ~= "string" or user == "" then return nil end
	if type(temp) ~= "number" or temp ~= temp or temp < 0 or temp > 2 then return nil end
	if type(tokens) ~= "number" or tokens % 1 ~= 0 or tokens < 1 or tokens > 64 then return nil end
	return { system_prompt = sys, user_text = user, temperature = temp, max_tokens = tokens }
end

--- Parses a catalogue document. Exposed for tests over the shared corpus.
--- @param text string|nil
--- @return table { providers, order, test_request }
function M.parse_catalogue(text)
	local catalogue = { providers = {}, order = {}, test_request = nil }
	local root = type(text) == "string" and Json.decode(text) or nil
	if type(root) ~= "table" or type(root.providers) ~= "table" or type(root.provider_order) ~= "table" then
		Logger.error(LOG, "api_providers.json is missing or malformed — no remote provider is available.")
		return catalogue
	end
	for _, id in ipairs(root.provider_order) do
		local desc = type(id) == "string" and root.providers[id] or nil
		if catalogue.providers[id] then
			Logger.warn(LOG, "api_providers.json: provider '%s' is listed twice; the first is kept.", id)
		elseif descriptor_is_valid(id, desc) then
			catalogue.providers[id] = {
				id = id,
				label = desc.label,
				base_url = desc.base_url,
				default_model = desc.default_model,
				format = desc.format,
				model_extras = normalize_model_extras(desc.model_extras),
			}
			catalogue.order[#catalogue.order + 1] = id
		else
			Logger.warn(LOG, "api_providers.json: provider '%s' is invalid and was skipped.", tostring(id))
		end
	end
	catalogue.test_request = parse_test_request(root.test_request)
	return catalogue
end

--- The catalogue, loaded once from the shared tree.
--- @return table
local function catalogue()
	if _catalogue then return _catalogue end
	local path = Paths.shared("modules/llm/api_providers.json")
	local fh = path and io.open(path, "r")
	local text = fh and fh:read("*a") or nil
	if fh then fh:close() end
	_catalogue = M.parse_catalogue(text)
	return _catalogue
end

--- Providers in catalogue order.
--- @return table Array of descriptors.
function M.providers()
	local list = {}
	for _, id in ipairs(catalogue().order) do list[#list + 1] = catalogue().providers[id] end
	return list
end

--- One provider descriptor.
--- @param id string
--- @return table|nil
function M.provider(id)
	return catalogue().providers[id]
end

--- The shared connectivity probe, or nil when the catalogue section is invalid.
--- @return table|nil
function M.test_request_spec()
	return catalogue().test_request
end




-- =========================================
-- =========================================
-- ======= 2/ Request building =============
-- =========================================
-- =========================================

--- Validates a base URL. Userinfo, queries and fragments are refused: each
--- could smuggle a credential or change every endpoint appended to it.
--- @param raw any
--- @return string|nil normalized, string reason
function M.normalize_base_url(raw)
	if type(raw) ~= "string" or raw == "" then return nil, "base URL is empty" end
	if raw:find("[%c%s\\]") then return nil, "base URL contains whitespace, a control character or a backslash" end
	local scheme, authority, suffix = raw:match("^([%a][%w+%.%-]*)://([^/?#]+)(.*)$")
	if not scheme then return nil, "base URL must include a scheme and host" end
	scheme = scheme:lower()
	if scheme ~= "http" and scheme ~= "https" then return nil, "base URL scheme must be http or https" end
	if authority:find("@", 1, true) then return nil, "base URL must not contain userinfo" end
	if suffix:find("[?#]") then return nil, "base URL must not contain a query or fragment" end
	local host, port = authority:match("^([^:]+):(%d+)$")
	host = host or authority
	if not host:match("^[%w%._%-]+$") and not host:match("^%[[%x:%.]+%]$") then
		return nil, "base URL host is invalid"
	end
	if port and (tonumber(port) < 1 or tonumber(port) > 65535) then
		return nil, "base URL port is outside 1..65535"
	end
	return (scheme .. "://" .. authority .. suffix):gsub("/+$", ""), "ok"
end

--- Percent-encodes every byte outside the unreserved set.
--- @param value string
--- @return string
local function percent_encode(value)
	return (value:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end))
end

--- Replaces credential-bearing query values before a URL is logged.
--- @param url string
--- @return string
function M.redact_url(url)
	return (tostring(url):gsub("([?&][Kk][Ee][Yy]=)[^&#]*", "%1<redacted>"))
end

--- The model an entry sends: its own, else the provider's default.
--- @param entry table
--- @param provider table
--- @return string
local function model_of(entry, provider)
	if type(entry.model) == "string" and entry.model ~= "" then return entry.model end
	return provider.default_model
end

--- Builds one request for an entry.
--- @param entry table { provider, base_url?, model?, token }
--- @param messages table Array of { role, content } (PromptBuilder.build_messages).
--- @param opts table|nil { temperature?, max_tokens? }
--- @return table|nil request { url, headers, body, format }, string|nil reason
function M.build_request(entry, messages, opts)
	if type(entry) ~= "table" then return nil, "no API entry" end
	local provider = M.provider(entry.provider)
	if not provider then return nil, "unknown provider " .. tostring(entry.provider) end
	local base_raw = (type(entry.base_url) == "string" and entry.base_url ~= "") and entry.base_url or provider.base_url
	local base, reason = M.normalize_base_url(base_raw)
	if not base then return nil, reason end
	local token = type(entry.token) == "string" and entry.token or ""
	if token == "" then return nil, "the API key is empty" end
	local model = model_of(entry, provider)
	if model == "" then return nil, "no model is configured" end

	local system, user = "", ""
	for _, message in ipairs(type(messages) == "table" and messages or {}) do
		if message.role == "system" then system = message.content else user = message.content end
	end
	local options = type(opts) == "table" and opts or {}
	local temperature = tonumber(options.temperature) or LlmBridge.DEFAULT_TEMPERATURE
	local max_tokens = tonumber(options.max_tokens) or PromptBuilder.DEFAULT_MAX_TOKENS

	local url, headers, payload = nil, { ["Content-Type"] = "application/json" }, nil
	if provider.format == "anthropic" then
		url = base .. "/messages"
		headers["x-api-key"] = token
		headers["anthropic-version"] = ANTHROPIC_VERSION
		payload = {
			model = model, system = system, max_tokens = max_tokens, temperature = temperature,
			messages = { { role = "user", content = user } },
		}
	elseif provider.format == "gemini" then
		local name = model:gsub("^models/", "")
		url = base .. "/models/" .. percent_encode(name) .. ":generateContent?key=" .. percent_encode(token)
		payload = {
			systemInstruction = { parts = { { text = system } } },
			contents = { { role = "user", parts = { { text = user } } } },
			generationConfig = { temperature = temperature, maxOutputTokens = max_tokens },
		}
	else
		url = base .. "/chat/completions"
		headers["Authorization"] = "Bearer " .. token
		local sent = {}
		if system ~= "" then sent[#sent + 1] = { role = "system", content = system } end
		sent[#sent + 1] = { role = "user", content = user }
		payload = { model = model, messages = sent, temperature = temperature, max_tokens = max_tokens, stream = false }
		-- Per-model fields from the catalogue (Cerebras' qwen reasons at length
		-- unless told not to), never restated here.
		for field, value in pairs(provider.model_extras[model] or {}) do payload[field] = value end
	end
	local body = Json.encode(payload)
	if type(body) ~= "string" then return nil, "request could not be encoded" end
	return { url = url, headers = headers, body = body, format = provider.format, model = model }
end




-- =========================================
-- =========================================
-- ======= 3/ Responses ====================
-- =========================================
-- =========================================

--- The completion text of a provider response, or nil.
--- @param format string
--- @param body string
--- @return string|nil
function M.extract_text(format, body)
	local root = type(body) == "string" and Json.decode(body) or nil
	if type(root) ~= "table" then return nil end
	if format == "anthropic" then
		for _, block in ipairs(type(root.content) == "table" and root.content or {}) do
			if type(block) == "table" and block.type == "text" and type(block.text) == "string" then return block.text end
		end
		return nil
	end
	if format == "gemini" then
		local candidate = type(root.candidates) == "table" and root.candidates[1]
		local parts = type(candidate) == "table" and type(candidate.content) == "table" and candidate.content.parts
		for _, part in ipairs(type(parts) == "table" and parts or {}) do
			if type(part) == "table" and part.thought ~= true and type(part.text) == "string" then return part.text end
		end
		return nil
	end
	local choice = type(root.choices) == "table" and root.choices[1]
	local message = type(choice) == "table" and choice.message
	return type(message) == "table" and type(message.content) == "string" and message.content or nil
end

--- The explanation a provider gives when it refuses a request.
--- @param body string|nil
--- @return string|nil
function M.server_message(body)
	local root = type(body) == "string" and Json.decode(body) or nil
	if type(root) ~= "table" then return nil end
	local message = type(root.error) == "table" and root.error.message or root.message
	if type(message) ~= "string" and type(root.error) == "string" then message = root.error end
	if type(message) ~= "string" or message == "" then return nil end
	return message:sub(1, MAX_SERVER_MESSAGE)
end




-- =========================================
-- =========================================
-- ======= 4/ Transport ====================
-- =========================================
-- =========================================

local _epoch = 0
local _active = nil

--- Sends one completion. Same shape as api_ollama.chat, with the entry in
--- place of the base URL: on_done(full_text, err) is called exactly once.
--- @param entry table
--- @param model string|nil Ignored: the entry names its model.
--- @param messages table
--- @param opts table|nil { temperature?, max_tokens? }
--- @param on_chunk function|nil Called once with the whole text (no streaming).
--- @param on_done function
function M.chat(entry, model, messages, opts, on_chunk, on_done)
	local _ = model
	if _active then M.cancel() end
	_epoch = _epoch + 1
	local epoch = _epoch
	local function done(text, err)
		if epoch ~= _epoch then return end
		_active = nil
		if type(on_done) == "function" then
			local ok, callback_err = pcall(on_done, text or "", err)
			if not ok then Logger.error(LOG, "chat(): terminal callback raised — %s", tostring(callback_err)) end
		end
	end
	local request, reason = M.build_request(entry, messages, opts)
	if not request then
		Logger.error(LOG, "Remote request refused before dispatch: %s.", tostring(reason))
		done("", reason)
		return false
	end
	_active = { epoch = epoch }
	local started = Monotonic.now_ms()
	Logger.debug(LOG, "chat() → %s (model=%s)", M.redact_url(request.url), request.model)
	local dispatched = HttpClient.post(request.url, request.headers, request.body, function(result)
		if epoch ~= _epoch then return end
		if type(result) ~= "table" or result.ok ~= true then
			local status = type(result) == "table" and result.status or 0
			local server = type(result) == "table" and M.server_message(result.error_body) or nil
			local detail = status ~= 0 and string.format("HTTP %d%s", status, server and (": " .. server) or "")
				or tostring(type(result) == "table" and result.error or "transport failed")
			Logger.warn(LOG, "Remote request failed: %s.", detail)
			done("", detail)
			return
		end
		local text = M.extract_text(request.format, result.body)
		if not text or text == "" then
			Logger.warn(LOG, "Remote response held no completion text.")
			done("", "empty reply")
			return
		end
		Logger.debug(LOG, "Remote completion received (%d chars in %d ms).", #text, Monotonic.now_ms() - started)
		if type(on_chunk) == "function" then pcall(on_chunk, text) end
		done(text, nil)
	end, { owner = OWNER, timeout_ms = Timings.sec("llm", "request_timeout_ms") * 1000 })
	if dispatched ~= true and _active and _active.epoch == epoch then
		done("", "HTTP transport unavailable")
		return false
	end
	return true
end

--- Cancels the request in flight; its callback is not called.
--- @return boolean
function M.cancel()
	_epoch = _epoch + 1
	_active = nil
	return HttpClient.cancel(OWNER)
end

--- Returns true while a request is in flight.
--- @return boolean
function M.is_active()
	return _active ~= nil
end

--- Sends the shared connectivity probe with one entry.
--- @param entry table
--- @param on_done function Called with (ok, detail, elapsed_ms): detail is the reply or the error.
--- @return boolean Whether the probe was dispatched.
function M.test(entry, on_done)
	local spec = M.test_request_spec()
	if not spec then
		on_done(false, "the API provider list is invalid", 0)
		return false
	end
	local started = Monotonic.now_ms()
	return M.chat(entry, nil, {
		{ role = "system", content = spec.system_prompt },
		{ role = "user", content = spec.user_text },
	}, { temperature = spec.temperature, max_tokens = spec.max_tokens }, nil, function(text, err)
		on_done(err == nil, err or text, Monotonic.now_ms() - started)
	end)
end

--- Forgets the loaded catalogue (tests).
function M._reset_for_test()
	_catalogue = nil
	_epoch = _epoch + 1
	_active = nil
end

return M
