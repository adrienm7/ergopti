--- modules/llm/api_remote.lua

--- ==============================================================================
--- MODULE: Remote LLM Providers (Linux)
--- DESCRIPTION:
--- Sends predictions to a hosted API (Cerebras, OpenAI, Anthropic, Gemini,
--- Mistral, OpenRouter, Groq, Backboard, any OpenAI-compatible server)
--- described by the shared catalogue _shared/modules/llm/api_providers.json,
--- the same file macOS and Windows read, and asks the agent's System 1 question
--- to Jev (TypeSafe's decisions protocol, directly or through Backboard).
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
--- 4. A provider's format decides what it serves (serves()): a chat request,
---    an image, or only the agent's System 1. Backboard chats through an
---    assistant created once per key and remembered for the session; a
---    decisions provider (Jev) is not a chat model and only answers decide().
---    Their request shapes are the shared _shared/lua/llm/remote_formats.lua.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ErrorDescription = require("error_description")
local Json = require("json")
local Paths = require("infra.paths")
local Timings = require("infra.timings")
local HttpClient = require("adapters.http_client")
local PromptBuilder = require("llm.prompt_builder")
local TextUtils = require("text_utils")
local LlmBridge = require("infra.llm_bridge")
local Monotonic = require("infra.monotonic")
local Formats = require("llm.remote_formats")
local Classifier = require("llm.remote_response_classifier")
local AuthPolicy = require("llm.local_server_auth")
local LocalCatalogue = require("modules.llm.local_server_catalogue")
local ProviderConfig = require("llm.provider_config_policy")

local LOG = "modules.llm.api_remote"

-- Remote inference never shares its owner with downloads or update checks.
-- A non-chat connection test also keeps the active prediction's owner intact.
local OWNER = "llm_remote"
local PROBE_OWNER = "llm_remote_probe"
local ANTHROPIC_VERSION = "2023-06-01"
-- What each format serves: "chat" (predictions, tone, translation, the screen
-- answers' text step, the agent's System 2 and chat triage), "vision" (an image
-- request, vision_request.lua) and "system1" (the agent's triage, a chat or a
-- Jev decision). Backboard's verified message shape carries no image, and Jev
-- is not a chat model.
local FORMAT_USES = {
	openai = { chat = true, vision = true, system1 = true },
	anthropic = { chat = true, vision = true, system1 = true },
	gemini = { chat = true, vision = true, system1 = true },
	backboard = { chat = true, system1 = true },
	decisions = { system1 = true },
}
-- The Backboard model prefix that runs Jev: System 1 asks it through system_one
-- questions instead of the chat triage prompt
local BACKBOARD_JEV_PREFIX = "typesafe/"
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
local _config_catalogue_failed = false

--- Whether one provider descriptor is usable.
--- @param id string
--- @param desc any
--- @return boolean
local function descriptor_is_valid(id, desc)
	if type(desc) ~= "table" then return false end
	for _, key in ipairs({ "label", "base_url", "default_model", "format" }) do
		if type(desc[key]) ~= "string" then return false end
	end
	if desc.label:match("^%s*$") or not FORMAT_USES[desc.format] then return false end
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

--- Validates the probe the Test-API action sends to a decisions provider.
--- @param node any
--- @return table|nil { state, questions }
local function parse_decisions_test(node)
	if type(node) ~= "table" then return nil end
	local state, questions = node.state, node.questions
	if (type(state) ~= "string" or state == "") and type(state) ~= "table" then return nil end
	if type(questions) ~= "table" or next(questions) == nil then return nil end
	return { state = state, questions = questions }
end

--- Parses a catalogue document. Exposed for tests over the shared corpus.
--- @param text string|nil
--- @return table { providers, order, prices, test_request, decisions_test }
--- @return boolean admitted Nonempty projected catalogue, before native read acknowledgement.
function M.parse_catalogue(text)
	local catalogue = { providers = {}, order = {}, prices = {}, test_request = nil, decisions_test = nil }
	local root = type(text) == "string" and Json.decode(text) or nil
	if type(root) ~= "table" or type(root.providers) ~= "table" or type(root.provider_order) ~= "table" then
		Logger.error(LOG, "api_providers.json is missing or malformed — no remote provider is available.")
		return catalogue, false
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
	local skipped
	catalogue.prices, skipped = Classifier.parse_prices(root.model_prices)
	for _, model in ipairs(skipped) do
		Logger.warn(LOG, "api_providers.json: model_prices.%s skipped (missing in/out).", model)
	end
	catalogue.test_request = parse_test_request(root.test_request)
	catalogue.decisions_test = parse_decisions_test(root.decisions_test)
	return catalogue, #catalogue.order > 0
end

--- The catalogue, loaded once from the shared tree.
--- @return table
local function catalogue()
	if _catalogue then return _catalogue end
	local path = Paths.shared("modules/llm/api_providers.json")
	local fh = path and io.open(path, "r")
	local text = fh and fh:read("*a") or nil
	local closed = fh and fh:close()
	local cloud_published
	_catalogue, cloud_published = M.parse_catalogue(text)
	local order, servers, local_published = LocalCatalogue.load(_catalogue.providers)
	_catalogue.config_cloud_published = cloud_published == true and type(text) == "string" and closed == true
	_catalogue.config_local_published = local_published == true
	_catalogue.local_servers = servers
	for _, id in ipairs(order) do
		local desc = servers[id]
		_catalogue.providers[id] = { id = id, label = desc.label, base_url = desc.base_url,
			default_model = "", format = "openai", model_extras = {} }
		_catalogue.order[#_catalogue.order + 1] = id
	end
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

--- Exposes only identities whose native catalogue owner actually published.
--- Empty, unavailable and unacknowledged reads cannot prove retirement.
--- @return table receipt Detached cloud/local configuration publication status.
function M.provider_config_receipt()
	if _config_catalogue_failed then return ProviderConfig.snapshot(false, false, {}) end
	local ok, current = pcall(catalogue)
	if not ok then
		-- A failed native publication cannot acquire configuration authority from
		-- its partial cache. Its existing transport behavior remains its owner's.
		_config_catalogue_failed = true
		Logger.error(LOG, "Provider catalogues could not publish configuration identities: %s.", tostring(current))
		return ProviderConfig.snapshot(false, false, {})
	end
	return ProviderConfig.snapshot(current.config_cloud_published,
		current.config_local_published, current.providers)
end

--- Whether an explicit token satisfies the actual provider's capability.
--- @param provider_id any
--- @param token any
--- @return boolean
function M.token_allowed(provider_id, token, base_url)
	return M.provider(provider_id) ~= nil
		and AuthPolicy.entry_token_allowed(provider_id, token, base_url, catalogue().local_servers)
end

--- The shared connectivity probe, or nil when the catalogue section is invalid.
--- @return table|nil
function M.test_request_spec()
	return catalogue().test_request
end

--- Reports whether a provider serves a use. Every list of providers (the
--- prediction backend, the screen actions, the agent's two systems) filters
--- the catalogue order with it, so a new provider needs no code here.
--- @param id string A provider id.
--- @param use string "chat", "vision" or "system1".
--- @return boolean
function M.serves(id, use)
	local provider = catalogue().providers[id]
	local uses = provider and FORMAT_USES[provider.format] or nil
	return uses ~= nil and uses[use] == true
end

--- The providers serving a use, in catalogue order.
--- @param use string "chat", "vision" or "system1".
--- @return table Array of descriptors.
function M.providers_for(use)
	local list = {}
	for _, provider in ipairs(M.providers()) do
		if M.serves(provider.id, use) then list[#list + 1] = provider end
	end
	return list
end

--- Reports whether an entry's System 1 is a Jev decision rather than the chat
--- triage: a decisions provider, or a Backboard model of TypeSafe.
--- @param entry table { provider, model? }
--- @return boolean
function M.is_decision_entry(entry)
	local provider = type(entry) == "table" and M.provider(entry.provider) or nil
	if not provider then return false end
	if provider.format == "decisions" then return true end
	if provider.format ~= "backboard" then return false end
	local model = (type(entry.model) == "string" and entry.model ~= "") and entry.model or provider.default_model
	return model:sub(1, #BACKBOARD_JEV_PREFIX) == BACKBOARD_JEV_PREFIX
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
	local host, port = authority:match("^(%[[%x:%.]+%]):(%d+)$")
	if not host then host, port = authority:match("^([^:]+):(%d+)$") end
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
local percent_encode = TextUtils.percent_encode

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

--- The address and headers of one request to an entry's provider, per format:
--- openai (and every OpenAI-compatible provider) base_url/chat/completions with
--- a Bearer key, anthropic base_url/messages with x-api-key, gemini
--- base_url/models/{model}:generateContent with the key in the URL. The screen
--- actions send their image bodies to the same address (vision_request.lua).
--- backboard and decisions return the base URL itself with the key's header:
--- Backboard's paths are appended per request by remote_formats, and a
--- decisions base_url is the full endpoint.
--- @param entry table { provider, base_url?, token }
--- @param model string The model the request names.
--- @return table|nil endpoint { url, headers, format }, string|nil reason
function M.endpoint(entry, model)
	if type(entry) ~= "table" then return nil, "no API entry" end
	local provider = M.provider(entry.provider)
	if not provider then return nil, "unknown provider " .. tostring(entry.provider) end
	local base_raw = (type(entry.base_url) == "string" and entry.base_url ~= "") and entry.base_url or provider.base_url
	local base, reason = M.normalize_base_url(base_raw)
	if not base then return nil, reason end
	local token = entry.token
	if not M.token_allowed(entry.provider, token, entry.base_url) then return nil, "the API key is missing or invalid" end
	if type(model) ~= "string" or model == "" then return nil, "no model is configured" end

	local headers = { ["Content-Type"] = "application/json" }
	local url
	if provider.format == "anthropic" then
		url = base .. "/messages"
		headers["x-api-key"] = token
		headers["anthropic-version"] = ANTHROPIC_VERSION
	elseif provider.format == "gemini" then
		local name = model:gsub("^models/", "")
		url = base .. "/models/" .. percent_encode(name) .. ":generateContent?key=" .. percent_encode(token)
	elseif provider.format == "backboard" then
		url = base
		headers[Formats.BACKBOARD_KEY_HEADER] = token
	elseif provider.format == "decisions" then
		url = base
		headers[Formats.DECISIONS_KEY_HEADER] = Formats.decisions_key_value(token)
	else
		url = base .. "/chat/completions"
		if token ~= "" then headers["Authorization"] = "Bearer " .. token end
	end
	return { url = url, headers = headers, format = provider.format }
end

--- The system and user turns of a PromptBuilder message list.
--- @param messages table Array of { role, content }.
--- @return string system, string user
local function split_messages(messages)
	local system, user = "", ""
	for _, message in ipairs(type(messages) == "table" and messages or {}) do
		if message.role == "system" then system = message.content else user = message.content end
	end
	return system, user
end

--- Builds one chat completion request for an entry (openai, anthropic and
--- gemini formats; Backboard's two-step exchange is chat()'s own).
--- @param entry table { provider, base_url?, model?, token }
--- @param messages table Array of { role, content } (PromptBuilder.build_messages).
--- @param opts table|nil { temperature?, max_tokens? }
--- @return table|nil request { url, headers, body, format }, string|nil reason
function M.build_request(entry, messages, opts)
	if type(entry) ~= "table" then return nil, "no API entry" end
	local provider = M.provider(entry.provider)
	if not provider then return nil, "unknown provider " .. tostring(entry.provider) end
	if provider.format == "backboard" or provider.format == "decisions" then
		return nil, provider.label .. " is not sent chat completions"
	end
	local model = model_of(entry, provider)
	local endpoint, reason = M.endpoint(entry, model)
	if not endpoint then return nil, reason end

	local system, user = split_messages(messages)
	local options = type(opts) == "table" and opts or {}
	local temperature = tonumber(options.temperature) or LlmBridge.DEFAULT_TEMPERATURE
	local max_tokens = tonumber(options.max_tokens) or PromptBuilder.DEFAULT_MAX_TOKENS

	local payload = nil
	if provider.format == "anthropic" then
		payload = {
			model = model, system = system, max_tokens = max_tokens, temperature = temperature,
			messages = { { role = "user", content = user } },
		}
	elseif provider.format == "gemini" then
		payload = {
			systemInstruction = { parts = { { text = system } } },
			contents = { { role = "user", parts = { { text = user } } } },
			generationConfig = { temperature = temperature, maxOutputTokens = max_tokens },
		}
	else
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
	return { url = endpoint.url, headers = endpoint.headers, body = body, format = provider.format, model = model }
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
	local text = Classifier.classify(format, body).text
	return text ~= "" and text or nil
end

--- Prices the token usage a response reports with the catalogue's model_prices,
--- so events_llm carries the same cost columns as on macOS.
--- @param usage table remote_response_classifier usage, completed in place.
--- @param model string The model the request named.
--- @return table usage
local function priced(usage, model)
	usage.est_cost_usd = Classifier.estimate_cost(catalogue().prices, model,
		usage.prompt_tokens, usage.completion_tokens)
	return usage
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
	return TextUtils.utf8_byte_prefix(message, MAX_SERVER_MESSAGE)
end




-- =========================================
-- =========================================
-- ======= 4/ Transport ====================
-- =========================================
-- =========================================

local _inference = { epoch = 0, owner = OWNER }
local _probe = { epoch = 0, owner = PROBE_OWNER }
-- The Backboard assistant of each key, created by the first request and reused
-- for the session: { [base_url .. "\n" .. key] = assistant_id }. In memory only.
local _assistants = {}

--- Retires only the original scope epoch, preserving any reentrant successor.
--- @param scope table Private inference or connectivity-test lifetime.
--- @param expected_epoch integer Epoch captured before either cancellation callback.
--- @return boolean accepted Original native cancellation was accepted.
--- @return boolean current No successor replaced the cancelled lifetime.
local function cancel_exchange(scope, expected_epoch)
	-- An earlier cancellation may have synchronously admitted another scope's
	-- successor. Its new epoch does not belong to the original cancel-all call.
	if scope.epoch ~= expected_epoch then return true, false end
	if HttpClient.cancel(scope.owner) ~= true then return false, false end
	if scope.epoch ~= expected_epoch then return true, false end
	scope.epoch, scope.active = expected_epoch + 1, nil
	return true, true
end

--- Opens one exchange, superseding only its own scope's earlier exchange.
--- @param scope table Private inference or connectivity-test lifetime.
--- @param on_done function|nil
--- @param admission function|nil Exact caller authorization, when supplied.
--- @return integer|nil epoch Nil when the previous exchange could not be cancelled.
--- @return function|nil done
--- @return function|nil authorized Pinned authorization for each acquisition.
local function open_exchange(scope, on_done, admission)
	local function permitted()
		if admission == nil then return true end
		if type(admission) ~= "function" then return false end
		local epoch = scope.epoch
		local called, allowed = pcall(admission)
		return called and allowed == true and scope.epoch == epoch
	end
	if not permitted() then return nil end
	if scope.active then
		local retired, current = cancel_exchange(scope, scope.epoch)
		if not retired or not current then return nil end
	end
	if not permitted() then return nil end
	scope.epoch = scope.epoch + 1
	local epoch = scope.epoch
	local finished = false
	local owner = { epoch = epoch }
	-- A terminal callback can precede physical HTTP settlement. Remember that
	-- this alias was used even after active clears, so cancel-all still visits it.
	scope.active, scope.used = owner, true
	local function authorized()
		if scope.active ~= owner or scope.epoch ~= epoch then return false end
		local allowed = permitted() and scope.active == owner and scope.epoch == epoch
		if not allowed and scope.active == owner and scope.epoch == epoch then
			finished, scope.active = true, nil
		end
		return allowed
	end
	local function done(...)
		if finished or epoch ~= scope.epoch then return end
		finished = true
		local deliver = admission == nil or authorized()
		if scope.active ~= owner or epoch ~= scope.epoch then return end
		scope.active = nil
		if deliver and type(on_done) == "function" then
			local ok, callback_err = pcall(on_done, ...)
			if not ok then Logger.error(LOG, "Terminal callback raised — %s", ErrorDescription.describe(callback_err)) end
		end
	end
	return epoch, done, admission ~= nil and authorized or nil
end

--- Why a request failed, with the provider's own explanation when it gives one.
--- @param result any The HTTP adapter's result.
--- @return string
local function failure_detail(result)
	local status = type(result) == "table" and result.status or 0
	local server = type(result) == "table" and M.server_message(result.error_body) or nil
	if status ~= 0 then return string.format("HTTP %d%s", status, server and (": " .. server) or "") end
	return tostring(type(result) == "table" and result.error or "transport failed")
end

--- Retains actual transport evidence privately for the current caller.
--- Application refusals and successful malformed replies create no evidence.
--- @param result any The native transport result.
--- @return table|nil receipt
local function failure_receipt(result)
	if type(result) ~= "table" or result.ok == true then return nil end
	return type(result.failure_receipt) == "table" and result.failure_receipt or nil
end

--- The sorted top-level keys of a decoded answer, never its values: they may
--- hold the user's text.
--- @param root table
--- @return string
local function top_level_keys(root)
	local keys = {}
	for key in pairs(root) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)
	return #keys > 0 and table.concat(keys, ", ") or "none"
end

--- Posts one JSON body within an exchange. on_answer(root) runs with the
--- decoded answer while the exchange is current; a transport or HTTP failure,
--- or an answer that is not a JSON object, goes to fail(detail, failure_receipt?).
--- @param epoch integer The exchange.
--- @param url string
--- @param headers table
--- @param payload table The body, encoded here.
--- @param fail function
--- @param on_answer function
--- @param authorized function|nil Exact exchange authorization.
local function post_json(scope, epoch, url, headers, payload, fail, on_answer, authorized)
	if authorized and not authorized() then return end
	local body = Json.encode(payload)
	if type(body) ~= "string" then
		fail("request could not be encoded")
		return
	end
	local dispatched = HttpClient.post(url, headers, body, function(result)
		if epoch ~= scope.epoch then return end
		if authorized and not authorized() then return end
		if type(result) ~= "table" or result.ok ~= true then
			fail(failure_detail(result), failure_receipt(result))
			return
		end
		local root = type(result.body) == "string" and Json.decode(result.body) or nil
		if type(root) ~= "table" then
			fail("the answer is not a JSON object")
			return
		end
		-- Multi-step providers must reject the same explicit error envelope as
		-- chat completions before its text, typed answers or assistant id escapes.
		if Formats.response_has_error(root) then
			fail("the provider returned an error envelope")
			return
		end
		if authorized and not authorized() then return end
		on_answer(root)
	end, { owner = scope.owner, timeout_ms = Timings.sec("llm", "request_timeout_ms") * 1000, authorized = authorized })
	if dispatched ~= true then fail("HTTP transport unavailable") end
end

--- The address, headers and model of a Backboard request for an entry.
--- @param entry table
--- @return table|nil prepared { endpoint, model }, string|nil reason
local function prepare_backboard(entry)
	local provider = M.provider(entry.provider)
	local model = model_of(entry, provider)
	if not Formats.backboard_split_model(model) then
		return nil, string.format("the Backboard model '%s' names no provider (<llm_provider>/<model_name>)",
			tostring(model))
	end
	local endpoint, reason = M.endpoint(entry, model)
	if not endpoint then return nil, reason end
	return { endpoint = endpoint, model = model }, nil
end

--- Sends one Backboard message, creating the key's assistant first when this
--- session has none yet. A failed creation fails the request and caches
--- nothing, so the next request tries again.
--- @param epoch integer The exchange.
--- @param prepared table prepare_backboard() output.
--- @param spec table { system, text, questions? }
--- @param fail function fail(detail, failure_receipt?)
--- @param on_answer function on_answer(root)
--- @param authorized function|nil Exact exchange authorization.
local function backboard_send(scope, epoch, prepared, spec, fail, on_answer, authorized)
	if authorized and not authorized() then return end
	local endpoint = prepared.endpoint
	local cache_key = endpoint.url .. "\n" .. endpoint.headers[Formats.BACKBOARD_KEY_HEADER]
	local function send_message(assistant_id)
		local request = Formats.backboard_message_request(endpoint.url, {
			assistant_id = assistant_id, model = prepared.model, system = spec.system, text = spec.text,
			questions = spec.questions,
		})
		post_json(scope, epoch, request.url, endpoint.headers, request.body, fail, on_answer, authorized)
	end
	if _assistants[cache_key] then
		send_message(_assistants[cache_key])
		return
	end
	local creation = Formats.backboard_assistant_request(endpoint.url)
	Logger.info(LOG, "Creating the Backboard assistant for this key.")
	-- fail() logs the reason with the request it fails.
	post_json(scope, epoch, creation.url, endpoint.headers, creation.body, function(detail, receipt)
		fail("the Backboard assistant could not be created: " .. detail, receipt)
	end, function(root)
		if authorized and not authorized() then return end
		local assistant_id = Formats.backboard_assistant_id(root)
		if not assistant_id then
			Logger.warn(LOG, "The Backboard assistant could not be created: no assistant_id (keys: %s).",
				top_level_keys(root))
			fail("the Backboard assistant could not be created: no assistant_id in the answer")
			return
		end
		if authorized and not authorized() then return end
		_assistants[cache_key] = assistant_id
		Logger.info(LOG, "Backboard assistant created; reused for this key until the daemon stops.")
		send_message(assistant_id)
	end, authorized)
end

--- Sends one completion. Same shape as api_ollama.chat, with the entry in
--- place of the base URL: on_done(full_text, nil, usage) on success, with the
--- reported tokens priced from model_prices, or on_done("", err, failure_receipt?),
--- exactly once.
--- A Backboard entry sends one message (its assistant created first when
--- needed); a decisions entry is refused, Jev being no chat model.
--- @param entry table
--- @param model string|nil Ignored: the entry names its model.
--- @param messages table
--- @param opts table|nil { temperature?, max_tokens?, authorized? } Backboard's message has
---   no such fields: they are not sent to it.
--- @param on_chunk function|nil Called once with the whole text (no streaming).
--- @param on_done function
function M.chat(entry, model, messages, opts, on_chunk, on_done)
	local _ = model
	local scope = _inference
	local admission
	if type(opts) == "table" then admission = rawget(opts, "authorized") end
	local epoch, done, authorized = open_exchange(scope, on_done, admission)
	if not epoch then return false end
	local function refuse(reason)
		Logger.error(LOG, "Remote request refused before dispatch: %s.", tostring(reason))
		done("", reason)
		return false
	end
	local function fail(detail, receipt)
		Logger.warn(LOG, "Remote request failed: %s.", detail)
		if receipt == nil then done("", detail) else done("", detail, receipt) end
	end
	local started = Monotonic.now_ms()
	local function deliver(text, usage)
		if authorized and not authorized() then return end
		if not text or text == "" then
			Logger.warn(LOG, "Remote response held no completion text.")
			done("", "empty reply")
			return
		end
		Logger.debug(LOG, "Remote completion received (%d chars in %d ms).", #text, Monotonic.now_ms() - started)
		if authorized and not authorized() then return end
		if type(on_chunk) == "function" then pcall(on_chunk, text) end
		done(text, nil, usage)
	end

	local provider = type(entry) == "table" and M.provider(entry.provider) or nil
	if provider and provider.format == "backboard" then
		local prepared, reason = prepare_backboard(entry)
		if not prepared then return refuse(reason) end
		local system, user = split_messages(messages)
		Logger.debug(LOG, "chat() → Backboard %s (model=%s)", M.redact_url(prepared.endpoint.url), prepared.model)
		backboard_send(scope, epoch, prepared, { system = system, text = user }, fail, function(root)
			deliver(Formats.backboard_text(root), priced(Classifier.usage("backboard", root), prepared.model))
		end, authorized)
		return scope.active ~= nil and scope.active.epoch == epoch
	end

	local request, reason = M.build_request(entry, messages, opts)
	if not request then return refuse(reason) end
	Logger.debug(LOG, "chat() → %s (model=%s)", M.redact_url(request.url), request.model)
	local dispatched = HttpClient.post(request.url, request.headers, request.body, function(result)
		if epoch ~= scope.epoch then return end
		if authorized and not authorized() then return end
		if type(result) ~= "table" or result.ok ~= true then
			fail(failure_detail(result), failure_receipt(result))
			return
		end
		local classified = Classifier.classify(request.format, result.body)
		deliver(classified.text ~= "" and classified.text or nil, priced(classified.usage, request.model))
	end, { owner = scope.owner, timeout_ms = Timings.sec("llm", "request_timeout_ms") * 1000, authorized = authorized })
	if dispatched ~= true then
		done("", "HTTP transport unavailable")
		return false
	end
	return true
end

--- Asks Jev one set of typed questions for the agent's System 1: a decisions
--- provider receives decisions_body(); a Backboard entry sends a message with
--- the questions in system_one, and where Backboard put the answers is logged
--- (its clients do not document it). on_done(answers, err, failure_receipt?) is called once.
--- @param entry table A decisions or Backboard entry.
--- @param state string|table What the questions are about.
--- @param questions table { [id] = { type, instructions, criteria? } }
--- @param on_done function
--- @param admission function|nil Exact caller authorization, when supplied.
--- @return boolean dispatched
local function decide(scope, entry, state, questions, on_done, admission)
	local epoch, done, authorized = open_exchange(scope, on_done, admission)
	if not epoch then return false end
	local function refuse(reason)
		Logger.error(LOG, "Decision request refused before dispatch: %s.", tostring(reason))
		done(nil, reason)
		return false
	end
	local function fail(detail, receipt)
		Logger.warn(LOG, "Decision request failed: %s.", detail)
		if receipt == nil then done(nil, detail) else done(nil, detail, receipt) end
	end
	local provider = type(entry) == "table" and M.provider(entry.provider) or nil
	if not provider then return refuse("unknown provider " .. tostring(type(entry) == "table" and entry.provider)) end

	if provider.format == "decisions" then
		local model = model_of(entry, provider)
		local endpoint, reason = M.endpoint(entry, model)
		if not endpoint then return refuse(reason) end
		Logger.debug(LOG, "decide() → %s (model=%s)", M.redact_url(endpoint.url), model)
		post_json(scope, epoch, endpoint.url, endpoint.headers, Formats.decisions_body(model, state, questions), fail,
			function(root)
				local answers = Formats.decisions_answers(root)
				if not answers then
					fail("the answer holds no answers (keys: " .. top_level_keys(root) .. ")")
					return
				end
				done(answers, nil)
			end, authorized)
		return scope.active ~= nil and scope.active.epoch == epoch
	end

	if provider.format == "backboard" then
		local prepared, reason = prepare_backboard(entry)
		if not prepared then return refuse(reason) end
		if type(state) ~= "string" then return refuse("a Backboard message carries a text state only") end
		Logger.debug(LOG, "decide() → Backboard %s (model=%s)", M.redact_url(prepared.endpoint.url), prepared.model)
		backboard_send(scope, epoch, prepared, { system = "", text = state, questions = questions }, fail, function(root)
			local answers, where = Formats.backboard_decision_answers(root, Json.decode)
			if not answers then
				Logger.warn(LOG, "Backboard returned no Jev answers; its top-level keys: %s.", top_level_keys(root))
				done(nil, "Backboard returned no Jev answers")
				return
			end
			Logger.info(LOG, "Jev answers read from Backboard's '%s'.", where)
			done(answers, nil)
		end, authorized)
		return scope.active ~= nil and scope.active.epoch == epoch
	end
	return refuse(provider.label .. " does not answer typed questions")
end

--- Asks one agent decision through the ordinary inference owner.
--- @param entry table Provider entry.
--- @param state string|table What the questions are about.
--- @param questions table Typed questions.
--- @param on_done function
--- @param admission function|nil Exact caller authorization.
--- @return boolean dispatched
function M.decide(entry, state, questions, on_done, admission)
	return decide(_inference, entry, state, questions, on_done, admission)
end

--- Cancels both original exchanges; neither callback is called after retirement.
--- @return boolean
function M.cancel()
	local inference_epoch, probe_epoch, probe_used = _inference.epoch, _probe.epoch, _probe.used
	local inference = cancel_exchange(_inference, inference_epoch)
	local probe = not probe_used or cancel_exchange(_probe, probe_epoch)
	return inference and probe
end

--- Returns true while inference or its independent non-chat probe is in flight.
--- @return boolean
function M.is_active()
	return _inference.active ~= nil or _probe.active ~= nil
end

--- Lists models for a manually configured local API through the existing owner.
--- @param entry table Provider, configured base URL, token and model identity.
--- @param on_done function Receives (model_ids, reason, failure_receipt?).
--- @return boolean dispatched
function M.models(entry, on_done)
	local scope = _inference
	local epoch, done = open_exchange(scope, on_done)
	if not epoch then return false end
	local endpoint, reason = M.endpoint(entry, "models-probe")
	if not endpoint or endpoint.format ~= "openai" then
		done(nil, reason or "unsupported_models")
		return false
	end
	local captured = {}
	for _, key in ipairs({ "id", "provider", "base_url", "token", "model" }) do captured[key] = entry[key] end
	local url = endpoint.url:gsub("/chat/completions$", "/models")
	local dispatched = HttpClient.get(url, endpoint.headers,
		{ owner = scope.owner, timeout_ms = Timings.ms("llm", "local_server_probe_timeout_ms"), follow_redirects = false },
		function(result)
			if epoch ~= scope.epoch then return end
			for _, key in ipairs({ "id", "provider", "base_url", "token", "model" }) do
				if entry[key] ~= captured[key] then done(nil, "identity_changed"); return end
			end
			local ids, refusal = AuthPolicy.models_receipt(result)
			local receipt = failure_receipt(result)
			if receipt == nil then done(ids, refusal) else done(ids, refusal, receipt) end
		end)
	if dispatched ~= true then done(nil, "HTTP transport unavailable"); return false end
	return true
end

--- Sends the connectivity probe with one entry: the shared test_request as a
--- chat (a Backboard entry as one message), or decisions_test to a decisions
--- provider, which passes when the answer holds answers.
--- @param entry table
--- @param on_done function Called with (ok, detail, elapsed_ms, failure_receipt?): detail is the reply or the error.
--- The optional receipt is private transport data, not a page-safe report.
--- @param admission function|nil Exact caller authorization, when supplied.
--- @return boolean Whether the probe was dispatched.
function M.test(entry, on_done, admission)
	local inference_epoch, probe_epoch = _inference.epoch, _probe.epoch
	local scope
	local function admitted()
		if admission == nil then return true end
		local function current()
			if scope == _inference then return _inference.epoch == inference_epoch end
			if scope == _probe then return _probe.epoch == probe_epoch end
			return _inference.epoch == inference_epoch and _probe.epoch == probe_epoch
		end
		if type(admission) ~= "function" or not current() then return false end
		local called, allowed = pcall(admission)
		return called and allowed == true and current()
	end
	if not admitted() then return false end
	local started = Monotonic.now_ms()
	local provider = type(entry) == "table" and M.provider(entry.provider) or nil
	scope = provider and provider.format == "decisions" and _probe or _inference
	if provider and provider.format == "decisions" then
		local probe = catalogue().decisions_test
		if not probe then
			if not admitted() then return false end
			on_done(false, "the API provider list is invalid", 0)
			return false
		end
		if not admitted() then return false end
		return decide(scope, entry, probe.state, probe.questions, function(answers, err, receipt)
			local detail = err or Json.encode(answers) or ""
			local elapsed = Monotonic.now_ms() - started
			if receipt == nil then on_done(err == nil, detail, elapsed)
			else on_done(err == nil, detail, elapsed, receipt) end
		end, admission)
	end
	local spec = M.test_request_spec()
	if not spec then
		if not admitted() then return false end
		on_done(false, "the API provider list is invalid", 0)
		return false
	end
	if not admitted() then return false end
	return M.chat(entry, nil, {
		{ role = "system", content = spec.system_prompt },
		{ role = "user", content = spec.user_text },
	}, { temperature = spec.temperature, max_tokens = spec.max_tokens, authorized = admission }, nil, function(text, err, third)
		local elapsed = Monotonic.now_ms() - started
		-- The third value is the usage of a completion, a failure's receipt only beside err.
		local receipt = err ~= nil and third or nil
		if receipt == nil then on_done(err == nil, err or text, elapsed)
		else on_done(err == nil, err or text, elapsed, receipt) end
	end)
end

--- Forgets the loaded catalogue and the Backboard assistants (tests).
function M._reset_for_test()
	_catalogue = nil
	_config_catalogue_failed = false
	for _, scope in ipairs({ _inference, _probe }) do
		scope.epoch, scope.active, scope.used = scope.epoch + 1, nil, nil
	end
	_assistants = {}
end

return M
