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

-- The HttpClient port of the request plan: the client that sends and cancels inference
-- requests. The engine hands it in at init; every other request keeps the adapter.
local InferenceClient = nil

local Logger = require("logger.shim")
local ErrorDescription = require("error_description")
local Json = require("json")
local Paths = require("infra.paths")
local Timings = require("infra.timings")
local HttpClient = require("adapters.http_client")
local Ports = require("llm.request_plan.ports")
local PromptBuilder = require("llm.prompt_builder")
local TextUtils = require("text_utils")
local LlmBridge = require("infra.llm_bridge")
local Monotonic = require("infra.monotonic")
local Formats = require("llm.remote_formats")
local Classifier = require("llm.remote_response_classifier")
local AuthPolicy = require("llm.local_server_auth")
local ThinkingOff = require("llm.thinking_off")
local ModelCapabilities = require("llm.model_capabilities")
local ApiModelListing = require("llm.api_model_listing")
local LocalCatalogue = require("modules.llm.local_server_catalogue")
local ProviderConfig = require("llm.provider_config_policy")
local UrlTemplate = require("llm.api_url_template")
local TokenExchange = require("llm.api_token_exchange")

local LOG = "modules.llm.api_remote"

-- Remote inference never shares its owner with downloads or update checks.
-- A non-chat connection test also keeps the active prediction's owner intact.
local OWNER = "llm_remote"
local PROBE_OWNER = "llm_remote_probe"
-- The model selector page's provider listings: their own owner, so a listing
-- never cancels a prediction or a test.
local LISTING_OWNER = "llm_remote_listing"
-- The capability listings (model_capabilities.lua): their own owner, so a
-- background fetch never cancels or waits for a prediction, a test or a page.
local CAPABILITY_OWNER = "llm_remote_capabilities"
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
	-- Only the generic OpenAI-compatible entry leaves its URL to the user; a
	-- per-account address (a template the add-entry form fills) leaves the model
	local fields, malformed = UrlTemplate.fields(desc.base_url)
	if malformed then return false end
	if id ~= "openai_compat" and (desc.base_url:match("^%s*$")
		or (#fields == 0 and desc.default_model:match("^%s*$"))) then
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
		local thinking_dialect, thinking_reason = nil, nil
		local auth, auth_reason = nil, nil
		if type(desc) == "table" then
			thinking_dialect, thinking_reason = ThinkingOff.parse_dialect(desc.thinking_dialect)
			auth, auth_reason = TokenExchange.parse(desc.auth)
		end
		if catalogue.providers[id] then
			Logger.warn(LOG, "api_providers.json: provider '%s' is listed twice; the first is kept.", id)
		elseif descriptor_is_valid(id, desc) and not thinking_dialect then
			-- A half-read dialect would let some models think: refuse the provider whole
			Logger.error(LOG, "api_providers.json: providers.%s.thinking_dialect is invalid (%s) — skipped.",
				tostring(id), tostring(thinking_reason))
		elseif descriptor_is_valid(id, desc) and auth_reason then
			-- Sent as Bearer, the stored key itself would be refused: refuse the provider whole
			Logger.error(LOG, "api_providers.json: providers.%s.auth is invalid (%s) — skipped.", tostring(id), auth_reason)
		elseif descriptor_is_valid(id, desc) then
			catalogue.providers[id] = {
				auth = auth,
				id = id,
				label = desc.label,
				base_url = desc.base_url,
				default_model = desc.default_model,
				format = desc.format,
				model_extras = normalize_model_extras(desc.model_extras),
				thinking_dialect = thinking_dialect,
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
	local order, servers, local_published, _, request_fields, local_dialect = LocalCatalogue.load(_catalogue.providers)
	_catalogue.config_cloud_published = cloud_published == true and type(text) == "string" and closed == true
	_catalogue.config_local_published = local_published == true
	_catalogue.local_servers = servers
	for _, id in ipairs(order) do
		local desc = servers[id]
		_catalogue.providers[id] = { id = id, label = desc.label, base_url = desc.base_url,
			default_model = "", format = "openai", model_extras = {}, thinking_dialect = local_dialect or {}, request_fields = request_fields }
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

-- Access tokens of the providers that exchange the stored key (auth in
-- api_providers.json), per provider and key: { token, expires_at, pending,
-- waiters, failure, retry_at }. In memory only, and never logged.
local _access = {}
-- Seconds before a failed exchange is tried again, so a refused key does
-- not reach the token service on every keystroke
local ACCESS_RETRY_SECONDS = 60

--- The access slot of an entry.
--- @param entry table
--- @return table
local function access_slot(entry)
	local key = tostring(entry.provider) .. "\0" .. tostring(entry.token)
	_access[key] = _access[key] or { waiters = {} }
	return _access[key]
end

--- Exchanges an entry's stored key for an access token, once at a time;
--- on_done(ok, reason) runs when the exchange settles.
--- @param provider table A catalogue provider with an auth block.
--- @param entry table
--- @param on_done function|nil
local function refresh_access(provider, entry, on_done)
	local slot = access_slot(entry)
	if type(on_done) == "function" then slot.waiters[#slot.waiters + 1] = on_done end
	if slot.pending then return end
	local function settle(ok, reason)
		slot.pending = false
		local waiters = slot.waiters
		slot.waiters = {}
		for _, waiter in ipairs(waiters) do
			local called, problem = pcall(waiter, ok, reason)
			if not called then Logger.error(LOG, "Access token waiter failed: %s", tostring(problem)) end
		end
	end
	local request, reason = TokenExchange.request(provider.auth, entry.token)
	if not request then
		slot.failure, slot.retry_at = reason, Monotonic.now_sec() + ACCESS_RETRY_SECONDS
		Logger.error(LOG, "Access token of provider '%s' cannot be asked: %s.", provider.id, reason)
		return settle(false, reason)
	end
	slot.pending = true
	Logger.start(LOG, "Exchanging the key of provider '%s' for an access token…", provider.id)
	local dispatched = HttpClient.post(request.url, request.headers, request.body, function(result)
		result = type(result) == "table" and result or {}
		local raw = type(result.body) == "string" and result.body ~= "" and result.body or result.error_body
		local decoded_ok, decoded = pcall(Json.decode, type(raw) == "string" and raw or "")
		local token, why = TokenExchange.read(provider.auth, result.status, decoded_ok and decoded or nil, Monotonic.now_sec())
		if token then
			slot.token, slot.expires_at, slot.failure, slot.retry_at = token.token, token.expires_at, nil, nil
			Logger.success(LOG, "Access token of provider '%s' received (valid %d s).", provider.id,
				math.floor(token.expires_at - Monotonic.now_sec()))
			return settle(true, nil)
		end
		slot.failure, slot.retry_at = why, Monotonic.now_sec() + ACCESS_RETRY_SECONDS
		Logger.error(LOG, "Access token of provider '%s' refused: %s.", provider.id, why)
		return settle(false, why)
	end)
	if not dispatched then
		slot.failure, slot.retry_at = "the token exchange could not be sent", Monotonic.now_sec() + ACCESS_RETRY_SECONDS
		Logger.error(LOG, "Access token of provider '%s' cannot be asked: the request was not sent.", provider.id)
		return settle(false, slot.failure)
	end
end

--- The access token an entry's requests carry now, refreshing it in the
--- background when it nears its end.
--- @param provider table
--- @param entry table
--- @return string|nil token, string|nil reason
local function access_token(provider, entry)
	local slot = access_slot(entry)
	local now = Monotonic.now_sec()
	local usable, refresh = TokenExchange.state(provider.auth, slot.token and slot or nil, now)
	if refresh and not slot.pending and (slot.retry_at == nil or now >= slot.retry_at) then
		refresh_access(provider, entry)
	end
	if usable then return slot.token, nil end
	return nil, slot.failure or "the access token is being fetched: try again in a moment"
end

--- Fetches an entry's access token when its provider exchanges keys, then
--- runs on_ready(ok, reason); at once for any other provider.
--- @param entry table
--- @param on_ready function
function M.prepare_access(entry, on_ready)
	local provider = type(entry) == "table" and M.provider(entry.provider) or nil
	if not (provider and provider.auth) then return on_ready(true, nil) end
	local slot = access_slot(entry)
	local now = Monotonic.now_sec()
	if TokenExchange.state(provider.auth, slot.token and slot or nil, now) then
		return on_ready(true, nil)
	end
	if not slot.pending and slot.retry_at and now < slot.retry_at then
		-- A refused exchange waits its pause: the reason answers at once
		return on_ready(false, slot.failure)
	end
	refresh_access(provider, entry, on_ready)
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
	-- A local server entry at its catalogue address goes where the last scan
	-- found the server (modules/llm/local_servers.lua); discovery loads that
	-- module, so an unloaded one has no scan to follow
	local Servers = package.loaded["modules.llm.local_servers"]
	if base_raw == provider.base_url and type(Servers) == "table" and type(Servers.port_scan) == "function" then
		local scan = Servers.port_scan(entry.provider)
		if scan and scan.running and type(scan.base_url) == "string" then base_raw = scan.base_url end
	end
	-- A per-account address is filled when the entry is added; its template never leaves
	if UrlTemplate.has_placeholder(base_raw) then
		return nil, "the entry has no account address: add it again from the provider list"
	end
	local base, reason = M.normalize_base_url(base_raw)
	if not base then return nil, reason end
	local token = entry.token
	if not M.token_allowed(entry.provider, token, entry.base_url) then return nil, "the API key is missing or invalid" end
	if type(model) ~= "string" or model == "" then return nil, "no model is configured" end
	if provider.auth then
		-- The stored key is exchanged for the short-lived token the requests carry
		local access, access_reason = access_token(provider, entry)
		if not access then return nil, access_reason end
		token = access
	end

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

-- The reasoning control of every model family (thinking_off.json), read once
local _thinking_families = nil

-- Fields a provider refused for a model (HTTP 400 naming them), by
-- "<provider>|<model>": later requests never send them again. Read from the
-- state file at the first request, written at each new refusal.
local _thinking_refused = nil

-- The state file of the refusals, under the XDG state home
local THINKING_REFUSED_FILE = "ergopti_plus/llm_thinking_refused.json"

-- Its path, replaced by the tests
local _thinking_refused_path = nil

-- Linux reports genuine absence separately from a read refusal
local ENOENT = 2

--- The refusal store's path.
--- @return string
local function thinking_refused_path()
	return _thinking_refused_path
		or (require("infra.config_paths").state_home() .. "/" .. THINKING_REFUSED_FILE)
end

-- Defined below; declared here for thinking_refused, which reads its expiry
local thinking_families

--- The refusal store, read from its state file on first use. An unreadable
--- file is logged and the refusals are learned again.
--- @return table key -> set of field names.
local function thinking_refused()
	if _thinking_refused then return _thinking_refused end
	local path = thinking_refused_path()
	local fh, _, errno = require("infra.regular_file_reader").open_source(path)
	local stored = nil
	if fh then
		local read_ok, text = pcall(fh.read, fh, "*a")
		pcall(fh.close, fh)
		stored = read_ok and type(text) == "string" and Json.decode(text) or nil
		if stored == nil then Logger.error(LOG, "The refused thinking fields are unreadable; they are learned again.") end
	elseif errno ~= ENOENT then
		Logger.error(LOG, "The refused thinking fields could not be read; they are learned again.")
	end
	local dropped
	_thinking_refused, dropped = ThinkingOff.refusals_parse(stored, os.time(), thinking_families().expiry_sec or 0) -- no families table: nothing is remembered
	if dropped > 0 then Logger.warn(LOG, "%d malformed refused thinking field entr(ies) dropped.", dropped) end
	return _thinking_refused
end

--- Writes the refusal store: a temporary file, then a rename.
--- @return boolean saved
local function save_thinking_refused()
	local path = thinking_refused_path()
	local dir = require("native_path").dirname(path)
	local Shell = require("adapters.shell_runner")
	if dir and not Shell.run("mkdir -p " .. Shell.quote(dir) .. " 2>/dev/null") then return false end
	local text = Json.encode(_thinking_refused)
	local temp = path .. ".tmp"
	-- A temporary file a crash left behind would refuse the exclusive creation
	if io.open(temp, "r") then os.remove(temp) end
	local opened, fh, _, _, remove_owned = pcall(require("infra.regular_file_writer").open, temp, "wx")
	if not opened or not fh or type(text) ~= "string" then
		if opened and fh then pcall(fh.close, fh); remove_owned() end
		return false
	end
	local wrote, written = pcall(fh.write, fh, text)
	local closed, flushed = pcall(fh.close, fh)
	if not wrote or not written or not closed or flushed ~= true then
		remove_owned()
		return false
	end
	local called, renamed = pcall(os.rename, temp, path)
	if not called or renamed ~= true then
		remove_owned()
		return false
	end
	return true
end

--- The model families, loaded at their first use. An unreadable table is
--- logged and turns nothing off: no guess.
--- @return table families
function thinking_families()
	if _thinking_families then return _thinking_families end
	local path = Paths.shared("modules/llm/thinking_off.json")
	local fh = path and io.open(path, "r")
	local text = fh and fh:read("*a") or nil
	if fh then fh:close() end
	local families, reason = ThinkingOff.parse_families(type(text) == "string" and Json.decode(text) or nil)
	if not families then
		Logger.error(LOG, "thinking_off.json is unreadable (%s) — no request turns thinking off.", tostring(reason))
		families = {}
	end
	_thinking_families = families
	return families
end

--- The think value of an Ollama chat body for a model (thinking_off.json):
--- false, or the effort level of a family that ignores false (gpt-oss).
--- @param model string The model id.
--- @return boolean|string think
function M.ollama_think(model)
	local think = ThinkingOff.ollama_think(thinking_families(), tostring(model))
	if think ~= false then Logger.debug(LOG, "Ollama think for model %s: %s.", tostring(model), think) end
	return think
end

-- The capability listings by provider id (model_capabilities.lua cache)
local _capabilities = {}

--- The capability check of one provider's model for the resolver: nil when
--- the provider has no listing.
--- @param provider_id string
--- @param model string
--- @return function|nil lacks (kind, level, template) -> boolean
local function capability_lacks(provider_id, model)
	local config = thinking_families().capability
	if not config or not config.providers[provider_id] then return nil end
	local record = ModelCapabilities.record(ModelCapabilities.records(_capabilities, provider_id), model)
	if not record then return nil end
	return function(kind, level, template)
		local lacking = ModelCapabilities.lacks(record, kind, level, template)
		if lacking then
			Logger.debug(LOG, "Model %s of provider '%s' lacks the %s control (its listing): skipped.", model, provider_id, kind)
		end
		return lacking
	end
end

--- Completes a request body for a provider: a local server's request_fields
--- of local_servers.json (OpenAI shape), then the model family's reasoning
--- control (thinking_off.json) through the provider's thinking_dialect. A
--- field the body already sets wins.
--- @param provider_id string
--- @param model string The model the request names.
--- @param body table The request body, changed in place.
--- @return table body
--- @return table added Paths the thinking control added (for M.thinking_refusal).
function M.complete_body(provider_id, model, body)
	local provider = M.provider(provider_id)
	if not provider then error("api_remote.complete_body: unknown provider " .. tostring(provider_id), 2) end
	if provider.format == "openai" then AuthPolicy.apply_request_fields(body, provider.request_fields) end
	local family, kind, added = ThinkingOff.apply(thinking_families(), provider.thinking_dialect, model, body,
		thinking_refused()[provider_id .. "|" .. model], capability_lacks(provider_id, model))
	if #added > 0 then
		Logger.debug(LOG, "Thinking off: family %d applies to model %s through provider '%s' (%s).",
			family, model, provider_id, kind)
	end
	-- These models answer HTTP 400 to any temperature but the default
	if body.temperature ~= nil and ThinkingOff.default_sampling_only(thinking_families(), model) then
		body.temperature = nil
		Logger.debug(LOG, "Model %s accepts only the default sampling: no temperature is sent.", model)
	end
	return body, added
end

--- When a provider answered HTTP 400 naming a field complete_body added,
--- remembers that field as refused for the provider and model and removes it
--- from the body, so the caller can send the request once more without it.
--- @param provider_id string
--- @param model string
--- @param result table The failed HTTP result (status, error_body).
--- @param added table complete_body's paths.
--- @param body table The request body, changed in place.
--- @return boolean retry True when a refused field was removed.
function M.thinking_refusal(provider_id, model, result, added, body)
	if type(result) ~= "table" then return false end
	local field = ThinkingOff.refused_field(result.status, M.server_message(result.error_body), added)
	if not field then return false end
	if not ThinkingOff.record_refusal(thinking_refused(), provider_id, model, field, os.time()) then
		-- Skipped for this session all the same; only the restart forgets it
		_thinking_refused[provider_id .. "|" .. model] = { [field] = os.time() }
		Logger.warn(LOG, "The refused thinking fields are full: '%s' for model %s is not remembered.", field, model)
	elseif not save_thinking_refused() then
		Logger.error(LOG, "The refused thinking fields could not be saved; they hold until the next restart.")
	end
	ThinkingOff.strip(body, added, field)
	Logger.warn(LOG, "Provider '%s' refused the thinking field '%s' for model %s: sent once more without it, and never again.",
		provider_id, field, model)
	return true
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
		-- Per-model fields from the catalogue, never restated here.
		for field, value in pairs(provider.model_extras[model] or {}) do payload[field] = value end
	end
	-- Reasoning off for every format: a local server's request fields, then
	-- the provider's thinking_off rules, never over a field already set.
	local _, added = M.complete_body(entry.provider, model, payload)
	M.refresh_capabilities(entry)
	local body = Json.encode(payload)
	if type(body) ~= "string" then return nil, "request could not be encoded" end
	return { url = endpoint.url, headers = endpoint.headers, body = body, format = provider.format, model = model,
		provider = entry.provider, payload = payload, added = added }
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
	if (InferenceClient or HttpClient).cancel(scope.owner) ~= true then return false, false end
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
	local dispatched = (InferenceClient or HttpClient).post(url, headers, body, function(result)
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
	local options = { owner = scope.owner, timeout_ms = Timings.sec("llm", "request_timeout_ms") * 1000, authorized = authorized }
	local retried = false
	local function on_result(result)
		if epoch ~= scope.epoch then return end
		if authorized and not authorized() then return end
		if type(result) ~= "table" or result.ok ~= true then
			-- A refused thinking field: the same request once more without it
			if not retried and M.thinking_refusal(request.provider, request.model, result, request.added, request.payload) then
				retried = true
				local again = Json.encode(request.payload)
				if type(again) == "string"
					and (InferenceClient or HttpClient).post(request.url, request.headers, again, on_result, options) == true then
					return
				end
			end
			fail(failure_detail(result), failure_receipt(result))
			return
		end
		local classified = Classifier.classify(request.format, result.body)
		deliver(classified.text ~= "" and classified.text or nil, priced(classified.usage, request.model))
	end
	local dispatched = (InferenceClient or HttpClient).post(request.url, request.headers, request.body, on_result, options)
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

--- The model listing address of an entry: its provider's <base>/models, with
--- the key in the headers (openai, anthropic) or the URL (gemini).
--- @param entry table
--- @return string|nil url, table|nil headers, string|nil format
local function listing_endpoint(entry)
	local provider = type(entry) == "table" and M.provider(entry.provider) or nil
	if not provider or not ApiModelListing.supported(provider.format) then return nil end
	local endpoint = M.endpoint(entry, model_of(entry, provider))
	if not endpoint then return nil end
	local url
	if endpoint.format == "anthropic" then
		url = endpoint.url:gsub("/messages$", "/models")
	elseif endpoint.format == "gemini" then
		local base = endpoint.url:match("^(.-)/models/")
		url = base and (base .. "/models?key=" .. percent_encode(entry.token)) or nil
	else
		url = endpoint.url:gsub("/chat/completions$", "/models")
	end
	return url, endpoint.headers, endpoint.format
end

--- Lists the models an entry's provider serves, for the model selector page,
--- through the HTTP adapter with the request timeout. Never logs the address
--- (a gemini key rides in it) nor the key.
--- @param entry table Provider, base URL, token and model.
--- @param on_done function Receives the api_model_listing state:
---   { state = "listed", ids } or { state = "failed", reason }.
--- @return boolean dispatched
function M.list_models(entry, on_done)
	if type(on_done) ~= "function" then error("api_remote.list_models requires on_done", 2) end
	local url, headers, format = listing_endpoint(entry)
	local provider_id = type(entry) == "table" and tostring(entry.provider) or "?"
	local function finish(state)
		local ok, err = pcall(on_done, state)
		if not ok then Logger.error(LOG, "Remote model listing callback raised — %s", ErrorDescription.describe(err)) end
	end
	if not url then
		finish({ state = "failed", reason = "unsupported" })
		return false
	end
	Logger.info(LOG, "Remote model listing requested (provider=%s).", provider_id)
	local dispatched = HttpClient.get(url, headers,
		{ owner = LISTING_OWNER, timeout_ms = Timings.ms("llm", "request_timeout_ms"), follow_redirects = false },
		function(result)
			if type(result) ~= "table" or result.ok ~= true then
				local status = type(result) == "table" and tonumber(result.status) or 0
				Logger.info(LOG, "Remote model listing unavailable (provider=%s, status=%s).", provider_id, tostring(status))
				finish({ state = "failed", reason = (status or 0) > 0 and "refused" or "unavailable" })
				return
			end
			local decoded_ok, decoded = pcall(Json.decode, type(result.body) == "string" and result.body or "")
			local ids = decoded_ok and ApiModelListing.model_ids(format, decoded) or nil
			if type(ids) ~= "table" then
				Logger.warn(LOG, "Remote model listing could not be read (provider=%s).", provider_id)
				finish({ state = "failed", reason = "unreadable" })
				return
			end
			Logger.info(LOG, "Remote model listing: %d model(s) for provider %s.", #ids, provider_id)
			finish({ state = "listed", ids = ids })
		end)
	if dispatched ~= true then
		finish({ state = "failed", reason = "unavailable" })
		return false
	end
	return true
end

--- Fetches a provider's capability listing when it is missing or stale: on
--- the next event-loop tick and with its own HTTP owner, so the request that
--- asked for it is never delayed. A failed fetch keeps the old listing.
--- @param entry table The API entry whose key reads the listing.
--- @return boolean scheduled
function M.refresh_capabilities(entry)
	local config = thinking_families().capability
	local provider_id = type(entry) == "table" and entry.provider or nil
	local listing = config and config.providers[provider_id]
	if not listing or not ModelCapabilities.needs_fetch(_capabilities, provider_id, os.time(), config.ttl_sec) then
		return false
	end
	local url, headers = listing_endpoint(entry)
	if not url then return false end
	local query = config.page_query[listing]
	if query then url = url .. (url:find("?", 1, true) and "&" or "?") .. query end
	ModelCapabilities.begin(_capabilities, provider_id)
	local function finish(records)
		ModelCapabilities.finish(_capabilities, provider_id, records, os.time())
	end
	local scheduled = require("adapters.event_loop").defer(function()
		Logger.info(LOG, "Capability listing of provider %s requested.", provider_id)
		local dispatched = HttpClient.get(url, headers,
			{ owner = CAPABILITY_OWNER, timeout_ms = Timings.ms("llm", "request_timeout_ms"), follow_redirects = false },
			function(result)
				if type(result) ~= "table" or result.ok ~= true then
					Logger.warn(LOG, "Capability listing of provider %s unavailable (status=%s): kept the old one.",
						provider_id, tostring(type(result) == "table" and result.status or nil))
					return finish(nil)
				end
				local decoded_ok, decoded = pcall(Json.decode, type(result.body) == "string" and result.body or "")
				local records, reason = ModelCapabilities.parse(listing, decoded_ok and decoded or nil)
				if not records then
					Logger.warn(LOG, "Capability listing of provider %s could not be read (%s).", provider_id, tostring(reason))
					return finish(nil)
				end
				local count = 0
				for _ in pairs(records) do count = count + 1 end
				Logger.info(LOG, "Capability listing of provider %s: %d model(s) described.", provider_id, count)
				finish(records)
			end)
		if dispatched ~= true then
			Logger.warn(LOG, "Capability listing of provider %s could not be sent.", provider_id)
			finish(nil)
		end
	end, 0)
	if not scheduled then finish(nil) end
	return scheduled == true
end

--- The capability cache (tests).
--- @return table
function M._capabilities_for_test()
	return _capabilities
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
	local function send()
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
	if not (provider and provider.auth) then return send() end
	-- The key test waits for the access token instead of failing while it is fetched
	local sent = true
	M.prepare_access(entry, function(ok, reason)
		if not admitted() then return end
		if ok then sent = send() ~= false
		else on_done(false, reason, Monotonic.now_ms() - started) end
	end)
	return sent
end

--- Forgets the loaded catalogue and the Backboard assistants (tests).
function M._reset_for_test(thinking_refused_file)
	_thinking_refused, _thinking_refused_path = nil, thinking_refused_file
	_catalogue = nil
	_config_catalogue_failed = false
	for _, scope in ipairs({ _inference, _probe }) do
		scope.epoch, scope.active, scope.used = scope.epoch + 1, nil, nil
	end
	_assistants = {}
	_capabilities = {}
	_access = {}
end

--- Hands in the HttpClient that sends and cancels inference requests (engine init).
--- nil restores the adapter.
--- @param client table|nil Offers post and cancel (llm.request_plan.ports).
function M.set_inference_client(client)
	InferenceClient = client ~= nil and Ports.check("HttpClient", client) or nil
end

return M
