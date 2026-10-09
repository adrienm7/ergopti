--- modules/llm/local_servers.lua

--- ==============================================================================
--- MODULE: Local OpenAI-Compatible Servers
--- DESCRIPTION:
--- The local servers of _shared/modules/llm/local_servers.json (oMLX,
--- LM Studio, llama.cpp / LocalAI, Jan) that the user installed and runs,
--- which of them answer right now, and the models each one serves.
---
--- FEATURES & RATIONALE:
--- 1. Detection, never installation: a server is listed only when its models
---    endpoint answers. A sweep probes every server at once through a probe
---    the caller injects (api_remote owns the HTTP transport, the address and
---    the key), so the main thread never waits and tests fake the transport.
---    A newer sweep supersedes an older one: a late answer is dropped, and the
---    older sweep's caller hears when the newer one completes.
--- 2. A 401 or 403 is an answer: the server runs and wants a key, which the
---    menu then asks for.
--- 3. Requests take the openai format of api_providers.json: api_remote
---    registers each server as a provider needing no key, so predictions, the
---    agent and screen reading follow the paths of a remote provider.
--- 4. A request failure is classified (not running, key wanted, model absent)
---    and reported once to the handler the menu registers, which offers the
---    fix; a success or a sweep that finds the server up clears it.
--- 5. An address or a key typed before any model is chosen waits here, for
---    this session, until the chosen model creates the server's API entry.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local Paths          = require("infra.paths")
local FileSystem     = require("adapters.file_system")
local JsonCodec      = require("adapters.json_codec")
local AuthPolicy     = require("llm.local_server_auth")
local Json           = require("json")
local Discovery      = require("llm.local_server_discovery")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.local_servers"





-- =====================================
-- =====================================
-- ======= 1/ Constants ================
-- =====================================
-- =====================================

-- What a probe found
M.STATUS_UP        = Discovery.STATUS_UP          -- the models endpoint listed the models
M.STATUS_NEEDS_KEY = Discovery.STATUS_NEEDS_KEY   -- the server answered 401 or 403
M.STATUS_DOWN      = Discovery.STATUS_DOWN        -- nothing, or something else, answered

-- Why a request to a local server failed
M.FAILURE_NOT_RUNNING   = "not_running"
M.FAILURE_NEEDS_KEY     = "needs_key"
M.FAILURE_MODEL_MISSING = "model_missing"





-- =====================================
-- =====================================
-- ======= 2/ Catalogue ================
-- =====================================
-- =====================================

--- Reads local_servers.json. A missing or malformed file is logged and gives an
--- empty catalogue: the AI menu then lists no local server, and nothing else of
--- the LLM stack depends on it.
--- @return table order Server ids in menu order.
--- @return table servers Server id -> { id, label, base_url }.
--- @return boolean published Complete same-source local inventory.
local function load_catalogue()
	local path = Paths.shared_llm_path("local_servers.json")
	local raw, status = nil, "error"
	if path then raw, status = FileSystem.read_with_status(path) end
	if status ~= "ok" or type(raw) ~= "string" then
		Logger.error(LOG, "local_servers.json is unreadable at %s (%s): no local server is detected.",
			tostring(path), tostring(status))
		return {}, {}, false
	end
	local ok, root = pcall(JsonCodec.decode, raw)
	if not ok or type(root) ~= "table" or type(root.server_order) ~= "table" or type(root.servers) ~= "table" then
		Logger.error(LOG, "local_servers.json is malformed: no local server is detected.")
		return {}, {}, false
	end
	local source = Json.decode_lossless(raw)
	local shaped = type(source) == "table" and not Json.is_array(source) and not Json.is_null(source)
		and Json.is_array(source.server_order) and type(source.servers) == "table"
		and not Json.is_array(source.servers) and not Json.is_null(source.servers)
	local order, servers = AuthPolicy.catalogue(root, {})
	if #order ~= #root.server_order then
		Logger.error(LOG, "local_servers.json contains unsupported or duplicate optional-auth descriptors.")
	end
	return order, servers, shaped and #order == #source.server_order
end

local config_published
M.ORDER, M.SERVERS, config_published = load_catalogue()

--- Reports admission of the original local catalogue, including a valid empty list.
--- Runtime mutations and server reachability cannot grant inventory authority.
--- @return boolean published
function M.config_catalogue_published() return config_published == true end

--- Tells whether an id names a server of the catalogue.
--- @param id any
--- @return boolean
function M.is_local(id)
	return type(id) == "string" and M.SERVERS[id] ~= nil
end





-- =====================================
-- =====================================
-- ======= 3/ Probe Verdicts ===========
-- =====================================
-- =====================================

--- Reads the model ids of an OpenAI models answer ({ data = { { id }, … } }),
--- in the server's order.
--- @param body any The answer body.
--- @return table|nil ids Nil when the body is not a models list.
function M.models_from_body(body)
	local ids = AuthPolicy.models_receipt({ ok = true, status = 200, body = body })
	return ids
end

--- Tells what answered a models probe.
--- @param response table|nil { ok, status, body } of the HTTP adapter.
--- @return string status M.STATUS_UP, M.STATUS_NEEDS_KEY or M.STATUS_DOWN.
--- @return table|nil models The model ids when the server is up.
function M.classify(response)
	return Discovery.classify(response)
end

--- Tells why a request to a local server failed, when the user can fix it.
--- @param status number|nil HTTP status, 0 or nil when nothing answered.
--- @param message string|nil The server's error message.
--- @return string|nil kind A M.FAILURE_* value, nil for any other failure.
function M.classify_failure(status, message)
	status = tonumber(status) or 0
	if status == 0 then return M.FAILURE_NOT_RUNNING end
	if status == 401 or status == 403 then return M.FAILURE_NEEDS_KEY end
	if status == 404 then return M.FAILURE_MODEL_MISSING end
	local text = type(message) == "string" and message:lower() or ""
	if status == 400 and text:find("model", 1, true)
		and (text:find("not found", 1, true) or text:find("not loaded", 1, true)
			or text:find("does not exist", 1, true) or text:find("no model", 1, true)) then
		return M.FAILURE_MODEL_MISSING
	end
	return nil
end





-- =====================================
-- =====================================
-- ======= 4/ Detection ================
-- =====================================
-- =====================================

-- Native requests, credentials and persistence stay in their existing owners.
-- This controller only owns logical generations, snapshots and publication.
local controller = Discovery.new({
	order = M.ORDER,
	clock = function() return TimerScheduler.now() end,
	max_age = function() return require("infra.timings").sec("llm", "local_server_detection_max_age_ms") end,
	on_publish = function(results)
		local found = {}
		for _, id in ipairs(M.ORDER) do
			local result = results[id]
			if result and result.status == M.STATUS_UP then M.report_success(id) end
			if result and result.status ~= M.STATUS_DOWN then found[#found + 1] = id .. "=" .. result.status end
		end
		Logger.info(LOG, "Local servers swept: %s.", #found > 0 and table.concat(found, ", ") or "none answers")
	end,
	on_error = function(kind, detail, id)
		if kind == "probe" then
			Logger.warn(LOG, "Local server '%s' was not probed: %s.", tostring(id), tostring(detail))
		else
			Logger.error(LOG, "Local server sweep %s callback raised: %s", kind, tostring(detail))
		end
	end,
})

--- Probes every target at once and publishes the verdicts together.
--- Native acquisition and retirement remain the injected probe's responsibility.
--- @param targets table Array of { id, base_url, ... }.
--- @param probe function (target, settle) -> boolean dispatched.
--- @param on_done function|nil Receives changed after the newest sweep completes.
--- @return boolean
function M.sweep(targets, probe, on_done)
	return controller.sweep(targets, probe, on_done)
end

--- Returns the last jointly published verdict of a catalogue server.
--- @param id string
--- @return table|nil
function M.result(id) return controller.result(id) end

--- Returns answering servers in catalogue order.
--- @return table
function M.detected() return controller.detected() end

--- Returns whether the shared cache age requires a new logical sweep.
--- @return boolean
function M.is_stale() return controller.is_stale() end

--- Returns logical activity, never native HTTP/task retirement.
--- @return boolean
function M.is_sweeping() return controller.is_sweeping() end





-- =====================================
-- =====================================
-- ======= 5/ Pending Settings =========
-- =====================================
-- =====================================

-- Server id -> { base_url?, token? } typed before the server has an API entry
local _pending = {}

--- Keeps an address or a key for a server that has no API entry yet.
--- @param id string A server id.
--- @param fields table { base_url = string|nil, token = string|nil }.
function M.set_pending(id, fields)
	if not M.is_local(id) or type(fields) ~= "table" then
		error("local_servers.set_pending: a server id and fields are required")
	end
	local pending = _pending[id] or {}
	for _, key in ipairs({ "base_url", "token" }) do
		if fields[key] ~= nil then pending[key] = fields[key] end
	end
	_pending[id] = pending
end

--- The address and key waiting for a server's API entry.
--- @param id string
--- @return table { base_url?, token? }
function M.pending(id)
	return _pending[id] or {}
end

--- Forgets what waited for a server once its API entry holds it.
--- @param id string
function M.clear_pending(id)
	_pending[id] = nil
end





-- =====================================
-- =====================================
-- ======= 6/ Failure Reports ==========
-- =====================================
-- =====================================

-- Called with (id, kind, detail) when a request to a local server fails
local _failure_handler = nil
-- Server id -> the failure kind already reported
local _reported = {}

--- Registers who offers the fix of a failure (the AI menu).
--- @param handler function|nil (id, kind, detail) where detail is { status, message, model }.
function M.set_failure_handler(handler)
	if handler ~= nil and type(handler) ~= "function" then
		error("local_servers.set_failure_handler: the handler must be a function")
	end
	_failure_handler = handler
end

--- Reports a failed request to a local server. Each kind is reported once
--- until the server answers again.
--- @param id string Server id.
--- @param status number|nil HTTP status.
--- @param message string|nil The server's error message.
--- @param model string|nil The model that was asked for.
--- @return string|nil kind The failure kind, nil when the user cannot fix it here.
function M.report_failure(id, status, message, model)
	if not M.is_local(id) then return nil end
	local kind = M.classify_failure(status, message)
	if kind == nil or _reported[id] == kind then return kind end
	Logger.warn(LOG, "Local server '%s' request failed: %s (HTTP %s).", id, kind, tostring(status))
	-- Before the menu registers its handler nothing is shown, so nothing is
	-- marked reported: the next failure still reaches the user
	if not _failure_handler then return kind end
	_reported[id] = kind
	local ok, err = xpcall(_failure_handler, debug.traceback, id, kind,
		{ status = tonumber(status) or 0, message = message, model = model })
	if not ok then Logger.error(LOG, "Local server failure handler raised: %s", tostring(err)) end
	return kind
end

--- Records that a server answered, so its next failure is reported again.
--- @param id string Server id.
function M.report_success(id)
	_reported[id] = nil
end

return M
